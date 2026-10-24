import Foundation

public enum AXSelectionEvidence: Sendable, Equatable {
    /// Controls which do not expose AXSelectedTextRanges are allowed to rely on AXSelectedTextRange.
    case unavailable
    case ranges([TextSelection])
    /// The attribute was present but was not a complete array of valid CFRange values.
    case malformed
}

public enum AXSelectionValidator {
    /// The optional multiple-range attribute is accepted only when it proves the same single selection.
    public static func validate(primary: TextSelection, evidence: AXSelectionEvidence) -> Bool {
        guard primary.location >= 0, primary.length >= 0 else { return false }
        switch evidence {
        case .unavailable: return true
        case let .ranges(ranges): return ranges.count == 1 && ranges[0] == primary
        case .malformed: return false
        }
    }

    /// Compatibility helper for platform-independent callers.
    public static func validate(primary: TextSelection, multiple: [TextSelection]?) -> Bool {
        validate(primary: primary, evidence: multiple.map(AXSelectionEvidence.ranges) ?? .unavailable)
    }
}

public enum AccessibilityInsertionAdapter {
    /// Returns nil unless the existing value, transcript, and final splice are bounded before allocating the result.
    public static func splicedValue(target: AXTextTarget, transcript: String, maximumUTF16Length: Int = 200_000, maximumTranscriptUTF16Length: Int = 50_000, maximumResultUTF16Length: Int? = nil) -> (value: String, selection: TextSelection)? {
        let resultLimit = maximumResultUTF16Length ?? maximumUTF16Length
        guard target.kind == .simpleText, target.isValueWritable, target.hasSingleSelection,
              let value = target.value, let selection = target.selection,
              maximumUTF16Length >= 0, maximumTranscriptUTF16Length >= 0, resultLimit >= 0,
              value.utf16.count <= maximumUTF16Length,
              AXSelectionValidator.validate(primary: selection, multiple: target.hasSingleSelection ? nil : []),
              selection.location <= value.utf16.count,
              selection.length <= value.utf16.count - selection.location else { return nil }
        let transcriptCount = transcript.utf16.count
        let remainingCount = value.utf16.count - selection.length
        guard transcriptCount <= maximumTranscriptUTF16Length,
              transcriptCount <= resultLimit,
              remainingCount <= resultLimit - transcriptCount else { return nil }
        let index = value.utf16.index(value.utf16.startIndex, offsetBy: selection.location)
        let end = value.utf16.index(index, offsetBy: selection.length)
        guard let startIndex = String.Index(index, within: value), let endIndex = String.Index(end, within: value) else { return nil }
        let result = String(value[..<startIndex]) + transcript + String(value[endIndex...])
        return (result, TextSelection(location: selection.location + transcriptCount, length: 0))
    }
}
