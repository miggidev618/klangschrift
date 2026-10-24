import Foundation
import Darwin

/// SDK-free metadata shared with the keyboard. Readiness is never persisted here.
struct KeyboardModelFavorite: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let shortTitle: String
}
struct KeyboardModelFavorites: Codable, Equatable, Sendable {
    var revision = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    var first: KeyboardModelFavorite?
    var second: KeyboardModelFavorite?
    var models: [KeyboardModelFavorite] { [first, second].compactMap { $0 } }
    func contains(_ id: String) -> Bool { models.contains { $0.id == id } }
    var valid: Bool {
        let values = models
        return Set(values.map(\.id)).count == values.count && values.allSatisfy {
            !$0.id.isEmpty && $0.id.utf8.count <= 100 && $0.title.utf8.count <= 160 && $0.shortTitle.utf8.count <= 100
        }
    }
    func matches(modelID: String?, revision: UUID?) -> Bool {
        guard let modelID, let revision else { return false }
        return self.revision == revision && contains(modelID)
    }
}
struct KeyboardModelFavoritesStore {
    private let root: URL
    init?(root: URL? = nil) {
        guard let root = root ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KeyboardBridgeStore.groupID) else { return nil }
        self.root = root
    }
    func read() throws -> KeyboardModelFavorites {
        try locked {
            let file = root.appendingPathComponent("Library/keyboard-model-favorites.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return KeyboardModelFavorites() }
            let data = try Data(contentsOf: file)
            guard data.count <= 4096 else { throw KeyboardBridgeError.unavailable }
            let value = try JSONDecoder().decode(KeyboardModelFavorites.self, from: data)
            guard value.valid else { throw KeyboardBridgeError.unavailable }
            return value
        }
    }
    func migrateIfReady(whisperBaseInstalled: Bool) throws {
        guard whisperBaseInstalled else { return }
        try locked {
            let file = root.appendingPathComponent("Library/keyboard-model-favorites.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            let data = try Data(contentsOf: file)
            guard data.count <= 4096 else { throw KeyboardBridgeError.unavailable }
            let value = try JSONDecoder().decode(KeyboardModelFavorites.self, from: data)
            guard value.valid else { throw KeyboardBridgeError.unavailable }
            let next = value.restrictedToIOSModels(whisperBaseInstalled: true)
            if next != value { try JSONEncoder().encode(next).write(to: file, options: .atomic) }
        }
    }
    func save(_ value: KeyboardModelFavorites) throws {
        guard value.valid else { throw KeyboardBridgeError.unavailable }
        try locked { try JSONEncoder().encode(value).write(to: root.appendingPathComponent("Library/keyboard-model-favorites.json"), options: .atomic) }
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Library"), withIntermediateDirectories: true)
        let fd = open(root.appendingPathComponent("Library/keyboard-model-favorites.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw KeyboardBridgeError.unavailable }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw KeyboardBridgeError.busy }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

// SDK-free because this file is also compiled in the keyboard extension.
extension KeyboardModelFavorites {
    func restrictedToIOSModels(whisperBaseInstalled: Bool) -> Self {
        guard whisperBaseInstalled else { return self }
        let offered: Set<String> = ["whisper-base-coreml", "whisper-base-en-coreml", "whisper-tiny-coreml", "moonshine-small-streaming-de", "moonshine-small-streaming-en", "parakeet-redux-coreml"]
        var next = self
        let fallback = KeyboardModelFavorite(id: "whisper-base-coreml", title: "Whisper Base", shortTitle: "Multi · Whisper Base")
        if let first, !offered.contains(first.id) { next.first = fallback }
        if let second, !offered.contains(second.id) { next.second = fallback }
        if next.first?.id == next.second?.id { next.second = nil }
        if next != self { next.revision = UUID() }
        return next
    }
}
