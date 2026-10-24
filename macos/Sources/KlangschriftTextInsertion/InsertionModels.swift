import Foundation

public enum AXContentContext: Sendable, Equatable { case native, webContent, unknown }
public enum AXTargetKind: Sendable, Equatable { case simpleText, richText, terminal, unsupported }
public struct TextSelection: Sendable, Equatable {
    public let location: Int
    public let length: Int
    public init(location: Int, length: Int) { self.location = location; self.length = length }
}
public struct AXTextTarget: Sendable, Equatable {
    public let kind: AXTargetKind
    public let value: String?
    public let selection: TextSelection?
    public let isValueWritable: Bool
    public let hasSingleSelection: Bool
    public let contentContext: AXContentContext
    public init(kind: AXTargetKind, value: String?, selection: TextSelection?, isValueWritable: Bool, hasSingleSelection: Bool = true, contentContext: AXContentContext = .native) {
        self.kind = kind; self.value = value; self.selection = selection; self.isValueWritable = isValueWritable; self.hasSingleSelection = hasSingleSelection
        self.contentContext = contentContext
    }
}
public enum AXMutationResult: Sendable, Equatable { case confirmed, rejected, uncertain, unavailable }
/// Posting is never confirmation; `.posted` requires a separate AX witness before restoration.
public enum PastePostResult: Sendable, Equatable { case posted, unconfirmed, unavailable }
public enum TextInsertionOutcome: Sendable, Equatable {
    case insertedDirectly
    case insertedByPaste
    /// The paste itself was confirmed, but a concurrent/failed clipboard restoration left the transcript on the clipboard.
    case insertedByPasteClipboardNotRestored
    /// The paste was posted without an AX witness because the target is not AX-readable; insertion could not be confirmed.
    case insertedUncertain
    case cancelledNotProcessed
    case copiedForRecovery(RecoveryReason)
    case recoveryUnavailable(RecoveryReason)
}
public enum InsertionFailure: Error, Sendable, Equatable { case invalidUTF16Selection, directReadbackMismatch, mutationUncertain, pasteboardFailure, pasteUnconfirmed }
public protocol MonotonicClock: Sendable { func nowNanoseconds() -> UInt64 }
public protocol Sleeper: Sendable { func sleep(nanoseconds: UInt64) async }
public protocol RecoveryPresenter: Sendable {
    func presentRecovery() async
    /// Stores only the current session's local recovery draft. It does not
    /// touch pasteboard, AX or event posting; a separate explicit UI copy
    /// action owns any later clipboard write.
    func presentRecovery(draft: String) async
    func presentRecovery(draft: String, session: UUID?) async
    func beginRecovery(session: UUID) async
    func clearRecovery(session: UUID) async
    /// Content-free warning: the confirmed paste succeeded but the previous clipboard could not be restored.
    func presentClipboardRestoreFailed() async
}
public extension RecoveryPresenter {
    func presentRecovery(draft: String) async { await presentRecovery() }
    func presentRecovery(draft: String, session: UUID?) async { await presentRecovery(draft: draft) }
    func beginRecovery(session: UUID) async {}
    func clearRecovery(session: UUID) async {}
    func presentClipboardRestoreFailed() async { await presentRecovery() }
}
public protocol PrivacyDiagnosticSink: Sendable { func recordInsertion(event: InsertionDiagnosticEvent) }
public enum InsertionDiagnosticEvent: String, Sendable { case directConfirmed, pasteConfirmed, pasteClipboardNotRestored, recoveryCopied, deniedProtected, deniedFocus, directUncertain, pasteUnconfirmed, pasteUnverified }

/// A captured focus is held from recording start and revalidated immediately before any mutation.
public protocol FocusTargeting: Sendable {
    func captureFocus() -> FocusLease?
    func revalidate(_ lease: FocusLease) -> CurrentFocus?
    /// Retains/validates the current AX element as a short insertion lease after anchor revalidation.
    func issueInsertionLease(for current: CurrentFocus, nowNanoseconds: UInt64) -> FocusLease?
}
public protocol AXMutation: Sendable {
    func readTextTarget(_ focus: CurrentFocus) -> AXTextTarget?
    func replaceSelectedText(_ text: String, selection: TextSelection, in focus: CurrentFocus) -> AXMutationResult
    func replaceValue(_ value: String, expectedOriginalValue: String, expectedOriginalSelection: TextSelection, in focus: CurrentFocus) -> AXMutationResult
    func readBackValue(in focus: CurrentFocus) -> String?
}
public struct PasteboardItemSnapshot: Sendable, Equatable { public let types: [String: Data]; public init(types: [String: Data]) { self.types = types } }
public struct PasteboardSnapshot: Sendable, Equatable { public let items: [PasteboardItemSnapshot]; public let changeCount: Int; public init(items: [PasteboardItemSnapshot], changeCount: Int) { self.items = items; self.changeCount = changeCount } }
public protocol PasteboardGateway: Sendable {
    /// True only for a supported macOS API path explicitly configured to avoid prompting.
    func supportsAlwaysAllowSnapshot() -> Bool
    func snapshot(maximumItems: Int, maximumBytes: Int, maximumItemBytes: Int) -> PasteboardSnapshot?
    func writeCurrentHostOnlyTranscript(_ text: String) -> Bool
    func changeCount() -> Int
    func restore(_ snapshot: PasteboardSnapshot) -> Bool
}
public protocol PasteEventPosting: Sendable {
    func isPreflightAllowed() -> Bool
    func postCommandV(to processID: Int32) -> PastePostResult
}
/// A rich target is confirmed by its collapsed, post-paste selection instead
/// of rewriting or reading its whole formatted value.
public struct PasteWitness: Sendable, Equatable {
    public let expectedValue: String?
    public let expectedInsertedText: String?
    public let expectedInsertedRange: TextSelection?
    public init(expectedValue: String) { self.expectedValue = expectedValue; self.expectedInsertedText = nil; self.expectedInsertedRange = nil }
    public init(expectedInsertedText: String, expectedInsertedRange: TextSelection) { self.expectedValue = nil; self.expectedInsertedText = expectedInsertedText; self.expectedInsertedRange = expectedInsertedRange }
}
public enum SelectionInsertionPlan {
    public static let maximumTranscriptUTF16Length = 50_000
    public static let maximumRangeUTF16Length = 200_000
    public static func witness(transcript: String, selection: TextSelection) -> PasteWitness? {
        let transcriptLength = transcript.utf16.count
        guard selection.location >= 0, selection.length >= 0,
              transcriptLength <= maximumTranscriptUTF16Length,
              selection.location <= maximumRangeUTF16Length,
              selection.length <= maximumRangeUTF16Length - selection.location,
              transcriptLength <= maximumRangeUTF16Length - selection.location else { return nil }
        return .init(expectedInsertedText: transcript, expectedInsertedRange: .init(location: selection.location, length: transcriptLength))
    }
}
public protocol BoundedPasteWitnessing: Sendable {
    func captureWitness(for target: AXTextTarget, in focus: CurrentFocus, transcript: String) -> PasteWitness?
    func confirms(_ witness: PasteWitness, in focus: CurrentFocus) async -> Bool
}
