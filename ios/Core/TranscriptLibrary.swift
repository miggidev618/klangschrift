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

    static func loadSpellings(defaults: UserDefaults = .standard) throws -> [PersonalSpelling] {
        guard let data = defaults.data(forKey: spellingsKey) else { return [] }
        guard let value = try? JSONDecoder().decode([PersonalSpelling].self, from: data) else { throw TranscriptPersistenceError.spellingsUnreadable }
        return value
    }

    static func saveSpellings(_ value: [PersonalSpelling], defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(value), forKey: spellingsKey)
    }
}
