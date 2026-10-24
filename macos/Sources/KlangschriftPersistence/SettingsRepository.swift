import Foundation

public enum SettingsLanguage: String, Codable, Sendable, CaseIterable { case automatic, de, en, fr, es, it, pt, nl }
public enum LocalModelProfile: String, Codable, Sendable, CaseIterable { case whisperLargeV3, whisperLargeV3Turbo }
public enum InsertionFallback: String, Codable, Sendable, CaseIterable { case accessibilityThenClipboard, accessibilityThenPaste }
public enum AppearancePreference: String, Codable, Sendable, CaseIterable { case system, light, dark }
public enum PersistedShortcutMode: String, Codable, Sendable, CaseIterable { case pushToTalk, toggle, reinsert }
public enum PersistedFnGlobeProfile: String, Codable, Sendable, CaseIterable { case disabled, functionModifier, globeQualified }

/// Deliberately contains no hardware identifier, signature, or proof material.
public struct PersistedShortcut: Codable, Sendable, Equatable, Hashable {
    public let keyCode: UInt16; public let modifiers: UInt64; public let mode: PersistedShortcutMode; public let fnGlobeProfile: PersistedFnGlobeProfile
    public init(keyCode: UInt16, modifiers: UInt64, mode: PersistedShortcutMode, fnGlobeProfile: PersistedFnGlobeProfile = .disabled) { self.keyCode = keyCode; self.modifiers = modifiers; self.mode = mode; self.fnGlobeProfile = fnGlobeProfile }
    private enum CodingKeys: String, CodingKey, CaseIterable { case keyCode, modifiers, mode, fnGlobeProfile }
    public init(from decoder: any Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); guard c.allKeys.count == CodingKeys.allCases.count else { throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "incomplete shortcut")) }; keyCode = try c.decode(UInt16.self, forKey: .keyCode); modifiers = try c.decode(UInt64.self, forKey: .modifiers); mode = try c.decode(PersistedShortcutMode.self, forKey: .mode); fnGlobeProfile = try c.decode(PersistedFnGlobeProfile.self, forKey: .fnGlobeProfile) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(keyCode, forKey: .keyCode); try c.encode(modifiers, forKey: .modifiers); try c.encode(mode, forKey: .mode); try c.encode(fnGlobeProfile, forKey: .fnGlobeProfile) }
}

public struct PreferencesSnapshot: Codable, Sendable, Equatable {
    public var historyEnabled: Bool = true; public var retention: HistoryRetentionCodable = .forever; public var selectedInputDeviceUID: String? = nil; public var language: SettingsLanguage = .automatic; public var model: LocalModelProfile = .whisperLargeV3; public var shortcuts: [PersistedShortcut] = []; public var insertionFallback: InsertionFallback = .accessibilityThenClipboard; public var appearance: AppearancePreference = .system; public var floatingControlEnabled: Bool = true; public var launchAtLoginDesired: Bool = false
    public init() {}
    private enum CodingKeys: String, CodingKey, CaseIterable { case historyEnabled, retention, selectedInputDeviceUID, language, model, shortcuts, insertionFallback, appearance, floatingControlEnabled, launchAtLoginDesired }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self); guard c.allKeys.count == CodingKeys.allCases.count else { throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "incomplete preferences")) }
        historyEnabled = try c.decode(Bool.self, forKey: .historyEnabled); retention = try c.decode(HistoryRetentionCodable.self, forKey: .retention); let uid = try c.decodeIfPresent(String.self, forKey: .selectedInputDeviceUID); selectedInputDeviceUID = uid?.isEmpty == true ? nil : uid; language = try c.decode(SettingsLanguage.self, forKey: .language); model = try c.decode(LocalModelProfile.self, forKey: .model); shortcuts = try c.decode([PersistedShortcut].self, forKey: .shortcuts); insertionFallback = try c.decode(InsertionFallback.self, forKey: .insertionFallback); appearance = try c.decode(AppearancePreference.self, forKey: .appearance); floatingControlEnabled = try c.decode(Bool.self, forKey: .floatingControlEnabled); launchAtLoginDesired = try c.decode(Bool.self, forKey: .launchAtLoginDesired)
    }
    /// Empty is the canonical encrypted-wire sentinel for "no device". It
    /// decodes back to `nil`, without inventing or retaining a device ID.
    public func encode(to encoder: any Encoder) throws { var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(historyEnabled, forKey: .historyEnabled); try c.encode(retention, forKey: .retention); try c.encode(selectedInputDeviceUID ?? "", forKey: .selectedInputDeviceUID); try c.encode(language, forKey: .language); try c.encode(model, forKey: .model); try c.encode(shortcuts, forKey: .shortcuts); try c.encode(insertionFallback, forKey: .insertionFallback); try c.encode(appearance, forKey: .appearance); try c.encode(floatingControlEnabled, forKey: .floatingControlEnabled); try c.encode(launchAtLoginDesired, forKey: .launchAtLoginDesired) }
}

public enum HistoryRetentionCodable: String, Codable, Sendable { case forever, days7, days14, days30, days90, none; var value: HistoryRetention { switch self { case .forever: .forever; case .days7: .days7; case .days14: .days14; case .days30: .days30; case .days90: .days90; case .none: .none } }; init(_ retention: HistoryRetention) { self = switch retention { case .forever: .forever; case .days7: .days7; case .days14: .days14; case .days30: .days30; case .days90: .days90; case .none: .none } } }
public struct PreferencesRecord: Sendable, Equatable { public let snapshot: PreferencesSnapshot; public let revision: Int64 }
public struct PreferencesSaveResult: Sendable, Equatable { public let record: PreferencesRecord; public let previousRetention: HistoryRetentionCodable; public let newRetention: HistoryRetentionCodable; public let revision: Int64 }
public enum SettingsFaultPoint: Sendable { case beforeCommit, afterCommitBeforeNotify }

/// Strict encrypted wire envelope. The public marker remains `v1`; this version is for the encrypted payload.
struct PreferencesEnvelope: Codable, Sendable {
    let version: Int; let preferences: PreferencesSnapshot
    private enum CodingKeys: String, CodingKey, CaseIterable { case version, preferences }
    init(preferences: PreferencesSnapshot) { version = 1; self.preferences = preferences }
    init(from decoder: any Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); guard c.allKeys.count == CodingKeys.allCases.count else { throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "incomplete preferences envelope")) }; version = try c.decode(Int.self, forKey: .version); preferences = try c.decode(PreferencesSnapshot.self, forKey: .preferences); guard version == 1 else { throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "unknown preferences version")) } }
}

/// JSONDecoder accepts duplicate and unknown keys. Settings ciphertext is a persistence boundary, so inspect raw JSON before decoding.
enum StrictPreferencesJSON {
    static let byteLimit = 64 * 1024
    static func encode(_ snapshot: PreferencesSnapshot) throws -> Data { try JSONEncoder().encode(PreferencesEnvelope(preferences: snapshot)) }
    static func decode(_ data: Data) throws -> PreferencesSnapshot {
        guard !data.isEmpty, data.count <= byteLimit, String(data: data, encoding: .utf8) != nil else { throw DatabaseFailure.wrongKeyOrTampered }
        do { _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]); var scanner = KeyScanner(data); try scanner.validate(); return try JSONDecoder().decode(PreferencesEnvelope.self, from: data).preferences } catch { throw DatabaseFailure.wrongKeyOrTampered }
    }
    private struct KeyScanner {
        let bytes: [UInt8]; var offset = 0
        init(_ data: Data) { bytes = Array(data) }
        enum Context { case envelope, preferences, shortcut, unknown }
        mutating func validate() throws { try value(context: .envelope); whitespace(); guard offset == bytes.count else { throw DatabaseFailure.wrongKeyOrTampered } }
        mutating func value(context: Context) throws { whitespace(); guard offset < bytes.count else { throw DatabaseFailure.wrongKeyOrTampered }; switch bytes[offset] { case 123: try object(context: context); case 91: try array(context: context); case 34: _ = try string(); case 116: try literal("true"); case 102: try literal("false"); case 110: try literal("null"); case 45, 48...57: try number(); default: throw DatabaseFailure.wrongKeyOrTampered } }
        mutating func object(context: Context) throws { advance(); whitespace(); var seen = Set<String>(); var count = 0; if consume(125) { try exactCount(count, context); return }; while true { whitespace(); let key = try string(); guard seen.insert(key).inserted, allowed(key, context) else { throw DatabaseFailure.wrongKeyOrTampered }; count += 1; whitespace(); guard consume(58) else { throw DatabaseFailure.wrongKeyOrTampered }; if context == .preferences && key == "shortcuts" { try array(context: .shortcut) } else { try value(context: context == .envelope && key == "preferences" ? .preferences : .unknown) }; whitespace(); if consume(125) { try exactCount(count, context); return }; guard consume(44) else { throw DatabaseFailure.wrongKeyOrTampered } } }
        mutating func array(context: Context) throws { advance(); whitespace(); if consume(93) { return }; while true { try value(context: context); whitespace(); if consume(93) { return }; guard consume(44) else { throw DatabaseFailure.wrongKeyOrTampered } } }
        func allowed(_ key: String, _ context: Context) -> Bool { switch context { case .envelope: ["version", "preferences"].contains(key); case .preferences: ["historyEnabled", "retention", "selectedInputDeviceUID", "language", "model", "shortcuts", "insertionFallback", "appearance", "floatingControlEnabled", "launchAtLoginDesired"].contains(key); case .shortcut: ["keyCode", "modifiers", "mode", "fnGlobeProfile"].contains(key); case .unknown: false } }
        func exactCount(_ count: Int, _ context: Context) throws { let expected: Int = switch context { case .envelope: 2; case .preferences: 10; case .shortcut: 4; case .unknown: 0 }; guard count == expected else { throw DatabaseFailure.wrongKeyOrTampered } }
        mutating func string() throws -> String { guard consume(34) else { throw DatabaseFailure.wrongKeyOrTampered }; let start = offset - 1; var escaped = false; while offset < bytes.count { let b = bytes[offset]; offset += 1; if escaped { escaped = false; continue }; if b == 92 { escaped = true; continue }; if b == 34 { let raw = Data(bytes[start..<offset]); guard let decoded = try? JSONDecoder().decode(String.self, from: raw) else { throw DatabaseFailure.wrongKeyOrTampered }; return decoded }; if b < 0x20 { throw DatabaseFailure.wrongKeyOrTampered } }; throw DatabaseFailure.wrongKeyOrTampered }
        mutating func number() throws { let start = offset; _ = consume(45); guard offset < bytes.count else { throw DatabaseFailure.wrongKeyOrTampered }; if !consume(48) { try digits() }; if consume(46) { try digits() }; if offset < bytes.count && (bytes[offset] == 69 || bytes[offset] == 101) { advance(); if offset < bytes.count && (bytes[offset] == 43 || bytes[offset] == 45) { advance() }; try digits() }; guard offset > start else { throw DatabaseFailure.wrongKeyOrTampered } }
        mutating func digits() throws { let start = offset; while offset < bytes.count, (48...57).contains(bytes[offset]) { advance() }; guard offset > start else { throw DatabaseFailure.wrongKeyOrTampered } }
        mutating func literal(_ text: String) throws { let chars = Array(text.utf8); guard offset + chars.count <= bytes.count, Array(bytes[offset..<(offset + chars.count)]) == chars else { throw DatabaseFailure.wrongKeyOrTampered }; offset += chars.count }
        mutating func whitespace() { while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { advance() } }
        mutating func advance() { offset += 1 }
        mutating func consume(_ byte: UInt8) -> Bool { guard offset < bytes.count, bytes[offset] == byte else { return false }; offset += 1; return true }
    }
}
