import Foundation
import ApplicationServices

/// Converts a matched physical shortcut into its configured behaviour. Unlike
/// the legacy generic state machine, configured modes stay separate except
/// right Option, whose product gesture combines hold and double tap.
public final class ModeAwareShortcutDispatcher: @unchecked Sendable {
    private enum State: Sendable {
        case idle
        case pttPending(downAt: UInt64)
        case optionPending(downAt: UInt64, secondTap: Bool)
        case optionWaiting(upAt: UInt64)
        case optionRecording
        case pttRecording(startedAt: UInt64, checkAt: UInt64)
        case toggleFirstDown
        case toggleWaitingStart(upAt: UInt64)
        case toggleRecording
        case toggleStopDown
        case toggleWaitingStop(upAt: UInt64)
        case reinsertPressed
    }
    private let lock = NSLock()
    private let configuration: HotkeyConfiguration
    private let onReinsert: @Sendable () -> Void
    private var state: State = .idle
    private var physicalKeyCode: UInt16?
    private let physicalKeyIsDown: @Sendable (UInt16) -> Bool?
    private let releaseCheckInterval: UInt64 = 1_000_000_000

    public init(configuration: HotkeyConfiguration = .init(), onReinsert: @escaping @Sendable () -> Void = {}, physicalKeyIsDown: @escaping @Sendable (UInt16) -> Bool? = { HardwareShortcutKeyState.isDown($0) }) {
        self.physicalKeyIsDown = physicalKeyIsDown
        self.configuration = configuration
        self.onReinsert = onReinsert
    }

    public func reset() { lock.withLock { state = .idle } }

    /// The caller arms one monotonic timer for this deadline, if any. There is
    /// no dependency on incidental modifier/flags events for holds or taps.
    public func nextDeadline() -> UInt64? {
        lock.withLock {
            switch state {
            case .pttPending(let downAt), .optionPending(let downAt, _): return downAt &+ configuration.holdThresholdNanoseconds
            case .optionWaiting(let upAt): return upAt &+ configuration.doubleTapWindowNanoseconds &+ 1
            // Check real key state after the grace period; subsequent checks
            // must advance the deadline even while the key remains held.
            case .pttRecording(let startedAt, let checkAt):
                return min(checkAt, startedAt &+ configuration.maximumRecordingNanoseconds)
            case .toggleWaitingStart(let upAt), .toggleWaitingStop(let upAt): return upAt &+ configuration.doubleTapWindowNanoseconds
            default: return nil
            }
        }
    }

    public func consume(_ matched: MatchedShortcutEvent) -> [HotkeyAction] {
        lock.withLock { let previous = state; let actions = consumeLocked(matched); return preRollActions(previous: previous, actions: actions, event: matched.event) }
    }

    public func tick(timestamp: UInt64) -> [HotkeyAction] {
        lock.withLock { let previous = state; let actions = tickLocked(timestamp); return preRollActions(previous: previous, actions: actions) }
    }

    private func needsPreRoll(_ value: State) -> Bool {
        switch value {
        case .pttPending, .optionPending, .optionWaiting, .toggleFirstDown, .toggleWaitingStart: true
        default: false
        }
    }
    private func preRollActions(previous: State, actions: [HotkeyAction], event: HotkeyEvent? = nil) -> [HotkeyAction] {
        let wasPending = needsPreRoll(previous), pending = needsPreRoll(state)
        if pending, case .keyDown(let now, _) = event {
            switch previous {
            case .optionWaiting(let upAt) where elapsed(now, upAt) > configuration.doubleTapWindowNanoseconds,
                 .toggleWaitingStart(let upAt) where elapsed(now, upAt) > configuration.doubleTapWindowNanoseconds:
                return [.disarmPreRoll, .armPreRoll] + actions
            default: break
            }
        }
        if !wasPending && pending { return [.armPreRoll] + actions }
        let confirmed = actions.contains(.startPushToTalk) || actions.contains(.startToggle)
        if wasPending && !pending && !confirmed { return actions + [.disarmPreRoll] }
        return actions
    }

    private func consumeLocked(_ matched: MatchedShortcutEvent) -> [HotkeyAction] {
        switch matched.event {
        case .tapDisabled, .wake:
            let wasRecording: Bool
            switch state { case .pttRecording, .toggleRecording, .toggleStopDown, .toggleWaitingStop, .optionRecording: wasRecording = true; default: wasRecording = false }
            state = .idle
            return [.resetInputTap]
        case .sleep:
            state = .idle; return [.resetInputTap]
        case .cancel:
            let wasRecording: Bool
            switch state { case .pttRecording, .toggleRecording, .toggleStopDown, .toggleWaitingStop, .optionRecording: wasRecording = true; default: wasRecording = false }
            state = .idle
            return wasRecording ? [.cancelRecording] : []
        case .keyDown(_, let isRepeat):
            guard !isRepeat else { return [] }
            if matched.mode == .pushToTalk, matched.physicalKeyCode == ShortcutDescriptor.rightOptionKeyCode {
                return optionDown(timestamp: timestamp(of: matched.event))
            }
            switch matched.mode {
            case .pushToTalk:
                guard case .idle = state else { return [] }
                physicalKeyCode = matched.physicalKeyCode
                state = .pttPending(downAt: timestamp(of: matched.event)); return []
            case .toggle:
                return toggleDown(timestamp: timestamp(of: matched.event))
            case .reinsert:
                guard case .idle = state else { return [] }
                state = .reinsertPressed; onReinsert(); return []
            }
        case .keyUp:
            switch state {
            case .optionPending(let downAt, let secondTap):
                let upAt = timestamp(of: matched.event)
                if elapsed(upAt, downAt) >= configuration.holdThresholdNanoseconds {
                    state = .idle; return [.showListening, .startPushToTalk, .stopAndProcess]
                }
                if secondTap { state = .optionRecording; return [.showListening, .startToggle] }
                state = .optionWaiting(upAt: upAt); return []
            case .pttPending: state = .idle; return []
            case .pttRecording: state = .idle; return [.stopAndProcess]
            case .toggleFirstDown: state = .toggleWaitingStart(upAt: timestamp(of: matched.event)); return []
            case .toggleStopDown: state = .toggleWaitingStop(upAt: timestamp(of: matched.event)); return []
            case .reinsertPressed: state = .idle; return []
            default: return []
            }
        case .tick(let timestamp):
            return tickLocked(timestamp)
        default:
            return []
        }
    }

    private func optionDown(timestamp: UInt64) -> [HotkeyAction] {
        physicalKeyCode = ShortcutDescriptor.rightOptionKeyCode
        switch state {
        case .idle:
            state = .optionPending(downAt: timestamp, secondTap: false)
        case .optionWaiting(let upAt):
            state = .optionPending(downAt: timestamp, secondTap: elapsed(timestamp, upAt) <= configuration.doubleTapWindowNanoseconds)
        case .optionRecording:
            // Start completed on the previous release. This distinct down
            // can stop immediately, even if its release is lost or chorded.
            state = .idle; return [.stopAndProcess]
        default: break
        }
        return []
    }

    private func toggleDown(timestamp: UInt64) -> [HotkeyAction] {
        switch state {
        case .idle: state = .toggleFirstDown; return []
        case .toggleWaitingStart(let upAt) where elapsed(timestamp, upAt) <= configuration.doubleTapWindowNanoseconds:
            state = .toggleRecording; return [.showListening, .startToggle]
        case .toggleWaitingStart: state = .toggleFirstDown; return []
        case .toggleRecording: state = .toggleStopDown; return []
        case .toggleWaitingStop(let upAt) where elapsed(timestamp, upAt) <= configuration.doubleTapWindowNanoseconds:
            state = .idle; return [.stopAndProcess]
        case .toggleWaitingStop: state = .toggleStopDown; return []
        default: return []
        }
    }

    private func tickLocked(_ timestamp: UInt64) -> [HotkeyAction] {
        switch state {
        case .optionWaiting(let upAt) where elapsed(timestamp, upAt) > configuration.doubleTapWindowNanoseconds:
            state = .idle; return []
        case .pttPending(let downAt) where elapsed(timestamp, downAt) >= configuration.holdThresholdNanoseconds,
             .optionPending(let downAt, _) where elapsed(timestamp, downAt) >= configuration.holdThresholdNanoseconds:
            state = .pttRecording(startedAt: timestamp, checkAt: timestamp &+ configuration.lostKeyUpTimeoutNanoseconds); return [.showListening, .startPushToTalk]
        case .pttRecording(let startedAt, _) where elapsed(timestamp, startedAt) >= configuration.maximumRecordingNanoseconds:
            state = .idle; return [.maximumDurationReached]
        case .pttRecording(let startedAt, let checkAt) where timestamp >= checkAt:
            if let physicalKeyCode, physicalKeyIsDown(physicalKeyCode) == false {
                state = .idle; return [.stopAndProcess]
            }
            // Unknown physical state cannot justify discarding spoken audio.
            state = .pttRecording(startedAt: startedAt, checkAt: timestamp &+ releaseCheckInterval)
            return []
        case .toggleWaitingStart(let upAt) where elapsed(timestamp, upAt) > configuration.doubleTapWindowNanoseconds:
            state = .idle; return []
        case .toggleWaitingStop(let upAt) where elapsed(timestamp, upAt) > configuration.doubleTapWindowNanoseconds:
            state = .toggleRecording; return []
        default: return []
        }
    }

    private func elapsed(_ later: UInt64, _ earlier: UInt64) -> UInt64 { later >= earlier ? later - earlier : 0 }
    private func timestamp(of event: HotkeyEvent) -> UInt64 {
        switch event { case .keyDown(let value, _), .keyUp(let value), .tick(let value): return value; default: return 0 }
    }
}
