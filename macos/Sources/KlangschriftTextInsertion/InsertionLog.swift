import os

/// Closed, content-free vocabulary. No API accepts text, bundle IDs, AX values,
/// raw AX roles, clipboard data, or caller-supplied message strings.
public enum InsertionLog {
    public enum Stage: String, Sendable { case capture, revalidate, issueLease, fieldValidation }
    public enum FocusFailure: String, Sendable { case axNotTrusted, noFocusedApp, noFocusedElement, noBundle, noPID, missingElement, elementMismatch, pidMismatch, bundleMismatch }
    public enum Step: String, Sendable, CaseIterable {
        case insertionStarted, insertionFinished, cancelled, queueRejected, anchorMismatch
        case focusedWindowSearch, manualAccessibilityEnabled
        case focusKnownAppRoute, focusFrontmostMismatch, focusSystemRoute, focusFrontmostRoute, focusSystemFailed, focusFrontmostFailed, ownAppRejected
        case webContentPaste, webContentUnknown, richWitnessRejected, pasteWitnessRejected, pasteFinalFocusRejected, spliceRejected
        case pasteStarted, snapshotRetry, snapshotRejected, snapshotCancelled, transcriptWriteUncertain, transcriptReady
        case pasteClaimRejected, postPosted, postUnconfirmed, postUnavailable, verifierFocusRejected
        case coordinatorStartRejected, coordinatorStartInvalidated, coordinatorInsertRejected, coordinatorInsertStarted, coordinatorInsertFinished
    }
    public enum Flag: String, Sendable { case fieldEditable, leaseAtStart, sessionPresent, selectionPresent, singleSelection, valueWritable, witnessMatches, verifierConfirmed, readbackMatches, preflightAllowed, snapshotAllowed, snapshotStable, restoreSucceeded }
    public enum SnapshotReason: String, Sendable, CaseIterable {
        case captured, accessDenied, invalidLimits, tooManyItems, missingTypes
        case itemsUnavailable, dataUnavailable, itemTooLarge, totalTooLarge, versionChanged, prewriteVersionChanged, unavailable
    }
    public enum Role: String, Sendable { case textField, textArea, webArea, other, unavailable }
    public enum Entry: Sendable {
        case snapshot(SnapshotReason, items: Int, types: Int, countDelta: Int)
        case focusFailure(Stage, FocusFailure)
        case step(Step)
        case flag(Flag, Bool)
        case classification(EditableTargetClassification)
        case decision(InsertionDecision)
        case target(AXTargetKind?)
        case role(Role)
        case mutation(AXMutationResult)
        case recovery(RecoveryReason)
        case event(InsertionDiagnosticEvent)

        public var code: String {
            switch self {
            case let .snapshot(reason, items, types, delta): return "snapshot.\(reason.rawValue).items.\(max(0, items)).types.\(max(0, types)).countDelta.\(delta)"
            case let .focusFailure(stage, reason): return "focus.\(stage.rawValue).\(reason.rawValue)"
            case .step(.focusedWindowSearch): return "focus.route.focusedWindowSearch"
            case .step(.manualAccessibilityEnabled): return "focus.manualAccessibilityEnabled"
            case let .step(step): return "step.\(step.rawValue)"
            case let .flag(flag, value): return "flag.\(flag.rawValue).\(value ? "true" : "false")"
            case let .classification(value): return "classification.\(value.rawValue)"
            case let .decision(value):
                switch value {
                case .accessibility: return "policy.accessibility"
                case .clipboardFallback: return "policy.clipboardFallback"
                case let .recovery(reason): return "policy.recovery.\(reason.rawValue)"
                }
            case let .target(value): return "target.\(value.map { String(describing: $0) } ?? "unavailable")"
            case let .role(value): return "role.\(value.rawValue)"
            case let .mutation(value): return "ax.\(String(describing: value))"
            case let .recovery(reason): return "recovery.\(reason.rawValue)"
            case let .event(value): return "event.\(value.rawValue)"
            }
        }
    }
    private static let logger = Logger(subsystem: "io.github.miggidev618.klangschrift", category: "insertion")
    public static func record(_ entry: Entry) { logger.notice("\(entry.code, privacy: .public)") }
}
