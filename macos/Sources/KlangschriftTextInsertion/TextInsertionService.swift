import AppKit
import Foundation

/// Per-request reducer: after an AX or clipboard/event path may mutate, no second mutation path is legal.
public struct InsertionAttemptReducer: Sendable {
    public private(set) var claimed: InsertionMutationKind?
    public init() {}
    public mutating func claim(_ kind: InsertionMutationKind) -> Bool {
        guard claimed == nil else { return false }
        claimed = kind
        return true
    }
}
public enum InsertionMutationKind: Sendable { case ax, paste }

public actor TextInsertionService {
    private struct FIFOWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    private let focus: any FocusTargeting
    private let ax: any AXMutation
    private let pasteboard: any PasteboardGateway
    private let poster: any PasteEventPosting
    private let verifier: any BoundedPasteWitnessing
    private let clock: any MonotonicClock
    private let recovery: any RecoveryPresenter
    private let diagnostics: any PrivacyDiagnosticSink
    private let policy: InsertionPolicy
    private let pastePoster = PasteEventPoster()
    private var gateTaken = false
    private var waiters: [FIFOWaiter] = []
    private var cancelledWaiters: Set<UUID> = []
    private var pendingWaiterInstallations: Set<UUID> = []
    private let onQueuedForTesting: (@Sendable () -> Void)?
    private let onGateAcquiredForTesting: (@Sendable () -> Void)?
    private let sleeper: any Sleeper
    private var recoverySession: UUID?
    public init(focus: any FocusTargeting, ax: any AXMutation, pasteboard: any PasteboardGateway, poster: any PasteEventPosting, verifier: any BoundedPasteWitnessing, clock: any MonotonicClock, sleeper: any Sleeper, recovery: any RecoveryPresenter, diagnostics: any PrivacyDiagnosticSink, policy: InsertionPolicy = .init(), onQueuedForTesting: (@Sendable () -> Void)? = nil, onGateAcquiredForTesting: (@Sendable () -> Void)? = nil) {
        self.focus = focus; self.ax = ax; self.pasteboard = pasteboard; self.poster = poster; self.verifier = verifier; self.clock = clock; self.recovery = recovery; self.diagnostics = diagnostics; self.policy = policy
        self.sleeper = sleeper
        self.onQueuedForTesting = onQueuedForTesting
        self.onGateAcquiredForTesting = onGateAcquiredForTesting
    }
    public func beginRecording() -> FocusLease? {
        let lease = focus.captureFocus()
        InsertionLog.record(.flag(.leaseAtStart, lease != nil))
        return lease
    }
    public func beginRecoverySession(_ session: UUID) async { recoverySession = session; await recovery.beginRecovery(session: session) }
    public func clearRecoverySession(_ session: UUID) async { guard recoverySession == session else { return }; recoverySession = nil; await recovery.clearRecovery(session: session) }
    public func insert(transcript: String, from lease: FocusLease?) async -> TextInsertionOutcome {
        InsertionLog.record(.step(.insertionStarted))
        InsertionLog.record(.flag(.leaseAtStart, lease != nil))
        defer { InsertionLog.record(.step(.insertionFinished)) }
        guard await enterFIFO() else { InsertionLog.record(.step(.queueRejected)); return .cancelledNotProcessed }
        defer { leaveFIFO() }
        guard !insertionCancelled else { return .cancelledNotProcessed }
        guard let anchor = lease, let current = focus.revalidate(anchor), policy.matchesAnchor(anchor, current: current) else { InsertionLog.record(.step(.anchorMismatch)); return await copyRecovery(.focusDrift, transcript: transcript) }
        InsertionLog.record(.classification(current.classification))
        let now = clock.nowNanoseconds()
        guard let lease = focus.issueInsertionLease(for: current, nowNanoseconds: now) else { return await copyRecovery(.focusDrift, transcript: transcript) }
        let decision = loggedDecision(lease: lease, current: current, nowNanoseconds: now, accessibilityAvailable: true, clipboardMaterializable: true)
        guard case .accessibility = decision else {
            if case let .recovery(reason) = decision {
                return await copyRecovery(reason, transcript: transcript)
            }
            return await copyRecovery(.unknownTarget, transcript: transcript)
        }
        guard current.classification == .editable else { return await copyRecovery(.targetNotEditable, transcript: transcript) }
        var reducer = InsertionAttemptReducer()
        let initialTarget = loggedTextTarget(current)
        if let target = initialTarget, target.contentContext != .native {
            guard target.contentContext == .webContent else {
                InsertionLog.record(.step(.webContentUnknown))
                return await copyRecovery(.accessibilityUnavailable, transcript: transcript)
            }
            InsertionLog.record(.step(.webContentPaste))
            return await pasteOrRecovery(transcript: transcript, target: target, anchor: lease, initialFocus: current)
        }
        if let target = initialTarget, target.kind == .richText {
            guard let selection = target.selection, let witness = SelectionInsertionPlan.witness(transcript: transcript, selection: selection), loggedWitness(for: target, in: current, transcript: transcript) == witness else {
                InsertionLog.record(.step(.richWitnessRejected))
                return await copyRecovery(.accessibilityUnavailable, transcript: transcript)
            }
            if target.isValueWritable {
                guard !insertionCancelled, reducer.claim(.ax) else { return .cancelledNotProcessed }
                let result = ax.replaceSelectedText(transcript, selection: selection, in: current)
                InsertionLog.record(.mutation(result))
                switch result {
                case .confirmed where await loggedConfirmation(witness, in: current):
                    diagnostics.recordInsertion(event: .directConfirmed)
                    return .insertedDirectly
                case .confirmed, .rejected, .uncertain, .unavailable:
                    diagnostics.recordInsertion(event: .directUncertain)
                    return await copyRecovery(.accessibilityUnavailable, transcript: transcript, preserveAfterPossibleMutation: true)
                }
            }
            // Selection is readable but not AX-settable: the prepared
            // witness authorizes the bounded paste path before any full-value write.
            return await pasteOrRecovery(transcript: transcript, target: target, anchor: lease, initialFocus: current)
        }
        if let target = loggedTextTarget(current), target.contentContext == .native, let splice = AccessibilityInsertionAdapter.splicedValue(target: target, transcript: transcript) {
            guard !insertionCancelled else { return .cancelledNotProcessed }
            guard reducer.claim(.ax) else { return .recoveryUnavailable(.accessibilityUnavailable) }
            let result = ax.replaceValue(splice.value, expectedOriginalValue: target.value ?? "", expectedOriginalSelection: target.selection ?? .init(location: -1, length: -1), in: current)
            InsertionLog.record(.mutation(result))
            switch result {
            case .confirmed:
                if loggedReadbackMatches(splice.value, in: current) { diagnostics.recordInsertion(event: .directConfirmed); return .insertedDirectly }
                diagnostics.recordInsertion(event: .directUncertain)
                return await copyRecovery(.accessibilityUnavailable, transcript: transcript, preserveAfterPossibleMutation: true)
            case .rejected, .uncertain, .unavailable:
                diagnostics.recordInsertion(event: .directUncertain)
                return await copyRecovery(.accessibilityUnavailable, transcript: transcript, preserveAfterPossibleMutation: true)
            }
        }
        // An unreadable, protected, or changed target is always a local
        // recovery/copy flow. The only paste path above requires the same
        // focused element and a bounded selection witness.
        InsertionLog.record(.step(.spliceRejected))
        return await copyRecovery(.accessibilityUnavailable, transcript: transcript)
    }
    private var insertionCancelled: Bool {
        let cancelled = Task.isCancelled
        if cancelled { InsertionLog.record(.step(.cancelled)) }
        return cancelled
    }
    private func loggedDecision(lease: FocusLease, current: CurrentFocus, nowNanoseconds: UInt64, accessibilityAvailable: Bool, clipboardMaterializable: Bool) -> InsertionDecision {
        let decision = policy.decide(lease: lease, current: current, nowNanoseconds: nowNanoseconds, accessibilityAvailable: accessibilityAvailable, clipboardMaterializable: clipboardMaterializable)
        InsertionLog.record(.decision(decision))
        return decision
    }
    private func loggedTextTarget(_ current: CurrentFocus) -> AXTextTarget? {
        let target = ax.readTextTarget(current)
        InsertionLog.record(.target(target?.kind))
        InsertionLog.record(.flag(.selectionPresent, target?.selection != nil))
        InsertionLog.record(.flag(.singleSelection, target?.hasSingleSelection == true))
        InsertionLog.record(.flag(.valueWritable, target?.isValueWritable == true))
        return target
    }
    private func expectedPasteWitness(for target: AXTextTarget, transcript: String) -> PasteWitness? {
        switch target.kind {
        case .simpleText:
            guard let splice = AccessibilityInsertionAdapter.splicedValue(target: target, transcript: transcript) else { return nil }
            return PasteWitness(expectedValue: splice.value)
        case .richText:
            return target.selection.flatMap { SelectionInsertionPlan.witness(transcript: transcript, selection: $0) }
        case .terminal, .unsupported:
            return nil
        }
    }
    private func loggedWitness(for target: AXTextTarget, in current: CurrentFocus, transcript: String) -> PasteWitness? {
        let witness = verifier.captureWitness(for: target, in: current, transcript: transcript)
        InsertionLog.record(.flag(.witnessMatches, witness != nil && witness == expectedPasteWitness(for: target, transcript: transcript)))
        return witness
    }
    private func loggedConfirmation(_ witness: PasteWitness, in current: CurrentFocus) async -> Bool {
        let confirmed = await verifier.confirms(witness, in: current)
        InsertionLog.record(.flag(.verifierConfirmed, confirmed))
        return confirmed
    }
    private func loggedReadbackMatches(_ expected: String, in current: CurrentFocus) -> Bool {
        let matches = ax.readBackValue(in: current) == expected
        InsertionLog.record(.flag(.readbackMatches, matches))
        return matches
    }
    private func enterFIFO() async -> Bool {
        guard !insertionCancelled else { return false }
        if !gateTaken {
            gateTaken = true
            onGateAcquiredForTesting?()
            return true
        }
        let id = UUID()
        pendingWaiterInstallations.insert(id)
        let acquired = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                pendingWaiterInstallations.remove(id)
                if cancelledWaiters.remove(id) != nil || insertionCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(FIFOWaiter(id: id, continuation: continuation))
                    onQueuedForTesting?()
                }
            }
        }, onCancel: {
            Task { await self.cancelQueuedWaiter(id) }
        })
        guard acquired else { return false }
        onGateAcquiredForTesting?()
        return true
    }
    private func cancelQueuedWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            // Only a continuation that has not been installed needs a tombstone. A request already
            // resumed by leaveFIFO will observe insertionCancelled at the next mutation guard.
            if pendingWaiterInstallations.contains(id) { cancelledWaiters.insert(id) }
            return
        }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
    private func leaveFIFO() {
        guard !waiters.isEmpty else { gateTaken = false; return }
        waiters.removeFirst().continuation.resume(returning: true)
    }
    private func pasteOrRecovery(transcript: String, target: AXTextTarget, anchor: FocusLease, initialFocus: CurrentFocus) async -> TextInsertionOutcome {
        // Everything through the transaction start is read-only. In
        // particular, a clipboard write is not allowed before preflight,
        // identity and the rich selection witness have all been checked.
        InsertionLog.record(.step(.pasteStarted))
        let preflightAllowed = poster.isPreflightAllowed()
        InsertionLog.record(.flag(.preflightAllowed, preflightAllowed))
        guard preflightAllowed, !insertionCancelled else {
            return insertionCancelled ? .cancelledNotProcessed : await copyRecovery(.accessibilityUnavailable, transcript: transcript)
        }
        let now = clock.nowNanoseconds()
        guard let prepared = focus.revalidate(anchor), prepared == initialFocus,
              let commitLease = focus.issueInsertionLease(for: prepared, nowNanoseconds: now),
              case .accessibility = loggedDecision(lease: commitLease, current: prepared, nowNanoseconds: now, accessibilityAvailable: true, clipboardMaterializable: true),
              let expectedWitness = expectedPasteWitness(for: target, transcript: transcript),
              loggedWitness(for: target, in: prepared, transcript: transcript) == expectedWitness else {
            return await copyRecovery(.focusDrift, transcript: transcript)
        }
        let witness = expectedWitness
        guard !insertionCancelled else { return .cancelledNotProcessed }
        let transaction: PasteboardTransaction
        switch PasteboardTransaction.start(gateway: pasteboard, transcript: transcript) {
        case .cancelledBeforeWrite:
            InsertionLog.record(.step(.snapshotCancelled))
            return .cancelledNotProcessed
        case .failedBeforeWrite:
            InsertionLog.record(.step(.snapshotRejected))
            return await copyRecovery(.clipboardUnsafe, transcript: transcript)
        case let .failedAfterPossibleWrite(transaction):
            InsertionLog.record(.step(.transcriptWriteUncertain))
            _ = loggedRestore(transaction)
            return await copyRecovery(.clipboardUnsafe, transcript: transcript, preserveAfterPossibleMutation: true)
        case let .ready(ready):
            InsertionLog.record(.step(.transcriptReady))
            transaction = ready
        }
        // Snapshot materialization and transcript writing can outlive the
        // original selection even while the same AX element stays focused.
        guard loggedWitness(for: target, in: prepared, transcript: transcript) == expectedWitness else {
            InsertionLog.record(.step(.pasteWitnessRejected))
            _ = loggedRestore(transaction)
            return await copyRecovery(.focusDrift, transcript: transcript, alreadyCopied: true)
        }
        var reducer = InsertionAttemptReducer()
        guard reducer.claim(.paste) else {
            InsertionLog.record(.step(.pasteClaimRejected))
            _ = loggedRestore(transaction)
            return await copyRecovery(.clipboardUnsafe, transcript: transcript, alreadyCopied: true)
        }
        guard !insertionCancelled else {
            _ = loggedRestore(transaction)
            return await copyRecovery(.cancelled, transcript: transcript, alreadyCopied: true)
        }
        // The clipboard now contains a transcript. Revalidate immediately
        // before the single CMD-V event; drift cannot target a new field.
        guard let target = focus.revalidate(commitLease), target == prepared,
              case .accessibility = loggedDecision(lease: commitLease, current: target, nowNanoseconds: clock.nowNanoseconds(), accessibilityAvailable: true, clipboardMaterializable: true) else {
            InsertionLog.record(.step(.pasteFinalFocusRejected))
            _ = loggedRestore(transaction)
            return await copyRecovery(.focusDrift, transcript: transcript, alreadyCopied: true)
        }
        guard !insertionCancelled else {
            _ = loggedRestore(transaction)
            return await copyRecovery(.cancelled, transcript: transcript, alreadyCopied: true)
        }
        let postResult = pastePoster.postPaste(using: poster, processID: target.processID)
        if case .unconfirmed = postResult { InsertionLog.record(.step(.postUnconfirmed)) }
        if case .unavailable = postResult { InsertionLog.record(.step(.postUnavailable)) }
        switch postResult {
        case .posted:
            InsertionLog.record(.step(.postPosted))
            guard await confirmsWitness(witness, anchor: commitLease, expected: target) else {
                diagnostics.recordInsertion(event: .pasteUnconfirmed)
                _ = loggedRestore(transaction)
                return await copyRecovery(.clipboardUnsafe, transcript: transcript, alreadyCopied: true)
            }
            if loggedRestore(transaction) {
                diagnostics.recordInsertion(event: .pasteConfirmed)
                return .insertedByPaste
            }
            diagnostics.recordInsertion(event: .pasteClipboardNotRestored)
            await recovery.presentClipboardRestoreFailed()
            return .insertedByPasteClipboardNotRestored
        case .unconfirmed, .unavailable:
            diagnostics.recordInsertion(event: .pasteUnconfirmed)
            _ = loggedRestore(transaction)
            return await copyRecovery(.clipboardUnsafe, transcript: transcript, alreadyCopied: true)
        }
    }
    private func loggedRestore(_ transaction: PasteboardTransaction) -> Bool {
        let restored = transaction.restoreIfUnchanged(gateway: pasteboard)
        InsertionLog.record(.flag(.restoreSucceeded, restored))
        return restored
    }
    private func confirmsWitness(_ witness: PasteWitness, anchor: FocusLease, expected: CurrentFocus) async -> Bool {
        for _ in 0..<4 {
            guard let current = focus.revalidate(anchor), current == expected else { InsertionLog.record(.step(.verifierFocusRejected)); return false }
            if await loggedConfirmation(witness, in: current) { return true }
            await sleeper.sleep(nanoseconds: 20_000_000)
        }
        return false
    }
    private func copyRecovery(_ reason: RecoveryReason, transcript: String = "", alreadyCopied: Bool = false, preserveAfterPossibleMutation: Bool = false) async -> TextInsertionOutcome {
        InsertionLog.record(.recovery(reason))
        guard alreadyCopied || preserveAfterPossibleMutation || !insertionCancelled else { return .cancelledNotProcessed }
        // Recovery is intentionally draft-only.  Clipboard mutation requires a
        // later, conscious UI action with its own transaction/CAS contract;
        // this terminal path never overwrites a user's clipboard.
        await recovery.presentRecovery(draft: transcript, session: recoverySession)
        diagnostics.recordInsertion(event: reason == .protectedField ? .deniedProtected : .recoveryCopied)
        return .copiedForRecovery(reason)
    }
}
