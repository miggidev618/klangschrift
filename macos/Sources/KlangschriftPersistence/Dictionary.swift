import Foundation

public enum DictionaryEntryKind: String, Sendable, CaseIterable { case recognitionHint, replacement }
public enum DictionaryMatchMode: String, Sendable, CaseIterable { case literal, wholeWord }
public struct DictionaryEntry: Sendable, Equatable {
    public let id: UUID; public let kind: DictionaryEntryKind; public let source: String; public let replacement: String; public let recognitionHint: String?
    public let enabled: Bool; public let matchMode: DictionaryMatchMode; public let caseSensitive: Bool; public let sortOrder: Int64; public let revision: Int64
    public init(id: UUID, kind: DictionaryEntryKind, source: String, replacement: String, recognitionHint: String?, enabled: Bool, matchMode: DictionaryMatchMode, caseSensitive: Bool, sortOrder: Int64, revision: Int64) { self.id = id; self.kind = kind; self.source = source; self.replacement = replacement; self.recognitionHint = recognitionHint; self.enabled = enabled; self.matchMode = matchMode; self.caseSensitive = caseSensitive; self.sortOrder = sortOrder; self.revision = revision }
}
public struct DictionaryDraft: Sendable, Equatable {
    public let kind: DictionaryEntryKind; public let source: String; public let replacement: String; public let recognitionHint: String?; public let enabled: Bool; public let matchMode: DictionaryMatchMode; public let caseSensitive: Bool; public let sortOrder: Int64
    public init(kind: DictionaryEntryKind, source: String, replacement: String = "", recognitionHint: String? = nil, enabled: Bool = true, matchMode: DictionaryMatchMode = .literal, caseSensitive: Bool = false, sortOrder: Int64 = 0) { self.kind = kind; self.source = source; self.replacement = replacement; self.recognitionHint = recognitionHint; self.enabled = enabled; self.matchMode = matchMode; self.caseSensitive = caseSensitive; self.sortOrder = sortOrder }
}
public struct DictionaryCursor: Sendable, Equatable { public let sortOrder: Int64; public let id: UUID; public init(sortOrder: Int64, id: UUID) { self.sortOrder = sortOrder; self.id = id } }
public struct DictionaryPage: Sendable, Equatable { public let entries: [DictionaryEntry]; public let next: DictionaryCursor? }
public enum DictionaryTransformFailure: Error, Equatable, Sendable { case invalidInput, outputLimit }

/// Bounded, deterministic, single-pass replacement. The folded trie retains the
/// original Character range for every expanded scalar (e.g. ß -> ss).
public enum DictionaryTransformer {
    public static let maximumInputBytes = 100 * 1024
    public static let maximumOutputBytes = 200 * 1024
    public static let maximumCompiledBytes = 16 * 1024 * 1024
    private static let posix = Locale(identifier: "en_US_POSIX")
    public struct Compiled: Sendable {
        fileprivate let rules: [DictionaryEntry]; fileprivate let normal: CharacterTrie; fileprivate let folded: ScalarTrie; fileprivate let foldedSources: [UUID: [Unicode.Scalar]]
        public let estimatedBytes: Int
        fileprivate init(_ entries: [DictionaryEntry]) {
            var selected: [RuleKey: DictionaryEntry] = [:]
            for entry in entries where entry.kind == .replacement && entry.enabled && !entry.source.isEmpty {
                let key = RuleKey(source: entry.source, caseSensitive: entry.caseSensitive, mode: entry.matchMode)
                if let old = selected[key], old.id.uuidString <= entry.id.uuidString { continue }
                selected[key] = entry
            }
            rules = selected.values.sorted(by: DictionaryTransformer.precedes)
            normal = CharacterTrie(rules: rules.filter(\.caseSensitive)); folded = ScalarTrie(rules: rules.filter { !$0.caseSensitive })
            foldedSources = Dictionary(uniqueKeysWithValues: rules.filter { !$0.caseSensitive }.map { ($0.id, DictionaryTransformer.fold($0.source)) })
            estimatedBytes = normal.estimatedBytes + folded.estimatedBytes + rules.reduce(0) { $0 + $1.source.utf8.count + $1.replacement.utf8.count + 128 }
        }
    }
    public static func compile(_ entries: [DictionaryEntry]) -> Compiled { Compiled(entries) }
    public static func estimatedCompiledBytes(_ entries: [DictionaryEntry]) -> Int { compile(entries).estimatedBytes }
    /// Conservative pre-commit bound. It deliberately overcharges every source
    /// scalar so admission never accepts a set that a later trie build cannot hold.
    public static func admissionBytes(_ entries: [DictionaryEntry]) -> Int {
        var total = 0
        for rule in entries {
            let (next, overflow) = total.addingReportingOverflow(admissionBytes(for: rule))
            if overflow { return .max }; total = next
        }
        return total
    }
    public static func admissionBytes(for rule: DictionaryEntry) -> Int {
        guard rule.kind == .replacement && rule.enabled else { return 0 }
        let foldedScalars = fold(rule.source).count
        let (cost, overflow) = rule.source.utf8.count.addingReportingOverflow(rule.replacement.utf8.count + 128 + foldedScalars * 128 + rule.source.unicodeScalars.count * 128)
        return overflow ? .max : cost
    }
    public static func apply(_ text: String, entries: [DictionaryEntry], maximumOutputBytes: Int = maximumOutputBytes) throws -> String { try apply(text, compiled: compile(entries), maximumOutputBytes: maximumOutputBytes) }
    public static func apply(_ text: String, compiled: Compiled, maximumOutputBytes: Int = maximumOutputBytes) throws -> String {
        guard maximumOutputBytes > 0, maximumOutputBytes <= Self.maximumOutputBytes, text.utf8.count <= maximumInputBytes, compiled.estimatedBytes <= maximumCompiledBytes else { throw DatabaseFailure.resourceLimit }
        let foldedInput = compiled.folded.isEmpty ? nil : FoldedInput(text); var output = "", cursor = text.startIndex
        while cursor < text.endIndex {
            var candidates = compiled.normal.isEmpty ? [] : compiled.normal.candidates(in: text, at: cursor)
            if let foldedInput { candidates.append(contentsOf: compiled.folded.candidates(in: foldedInput, at: cursor)) }; candidates.sort(by: precedes)
            var winner: (DictionaryEntry, String.Index)?
            for rule in candidates {
                let end = rule.caseSensitive ? normalEnd(rule, in: text, at: cursor) : foldedInput?.end(of: compiled.foldedSources[rule.id] ?? [], at: cursor)
                guard let end, rule.matchMode != .wholeWord || wholeWord(in: text, start: cursor, end: end) else { continue }
                winner = (rule, end); break
            }
            if let winner { output += winner.0.replacement; cursor = winner.1 } else { output.append(text[cursor]); cursor = text.index(after: cursor) }
            guard output.utf8.count <= maximumOutputBytes else { throw DatabaseFailure.resourceLimit }
        }
        return output
    }
    fileprivate static func precedes(_ lhs: DictionaryEntry, _ rhs: DictionaryEntry) -> Bool { lhs.source.utf8.count == rhs.source.utf8.count ? lhs.id.uuidString < rhs.id.uuidString : lhs.source.utf8.count > rhs.source.utf8.count }
    private struct RuleKey: Hashable { let source: String; let caseSensitive: Bool; let mode: DictionaryMatchMode }
    private static func normalUnit(_ character: Character) -> String { String(character).precomposedStringWithCanonicalMapping }
    /// Compatibility permits ligatures/width forms, but never diacritic folding.
    fileprivate static func fold(_ value: String) -> [Unicode.Scalar] {
        let scalars = value.unicodeScalars
        if scalars.allSatisfy(\.isASCII) { return scalars.map { Unicode.Scalar($0.value >= 65 && $0.value <= 90 ? $0.value + 32 : $0.value)! } }
        return Array(value.decomposedStringWithCompatibilityMapping.folding(options: [.caseInsensitive, .widthInsensitive], locale: posix).unicodeScalars)
    }
    private static func normalEnd(_ rule: DictionaryEntry, in text: String, at start: String.Index) -> String.Index? { var index = start; for expected in rule.source { guard index < text.endIndex, normalUnit(text[index]) == normalUnit(expected) else { return nil }; index = text.index(after: index) }; return index }
    private static func wholeWord(in text: String, start: String.Index, end: String.Index) -> Bool { let before = start > text.startIndex ? text[text.index(before: start)] : nil, after = end < text.endIndex ? text[end] : nil; return !isWord(before) && !isWord(after) }
    private static func isWord(_ value: Character?) -> Bool { value?.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0) || $0 == "_" } ?? false }
    fileprivate struct FoldedInput {
        struct Unit { let scalar: Unicode.Scalar; let start: String.Index; let end: String.Index }
        let units: [Unit]; let starts: [String.Index: Int]
        init(_ text: String) { var values: [Unit] = [], offsets: [String.Index: Int] = [:], foldCache: [Character: [Unicode.Scalar]] = [:]; var index = text.startIndex; while index < text.endIndex { let end = text.index(after: index); offsets[index] = values.count; let character = text[index]; if character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first, scalar.isASCII { values.append(.init(scalar: Unicode.Scalar(scalar.value >= 65 && scalar.value <= 90 ? scalar.value + 32 : scalar.value)!, start: index, end: end)) } else { let folded = foldCache[character] ?? DictionaryTransformer.fold(String(character)); foldCache[character] = folded; for scalar in folded { values.append(.init(scalar: scalar, start: index, end: end)) } }; index = end }; units = values; starts = offsets }
        func end(of wanted: [Unicode.Scalar], at start: String.Index) -> String.Index? { guard let offset = starts[start], !wanted.isEmpty, offset + wanted.count <= units.count else { return nil }; for (index, scalar) in wanted.enumerated() where units[offset + index].scalar != scalar { return nil }; return units[offset + wanted.count - 1].end }
    }
    fileprivate struct CharacterTrie: Sendable {
        struct Node: Sendable { var children: [String: Int] = [:]; var terminal: [DictionaryEntry] = [] }
        var nodes: [Node] = [.init()]; var estimatedBytes = 0
        var isEmpty: Bool { nodes.count == 1 && nodes[0].children.isEmpty }
        init(rules: [DictionaryEntry]) { for rule in rules { var node = 0; for char in rule.source { let unit = DictionaryTransformer.normalUnit(char); if let next = nodes[node].children[unit] { node = next } else { nodes.append(.init()); let next = nodes.count - 1; nodes[node].children[unit] = next; node = next; estimatedBytes += 96 + unit.utf8.count }; nodes[node].terminal.append(rule); estimatedBytes += 16 } } }
        func candidates(in text: String, at start: String.Index) -> [DictionaryEntry] { var node = 0, index = start, result: [DictionaryEntry] = []; while index < text.endIndex, let next = nodes[node].children[DictionaryTransformer.normalUnit(text[index])] { node = next; index = text.index(after: index); result.append(contentsOf: nodes[node].terminal) }; return result }
    }
    fileprivate struct ScalarTrie: Sendable {
        struct Node: Sendable { var children: [Unicode.Scalar: Int] = [:]; var terminal: [DictionaryEntry] = [] }
        var nodes: [Node] = [.init()]; var estimatedBytes = 0
        var isEmpty: Bool { nodes.count == 1 && nodes[0].children.isEmpty }
        init(rules: [DictionaryEntry]) { for rule in rules { var node = 0; for scalar in DictionaryTransformer.fold(rule.source) { if let next = nodes[node].children[scalar] { node = next } else { nodes.append(.init()); let next = nodes.count - 1; nodes[node].children[scalar] = next; node = next; estimatedBytes += 128 }; nodes[node].terminal.append(rule); estimatedBytes += 16 } } }
        func candidates(in input: FoldedInput, at start: String.Index) -> [DictionaryEntry] { guard let begin = input.starts[start] else { return [] }; var node = 0, result: [DictionaryEntry] = []; for unit in input.units[begin...] { guard let next = nodes[node].children[unit.scalar] else { break }; node = next; result.append(contentsOf: nodes[node].terminal) }; return result }
    }
}
