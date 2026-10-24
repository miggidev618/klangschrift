import Foundation

struct TranscriptEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let text: String

    init(id: UUID = UUID(), createdAt: Date = .now, text: String) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
    }
}

enum TranscriptHistory {
    static let maximumEntries = 200

    static func appending(_ entry: TranscriptEntry, to entries: [TranscriptEntry]) -> [TranscriptEntry] {
        [entry] + entries
    }

    static func recent(_ entries: [TranscriptEntry]) -> [TranscriptEntry] {
        Array(entries.prefix(maximumEntries))
    }
}

/// Calendar projection keeps the visible history and its date navigation on
/// the same complete local data set; it deliberately does not apply the
/// compact recents limit used by callers that only need a preview.
enum TranscriptHistoryCalendar {
    static func dictationDays(in entries: [TranscriptEntry], calendar: Calendar = .current) -> [Date] {
        Array(Set(entries.map { calendar.startOfDay(for: $0.createdAt) })).sorted(by: >)
    }

    static func days(inMonthContaining date: Date, calendar: Calendar = .current) -> [Date] {
        guard let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date)),
              let range = calendar.range(of: .day, in: .month, for: start) else { return [] }
        return range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: start) }
    }
}

struct PersonalSpelling: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var heard: String
    var preferred: String

    init(id: UUID = UUID(), heard: String, preferred: String) {
        self.id = id
        self.heard = heard
        self.preferred = preferred
    }
}

/// A bounded, local-only conditioning prompt. It deliberately uses the
/// preferred spelling: the existing literal replacement still corrects the
/// recognized text afterwards for every engine.
enum RecognitionHintPrompt {
    static let maximumEntries = 20
    static let maximumUTF8Bytes = 512

    static func text(from spellings: [PersonalSpelling]) -> String? {
        var accepted: [String] = []
        var seen: Set<String> = []
        for spelling in spellings {
            let term = spelling.preferred.trimmingCharacters(in: .whitespacesAndNewlines)
            let identity = term.lowercased()
            guard !term.isEmpty, seen.insert(identity).inserted else { continue }
            let candidate = (accepted + [term]).joined(separator: ", ")
            guard candidate.lengthOfBytes(using: .utf8) <= maximumUTF8Bytes else { break }
            accepted.append(term)
            if accepted.count == maximumEntries { break }
        }
        return accepted.isEmpty ? nil : accepted.joined(separator: ", ")
    }
}

enum LiteralWordReplacement {
    static func apply(_ text: String, spellings: [PersonalSpelling]) -> String {
        var accumulated = text
        for spelling in spellings {
            let heard = spelling.heard.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !heard.isEmpty, !spelling.preferred.isEmpty else { continue }
            var ranges: [Range<String.Index>] = []
            var search = accumulated.startIndex
            while let range = accumulated.range(of: heard, range: search..<accumulated.endIndex, locale: .current) {
                let before = range.lowerBound > accumulated.startIndex && String(accumulated[accumulated.index(before: range.lowerBound)]).rangeOfCharacter(from: .alphanumerics) != nil
                let after = range.upperBound < accumulated.endIndex && String(accumulated[range.upperBound]).rangeOfCharacter(from: .alphanumerics) != nil
                if !before && !after { ranges.append(range) }
                search = range.upperBound
            }
            for range in ranges.reversed() { accumulated.replaceSubrange(range, with: spelling.preferred) }
        }
        return accumulated
    }
}

enum TranscriptPersistenceError: LocalizedError {
    case historyUnreadable
    case spellingsUnreadable

    var errorDescription: String? {
        switch self {
        case .historyUnreadable: "Der lokale Verlauf konnte nicht gelesen werden. Bestehende Einträge wurden nicht verändert."
        case .spellingsUnreadable: "Eigene Schreibweisen konnten nicht gelesen werden. Bestehende Einträge wurden nicht verändert."
        }
    }
}

enum TranscriptPersistence {
    private static let historyKey = "klangschrift.history.v1"
    private static let spellingsKey = "klangschrift.spellings.v1"

    static func loadHistory(defaults: UserDefaults = .standard) throws -> [TranscriptEntry] {
        guard let data = defaults.data(forKey: historyKey) else { return [] }
        guard let value = try? JSONDecoder().decode([TranscriptEntry].self, from: data) else { throw TranscriptPersistenceError.historyUnreadable }
        return value
    }

    static func saveHistory(_ value: [TranscriptEntry], defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(value), forKey: historyKey)
    }

    /// Removes only the dedicated history payload. Personal spellings and all
    /// other app preferences live under distinct keys and remain untouched.
    static func clearHistory(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: historyKey)
    }

    static func historyByteCount(defaults: UserDefaults = .standard) -> Int {
        defaults.data(forKey: historyKey)?.count ?? 0
    }

    static func loadSpellings(defaults: UserDefaults = .standard) throws -> [PersonalSpelling] {
        guard let data = defaults.data(forKey: spellingsKey) else { return [] }
        guard let value = try? JSONDecoder().decode([PersonalSpelling].self, from: data) else { throw TranscriptPersistenceError.spellingsUnreadable }
        return value
    }

    static func saveSpellings(_ value: [PersonalSpelling], defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(value), forKey: spellingsKey)
    }
}

/// Every displayed amount is calculated from precisely the roots used by the
/// matching maintenance action. No app-group or general preferences are read.
struct StorageMaintenanceUsage: Equatable, Sendable {
    let historyBytes: Int
    let downloadedModelBytes: Int
    let removableModelBytes: Int
    let cacheAndTemporaryBytes: Int
}

struct StorageMaintenanceActivity: Equatable, Sendable {
    var isStarting = false
    var isRecording = false
    var isTranscribing = false
    var isPreparingModel = false
    var hasDownload = false
    var keyboardIsBusy = false

    var isIdle: Bool {
        !isStarting && !isRecording && !isTranscribing && !isPreparingModel && !hasDownload && !keyboardIsBusy
    }
}

enum StorageMaintenanceError: LocalizedError, Equatable {
    case busy
    case unsafePath

    var errorDescription: String? {
        switch self {
        case .busy: "Die Speicherbereinigung ist nur möglich, wenn kein Diktat, Modellvorgang oder Tastaturvorgang läuft."
        case .unsafePath: "Ein Speicherpfad konnte nicht sicher bereinigt werden."
        }
    }
}

/// App-owned storage maintenance. Production roots are deliberately concrete:
/// app support models, this bundle identifier's cache directory, and explicitly
/// named Klangschrift temporary files. There is no generic Library traversal.
enum StorageMaintenance {
    struct Roots: Sendable {
        let models: URL
        let caches: URL
        let temporary: URL
    }

    static func productionRoots(fileManager: FileManager = .default) -> Roots {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return Roots(
            models: applicationSupport.appendingPathComponent("Klangschrift/Models", isDirectory: true),
            caches: caches.appendingPathComponent(cacheDirectoryIdentifier(), isDirectory: true),
            temporary: fileManager.temporaryDirectory
        )
    }

    static func cacheDirectoryIdentifier(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        bundleIdentifier ?? "io.github.miggidev618.klangschrift"
    }

    static func usage(activeModel: DictationModelID, defaults: UserDefaults = .standard,
                      roots: Roots = productionRoots(), fileManager: FileManager = .default) throws -> StorageMaintenanceUsage {
        let models = try modelDirectories(roots: roots, fileManager: fileManager)
        let totalModels = try models.reduce(0) { partial, item in partial + (try byteCount(at: item.url, fileManager: fileManager)) }
        let removableModels = try models.filter { $0.id != activeModel }.reduce(0) { partial, item in partial + (try byteCount(at: item.url, fileManager: fileManager)) }
        let caches = try byteCount(at: roots.caches, fileManager: fileManager)
        let temporary = try knownTemporaryURLs(in: roots.temporary, fileManager: fileManager)
            .reduce(0) { partial, item in partial + (try byteCount(at: item, fileManager: fileManager)) }
        return StorageMaintenanceUsage(
            historyBytes: TranscriptPersistence.historyByteCount(defaults: defaults),
            downloadedModelBytes: totalModels,
            removableModelBytes: removableModels,
            cacheAndTemporaryBytes: caches + temporary
        )
    }

    @discardableResult
    static func clearHistory(activity: StorageMaintenanceActivity, defaults: UserDefaults = .standard) throws -> Int {
        guard activity.isIdle else { throw StorageMaintenanceError.busy }
        let removed = TranscriptPersistence.historyByteCount(defaults: defaults)
        TranscriptPersistence.clearHistory(defaults: defaults)
        return removed
    }

    @discardableResult
    static func removeDownloadedModels(keeping activeModel: DictationModelID, activity: StorageMaintenanceActivity,
                                       roots: Roots = productionRoots(), fileManager: FileManager = .default) throws -> Int {
        guard activity.isIdle else { throw StorageMaintenanceError.busy }
        var removed = 0
        for item in try modelDirectories(roots: roots, fileManager: fileManager) where item.id != activeModel {
            removed += try byteCount(at: item.url, fileManager: fileManager)
            try removeAllowedDirectory(item.url, root: roots.models, fileManager: fileManager)
        }
        return removed
    }

    @discardableResult
    static func clearCachesAndTemporary(activity: StorageMaintenanceActivity,
                                        roots: Roots = productionRoots(), fileManager: FileManager = .default) throws -> Int {
        guard activity.isIdle else { throw StorageMaintenanceError.busy }
        var removed = try byteCount(at: roots.caches, fileManager: fileManager)
        if fileManager.fileExists(atPath: roots.caches.path) {
            try removeAllowedDirectory(roots.caches, root: roots.caches.deletingLastPathComponent(), fileManager: fileManager)
        }
        for item in try knownTemporaryURLs(in: roots.temporary, fileManager: fileManager) {
            removed += try byteCount(at: item, fileManager: fileManager)
            try removeAllowedItem(item, root: roots.temporary, fileManager: fileManager)
        }
        return removed
    }

    private static func modelDirectories(roots: Roots, fileManager: FileManager) throws -> [(id: DictationModelID, url: URL)] {
        try DictationModelID.allCases.compactMap { id in
            let descriptor = DictationModelDescriptor.descriptor(for: id)
            guard !descriptor.isBundled else { return nil }
            let url = roots.models.appendingPathComponent("\(id.rawValue)-\(descriptor.revision)", isDirectory: true)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            try validateDirectory(url, within: roots.models, fileManager: fileManager)
            return (id, url)
        }
    }

    private static func knownTemporaryURLs(in root: URL, fileManager: FileManager) throws -> [URL] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        try validateDirectory(root, within: root.deletingLastPathComponent(), fileManager: fileManager)
        return try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])
            .filter { $0.lastPathComponent.hasPrefix("klangschrift-") }
            .map { url in
                try validateItem(url, within: root, fileManager: fileManager)
                return url
            }
    }

    private static func byteCount(at root: URL, fileManager: FileManager) throws -> Int {
        guard fileManager.fileExists(atPath: root.path) else { return 0 }
        try validateItem(root, within: root.deletingLastPathComponent(), fileManager: fileManager)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey, .fileSizeKey]
        let values = try root.resourceValues(forKeys: keys)
        if values.isRegularFile == true { return values.fileAllocatedSize ?? values.fileSize ?? 0 }
        guard values.isDirectory == true else { return 0 }
        var total = 0
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: []) else { return 0 }
        for case let url as URL in enumerator {
            let child = try url.resourceValues(forKeys: keys)
            if child.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if child.isRegularFile == true { total += child.fileAllocatedSize ?? child.fileSize ?? 0 }
        }
        return total
    }

    private static func removeAllowedDirectory(_ url: URL, root: URL, fileManager: FileManager) throws {
        try validateDirectory(url, within: root, fileManager: fileManager)
        try fileManager.removeItem(at: url)
    }

    private static func removeAllowedItem(_ url: URL, root: URL, fileManager: FileManager) throws {
        try validateItem(url, within: root, fileManager: fileManager)
        try fileManager.removeItem(at: url)
    }

    private static func validateDirectory(_ url: URL, within root: URL, fileManager: FileManager) throws {
        try validateItem(url, within: root, fileManager: fileManager)
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw StorageMaintenanceError.unsafePath }
    }

    private static func validateItem(_ url: URL, within root: URL, fileManager: FileManager) throws {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        guard path != rootPath, path.hasPrefix(rootPath + "/"),
              try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw StorageMaintenanceError.unsafePath }
    }
}
