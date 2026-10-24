import Foundation
import KlangschriftCore

public struct HotkeyConfiguration: Sendable {
    public let holdThresholdNanoseconds: UInt64
    public let doubleTapWindowNanoseconds: UInt64
    public let lostKeyUpTimeoutNanoseconds: UInt64
    public let maximumRecordingNanoseconds: UInt64
    public init(holdThresholdNanoseconds: UInt64 = 120_000_000, doubleTapWindowNanoseconds: UInt64 = 450_000_000, lostKeyUpTimeoutNanoseconds: UInt64 = 45_000_000_000, maximumRecordingNanoseconds: UInt64 = 30 * 60 * 1_000_000_000) {
        self.holdThresholdNanoseconds = holdThresholdNanoseconds
        self.doubleTapWindowNanoseconds = doubleTapWindowNanoseconds
        self.lostKeyUpTimeoutNanoseconds = lostKeyUpTimeoutNanoseconds
        self.maximumRecordingNanoseconds = maximumRecordingNanoseconds
    }
}
public enum HotkeyEvent: Sendable { case keyDown(timestamp: UInt64, isRepeat: Bool), keyUp(timestamp: UInt64), tick(timestamp: UInt64), escape, cancel, sleep, tapDisabled, wake }
/// `startThenStopAndProcess` preserves the audio lifecycle when a key-up arrives before the hold timer tick.
/// Actions encode resource ownership: only a `start*` action owns an active audio
/// session; only `armPreRoll` owns the short pre-roll buffer.  Coordinators must
/// therefore never interpret pre-roll cleanup as cancellation of an active session.
public enum HotkeyAction: Equatable, Sendable { case armPreRoll, disarmPreRoll, discardPreRoll, showListening, startPushToTalk, startToggle, stopAndProcess, maximumDurationReached, startThenStopAndProcess, cancelRecording, resetInputTap, none }
public enum HotkeyState: Equatable, Sendable {
    case idle, prearmed(downAt: UInt64), firstTapPending(at: UInt64), pushToTalk(startedAt: UInt64), toggleRecording(startedAt: UInt64), toggleStopFirstDown(startedAt: UInt64, downAt: UInt64), toggleStopTapPending(startedAt: UInt64, upAt: UInt64), toggleStopSecondDown(startedAt: UInt64), processing
}

public struct HotkeyStateMachine: Sendable {
    public private(set) var state: HotkeyState = .idle
    public let configuration: HotkeyConfiguration
    private let physicalKeyIsDown: @Sendable () -> Bool?
    public init(configuration: HotkeyConfiguration = .init(), physicalKeyIsDown: @escaping @Sendable () -> Bool? = { nil }) {
        self.configuration = configuration
        self.physicalKeyIsDown = physicalKeyIsDown
    }
    private func elapsed(_ later: UInt64, since earlier: UInt64) -> UInt64 { later >= earlier ? later - earlier : 0 }
    private func maximumReached(_ now: UInt64, _ started: UInt64) -> Bool { elapsed(now, since: started) >= configuration.maximumRecordingNanoseconds }
    private var isRecording: Bool {
        switch state { case .pushToTalk, .toggleRecording, .toggleStopFirstDown, .toggleStopTapPending, .toggleStopSecondDown: true; default: false }
    }
    private var recordingStartedAt: UInt64? {
        switch state {
        case .pushToTalk(let value), .toggleRecording(let value), .toggleStopFirstDown(let value, _), .toggleStopTapPending(let value, _), .toggleStopSecondDown(let value): return value
        default: return nil
        }
    }
    public mutating func handle(_ event: HotkeyEvent) -> HotkeyAction {
        switch event {
        case .cancel:
            let recording = isRecording; state = .idle; return recording ? .cancelRecording : .none
        case .sleep, .tapDisabled, .wake:
            let recording = isRecording; state = .idle; return recording ? .resetInputTap : .none
        case .escape:
            switch state {
            case .toggleRecording, .toggleStopFirstDown, .toggleStopTapPending, .toggleStopSecondDown:
                state = .processing; return .stopAndProcess
            default: return .none
            }
        case let .keyDown(timestamp, isRepeat):
            guard !isRepeat else { return .none }
            switch state {
            case .idle: state = .prearmed(downAt: timestamp); return .none
            case .firstTapPending(let first):
                guard timestamp >= first, elapsed(timestamp, since: first) <= configuration.doubleTapWindowNanoseconds else { state = .prearmed(downAt: timestamp); return .none }
                state = .toggleRecording(startedAt: timestamp); return .startToggle
            case .toggleRecording(let startedAt): state = .toggleStopFirstDown(startedAt: startedAt, downAt: timestamp); return .none
            case .toggleStopTapPending(let startedAt, let upAt):
                guard timestamp >= upAt, elapsed(timestamp, since: upAt) <= configuration.doubleTapWindowNanoseconds else { state = .toggleStopFirstDown(startedAt: startedAt, downAt: timestamp); return .none }
                state = .toggleStopSecondDown(startedAt: startedAt); return .none
            default: return .none
            }
        case let .keyUp(timestamp):
            switch state {
            case .prearmed(let downAt):
                if elapsed(timestamp, since: downAt) >= configuration.holdThresholdNanoseconds { state = .processing; return .startThenStopAndProcess }
                state = .firstTapPending(at: timestamp); return .none
            case .pushToTalk: state = .processing; return .stopAndProcess
            case .toggleStopFirstDown(let startedAt, _): state = .toggleStopTapPending(startedAt: startedAt, upAt: timestamp); return .none
            case .toggleStopSecondDown: state = .processing; return .stopAndProcess
            default: return .none
            }
        case let .tick(timestamp):
            switch state {
            case .prearmed(let downAt) where elapsed(timestamp, since: downAt) >= configuration.lostKeyUpTimeoutNanoseconds:
                // No recording started yet.  This is deliberately not
                // `cancelRecording`: only the pre-roll resource exists.
                state = .idle; return .discardPreRoll
            case .prearmed(let downAt) where elapsed(timestamp, since: downAt) >= configuration.holdThresholdNanoseconds:
                state = .pushToTalk(startedAt: timestamp); return .startPushToTalk
            case .firstTapPending(let first) where elapsed(timestamp, since: first) > configuration.doubleTapWindowNanoseconds:
                state = .idle; return .none
            case .toggleStopTapPending(let startedAt, let upAt):
                if maximumReached(timestamp, startedAt) { state = .processing; return .maximumDurationReached }
                if elapsed(timestamp, since: upAt) > configuration.doubleTapWindowNanoseconds { state = .toggleRecording(startedAt: startedAt) }
                return .none
            case .pushToTalk, .toggleRecording, .toggleStopFirstDown, .toggleStopSecondDown:
                if let startedAt = recordingStartedAt, maximumReached(timestamp, startedAt) { state = .processing; return .maximumDurationReached }
                if case .pushToTalk(let startedAt) = state,
                   elapsed(timestamp, since: startedAt) >= configuration.lostKeyUpTimeoutNanoseconds,
                   physicalKeyIsDown() == false { state = .processing; return .stopAndProcess }
                if case .toggleStopFirstDown(_, let downAt) = state, elapsed(timestamp, since: downAt) >= configuration.lostKeyUpTimeoutNanoseconds { state = .idle; return .cancelRecording }
                return .none
            default: return .none
            }
        }
    }
    /// Ordered coordinator contract. The legacy scalar reducer is retained for P0 compatibility.
    public mutating func handleActions(_ event: HotkeyEvent) -> [HotkeyAction] {
        let previous = state; let action = handle(event)
        switch action {
        case .startPushToTalk: return [.showListening, .startPushToTalk]
        case .startToggle: return [.showListening, .startToggle]
        case .startThenStopAndProcess: return [.showListening, .startPushToTalk, .stopAndProcess]
        case .stopAndProcess: return [.stopAndProcess]
        case .maximumDurationReached: return [.maximumDurationReached]
        case .resetInputTap: return [.resetInputTap]
        case .cancelRecording:
            if case .tapDisabled = event { return [.resetInputTap, .cancelRecording] }
            if case .wake = event { return [.resetInputTap, .cancelRecording] }
            return [.cancelRecording]
        case .discardPreRoll:
            return [.disarmPreRoll]
        case .none:
            if case .idle = previous, case .keyDown(_, let repeatEvent) = event, !repeatEvent { return [.armPreRoll] }
            // `firstTapPending` already owns the pre-roll. If a stale second
            // press becomes a new prearmed gesture, that ownership is reused;
            // emitting arm again would allow a coordinator to double-arm it.
            if case .firstTapPending = previous, case .keyDown = event { return [] }
            if case .prearmed = previous {
                switch event {
                case .keyUp:
                    // A short first tap transitions to `firstTapPending`; retain
                    // the owned pre-roll until it either starts a toggle or expires.
                    if case .firstTapPending = state { return [] }
                    return [.disarmPreRoll]
                case .cancel, .sleep: return [.disarmPreRoll]
                case .tapDisabled, .wake: return [.resetInputTap, .disarmPreRoll]
                default: break
                }
            }
            if case .firstTapPending = previous { switch event { case .cancel, .sleep, .tick: return [.disarmPreRoll]; case .tapDisabled, .wake: return [.resetInputTap, .disarmPreRoll]; default: break } }
            return []
        default: return []
        }
    }
    public mutating func completeProcessing() { if state == .processing { state = .idle } }
}
