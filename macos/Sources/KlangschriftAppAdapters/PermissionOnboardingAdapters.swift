import KlangschriftAudio
import AppKit
import ApplicationServices
import AVFoundation
import Foundation
import KlangschriftCore
import KlangschriftAppCore
import KlangschriftHotkeys
import KlangschriftPersistence
import KlangschriftUI

// MARK: - Permission intent

/// The platform boundary keeps status reads side-effect free. Requests and
/// System Settings navigation have separate methods so onboarding can only
/// invoke them after an explicit button action.
@MainActor public protocol MacPermissionPlatform {
    func microphoneStatus() -> Authorization
    func accessibilityStatus() -> Authorization
    func inputMonitoringStatus() -> Authorization
    func requestMicrophone() async -> Authorization
    func requestAccessibility() -> Authorization
    func requestInputMonitoring() -> Authorization
    func openSystemSettings(for kind: PermissionKind)
}
@MainActor public protocol MicrophoneUsageDescriptionProviding { func microphoneUsageDescription() -> String? }
@MainActor public final class BundleMicrophoneUsageDescriptionProvider: MicrophoneUsageDescriptionProviding { public init() {} ; public func microphoneUsageDescription() -> String? { Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String } }

/// Dashboard-facing recovery boundary. Reading status never prompts; the two
/// side-effecting operations remain explicit user actions in the caller.
@MainActor public protocol MicrophonePermissionRecoveryIntent {
    func refreshMicrophonePermission() async -> PermissionStatus
    func requestMicrophonePermission() async -> PermissionStatus
    func openMicrophoneSettings()
}

@MainActor public final class SystemMacPermissionPlatform: MacPermissionPlatform {
    public init() {}
    public func microphoneStatus() -> Authorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted; case .notDetermined: .unknown
        case .denied: .denied; case .restricted: .restricted
        @unknown default: .unavailable
        }
    }
    /// Accessibility exposes trust, but no non-prompting distinction between a
    /// first run and a denial. Keep it requestable until the user explicitly
    /// chooses the permission action.
    public func accessibilityStatus() -> Authorization { AXIsProcessTrusted() ? .granted : .unknown }
    public func inputMonitoringStatus() -> Authorization { CGPreflightListenEventAccess() ? .granted : .unknown }
    public func requestMicrophone() async -> Authorization {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        return microphoneStatus()
    }
    public func requestAccessibility() -> Authorization {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        return accessibilityStatus()
    }
    public func requestInputMonitoring() -> Authorization {
        _ = CGRequestListenEventAccess()
        return inputMonitoringStatus()
    }
    public func openSystemSettings(for kind: PermissionKind) {
        let suffix: String = switch kind {
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(suffix)") else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor public final class MacPermissionStatusIntent: PermissionStatusIntent, MicrophonePermissionRecoveryIntent {
    private let platform: any MacPermissionPlatform
    private let usageDescription: any MicrophoneUsageDescriptionProviding
    private var generation: UInt64 = 0
    public init(platform: any MacPermissionPlatform = SystemMacPermissionPlatform(), usageDescription: any MicrophoneUsageDescriptionProviding = BundleMicrophoneUsageDescriptionProvider()) { self.platform = platform; self.usageDescription = usageDescription }
    public func refresh() async throws -> PermissionSnapshot {
        generation &+= 1
        return snapshot()
    }
    public func refreshMicrophonePermission() async -> PermissionStatus {
        generation &+= 1
        return microphoneStatus()
    }
    public func requestMicrophonePermission() async -> PermissionStatus {
        guard let value = usageDescription.microphoneUsageDescription()?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            generation &+= 1
            return unavailableSnapshot(.microphone).statuses[.microphone]!
        }
        _ = await platform.requestMicrophone()
        generation &+= 1
        return microphoneStatus()
    }
    public func openMicrophoneSettings() { platform.openSystemSettings(for: .microphone) }
    public func requestAuthorization(for kind: PermissionKind) async throws -> PermissionSnapshot {
        // The only prompting calls are deliberately reachable through this
        // explicit intent method, never refresh/init/scene resume.
        switch kind {
        case .microphone:
            guard let value = usageDescription.microphoneUsageDescription()?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { generation &+= 1; return unavailableSnapshot(kind) }
            _ = await platform.requestMicrophone()
        case .accessibility: _ = platform.requestAccessibility()
        case .inputMonitoring: _ = platform.requestInputMonitoring()
        }
        generation &+= 1
        return snapshot()
    }
    private func unavailableSnapshot(_ kind: PermissionKind) -> PermissionSnapshot { var values = snapshot().statuses; values[kind] = .init(kind: kind, authorization: .unavailable, checkedGeneration: generation, canRequest: false, settingsAvailable: false, detailCode: .unavailableOnDevice); return .init(statuses: values, generation: generation) }
    public func openSettings(for kind: PermissionKind) { platform.openSystemSettings(for: kind) }
    private func microphoneStatus() -> PermissionStatus {
        let authorization = platform.microphoneStatus()
        return .init(kind: .microphone, authorization: authorization, checkedGeneration: generation, canRequest: authorization == .unknown, settingsAvailable: authorization != .unavailable, detailCode: Self.detail(authorization))
    }
    private func snapshot() -> PermissionSnapshot {
        let values: [(PermissionKind, Authorization)] = [(.microphone, platform.microphoneStatus()), (.accessibility, platform.accessibilityStatus()), (.inputMonitoring, platform.inputMonitoringStatus())]
        return .init(statuses: Dictionary(uniqueKeysWithValues: values.map { kind, authorization in
            (kind, PermissionStatus(kind: kind, authorization: authorization, checkedGeneration: generation, canRequest: authorization == .unknown, settingsAvailable: authorization != .unavailable, detailCode: Self.detail(authorization)))
        }), generation: generation)
    }
    private static func detail(_ value: Authorization) -> PermissionDetailCode { switch value {
        case .unknown: .notDetermined; case .denied: .deniedByUser; case .restricted: .restrictedBySystem; case .unavailable: .unavailableOnDevice; case .granted: .none
        } }
}

// MARK: - Bounded microphone level test

@MainActor public protocol MicrophoneLevelSampling {
    /// Returns one scalar level only. Implementations must not persist audio.
    func oneLevel(timeoutNanoseconds: UInt64) async throws -> Float
    func cleanup()
}

@MainActor public final class MicrophoneLevelTester: MicrophoneTestIntent {
    private let sampler: any MicrophoneLevelSampling
    private let timeoutNanoseconds: UInt64
    private var running = false
    public init(sampler: any MicrophoneLevelSampling, timeoutNanoseconds: UInt64 = 2_000_000_000) { self.sampler = sampler; self.timeoutNanoseconds = timeoutNanoseconds }
    public func run() async throws -> PermissionTestResult {
        guard !running else { return .init(passed: false, detailCode: .microphoneTestFailed, failure: .alreadyRunning) }
        guard timeoutNanoseconds > 0 else { return .init(passed: false, detailCode: .microphoneTestFailed, failure: .invalidConfiguration) }
        running = true
        defer { sampler.cleanup(); running = false }
        do {
            let level = try await sampler.oneLevel(timeoutNanoseconds: timeoutNanoseconds)
            guard level.isFinite, level >= 0 else { return .init(passed: false, detailCode: .microphoneTestFailed, failure: .invalidAudioLevel) }
            return .init(passed: true, level: level)
        } catch let failure as MicrophoneTestFailure {
            return .init(passed: false, detailCode: .microphoneTestFailed, failure: failure)
        } catch is CancellationError {
            return .init(passed: false, detailCode: .microphoneTestFailed, failure: .cancelled)
        } catch {
            return .init(passed: false, detailCode: .microphoneTestFailed, failure: .captureCouldNotStart)
        }
    }
}

/// Captures exactly one audio callback, reduces it to a scalar level and tears
/// the engine down. The callback buffer is never retained, serialized or logged.
@MainActor public final class AVOneFrameMicrophoneSampler: NSObject, MicrophoneLevelSampling {
    private var engine: AVAudioEngine?
    private var continuation: CheckedContinuation<Float, Error>?
    private var timeout: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?
    public override init() { super.init() }
    public func oneLevel(timeoutNanoseconds: UInt64) async throws -> Float {
        guard engine == nil, continuation == nil, timeoutNanoseconds > 0 else { throw CancellationError() }
        generation &+= 1
        let frameGeneration = generation
        let engine = AVAudioEngine(); let input = engine.inputNode
        return try await withCheckedThrowingContinuation { continuation in
            self.engine = engine; self.continuation = continuation; self.activeGeneration = frameGeneration
            input.installTap(onBus: 0, bufferSize: 256, format: nil, block: Self.makeTapCallback(generation: frameGeneration) { [weak self] generation, value in
                self?.deliver(value, generation: generation)
            })
            do { try engine.start() } catch { finish(.failure(MicrophoneTestFailure.captureCouldNotStart), generation: frameGeneration); return }
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard !Task.isCancelled else { return }
                self?.finish(.failure(MicrophoneTestFailure.noAudioFrameBeforeTimeout), generation: frameGeneration)
            }
        }
    }
    public func cleanup() { guard let generation = activeGeneration else { return }; finish(.failure(CancellationError()), generation: generation) }
    /// Test-only seam: installs no AV tap or engine and exists solely to prove
    /// terminal continuation ownership without a TCC/audio-device interaction.
    @_spi(Testing) public func _testingAwaitPendingFrame(armed: @escaping @MainActor @Sendable () -> Void = {}) async throws -> Float {
        guard engine == nil, continuation == nil else { throw CancellationError() }
        generation &+= 1
        let frameGeneration = generation
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation; self.activeGeneration = frameGeneration; armed()
        }
    }
    /// Test-only seam for the exact callback used by the physical AV tap.
    @_spi(Testing) public func _testingTapCallback() throws -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        guard let generation = activeGeneration else { throw CancellationError() }
        return Self.makeTapCallback(generation: generation) { [weak self] generation, value in
            self?.deliver(value, generation: generation)
        }
    }
    @_spi(Testing) public func _testingDeliverFrame(_ value: Float, generation: UInt64? = nil) {
        guard let activeGeneration else { return }
        finish(.success(value), generation: generation ?? activeGeneration)
    }
    @_spi(Testing) public func _testingTimeout() {
        guard let generation = activeGeneration else { return }
        finish(.failure(CancellationError()), generation: generation)
    }
    nonisolated static func makeTapCallback(generation: UInt64, delivery: @escaping @MainActor @Sendable (UInt64, Float) -> Void) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            let frames = Int(buffer.frameLength)
            let scalar: Float
            if frames > 0, let channel = buffer.floatChannelData?[0] {
                var total: Float = 0
                for index in 0..<frames { total += channel[index] * channel[index] }
                scalar = (total / Float(frames)).squareRoot()
            } else { scalar = 0 }
            Task { @MainActor in delivery(generation, scalar) }
        }
    }
    private func deliver(_ value: Float, generation: UInt64) { finish(.success(value), generation: generation) }
    private func finish(_ result: Result<Float, Error>, generation: UInt64) {
        guard activeGeneration == generation else { return }
        activeGeneration = nil
        let engine = self.engine; self.engine = nil; timeout?.cancel(); timeout = nil
        engine?.inputNode.removeTap(onBus: 0); engine?.stop(); engine?.reset()
        let continuation = self.continuation; self.continuation = nil
        continuation?.resume(with: result)
    }
}

// MARK: - Shortcut capture and validation

public struct ShortcutCapture: Sendable, Equatable {
    public let keyCode: UInt16; public let modifiers: UInt64; public let display: String; public let mode: ShortcutDraftMode; public let fnProfile: ShortcutDraftFnProfile; public let globeProof: FnGlobeCaptureProof?
    public init(keyCode: UInt16, modifiers: UInt64, display: String, mode: ShortcutDraftMode, fnProfile: ShortcutDraftFnProfile, globeProof: FnGlobeCaptureProof? = nil) { self.keyCode = keyCode; self.modifiers = modifiers; self.display = display; self.mode = mode; self.fnProfile = fnProfile; self.globeProof = globeProof }
}
@MainActor public protocol TemporaryShortcutCapturing { func install(generation: UInt64, receive: @escaping @MainActor (ShortcutCapture) -> Void, terminate: @escaping @MainActor () -> Void) throws; func uninstall() }
@MainActor public final class NoopShortcutCapturer: TemporaryShortcutCapturing { public init() {} ; public func install(generation: UInt64, receive: @escaping @MainActor (ShortcutCapture) -> Void, terminate: @escaping @MainActor () -> Void) throws {} ; public func uninstall() {} }
/// Production deliberately has no ambient keyboard-identity probe. A concrete
/// device monitor must be injected before a Globe proof can be issued; without
/// it, Fn remains a regular function modifier and Globe is unavailable.
public struct UnavailableKeyboardIdentityObserver: CurrentKeyboardIdentityObserving { public init() {} ; public func currentIdentity() -> RawKeyboardIdentityObservation? { nil } }
/// Production bridge for the *existing* physical P2 tap. It owns one P2 token
/// and transforms only a non-repeat key down into the typed UI draft.
@MainActor public final class TemporaryCGEventShortcutCapturer: TemporaryShortcutCapturing {
    private let controller: any EventTapTemporaryCaptureControlling; private let identity: any CurrentKeyboardIdentityObserving; private let qualification: FnGlobeQualificationService
    private var token: UUID?; private var callback: (@MainActor (ShortcutCapture) -> Void)?; private var terminate: (@MainActor () -> Void)?
    private var captureIdentity: RawKeyboardIdentityObservation?; private var globeIdentity: RawKeyboardIdentityObservation?; private var globeDown = false; private var globeUp = false; private var globeFlags = false; private var globeKeyCode: UInt16 = 0; private var globeModifiers: UInt64 = 0; private var functionOnlyPending = false; private var rightOptionOnlyPending = false
    public init(controller: any EventTapTemporaryCaptureControlling, identity: any CurrentKeyboardIdentityObserving = UnavailableKeyboardIdentityObserver(), qualification: FnGlobeQualificationService) { self.controller = controller; self.identity = identity; self.qualification = qualification }
    public func install(generation: UInt64, receive: @escaping @MainActor (ShortcutCapture) -> Void) throws { try install(generation: generation, receive: receive, terminate: {}) }
    public func install(generation: UInt64, receive: @escaping @MainActor (ShortcutCapture) -> Void, terminate: @escaping @MainActor () -> Void) throws {
        uninstall(); captureIdentity = nil; globeIdentity = nil; globeDown = false; globeUp = false; globeFlags = false; functionOnlyPending = false; rightOptionOnlyPending = false; let token = UUID(); self.token = token; callback = receive; self.terminate = terminate
        try controller.beginTemporaryCapture(token: token) { [weak self] received, observation in
            guard received == token else { return }; Task { @MainActor [weak self] in self?.consume(observation, token: token) }
        }
    }
    public func uninstall() { guard let token else { return }; self.token = nil; callback = nil; terminate = nil; captureIdentity = nil; functionOnlyPending = false; rightOptionOnlyPending = false; controller.endTemporaryCapture(token: token) }
    private func consume(_ value: RawShortcutObservation, token: UUID) {
        guard self.token == token else { return }
        if value.kind == .tapDisabled || value.kind == .wake { let terminal = self.terminate; uninstall(); terminal?(); return }
        if value.kind == .keyDown, value.keyCode == 53 { let terminal = self.terminate; uninstall(); terminal?(); return }
        guard value.kind == .keyDown || value.kind == .keyUp || value.kind == .flagsChanged else { return }
        // Identity is relevant only to the optional Globe qualification flow;
        // normal shortcuts and Fn as a modifier work without hardware facts.
        if globeIdentity != nil {
            guard let current = identity.currentIdentity(), current.keyboardClass != .unknown,
                  let expected = captureIdentity,
                  current.device == expected.device, current.signature == expected.signature, current.keyboardClass == expected.keyboardClass else { let terminal = self.terminate; uninstall(); terminal?(); return }
            if value.kind == .keyUp { globeUp = true }; if value.kind == .flagsChanged { globeFlags = true }
            guard globeDown && globeUp && globeFlags, let identity = globeIdentity else { return }
            guard let proof = try? qualification.recordQualifiedCaptureProof(rawDeviceIdentifier: identity.device, rawObservedSignature: identity.signature, keyboardClass: identity.keyboardClass, sawDown: true, sawUp: true, sawFlagsChanged: true) else { let terminal = self.terminate; uninstall(); terminal?(); return }
            let capture = ShortcutCapture(keyCode: globeKeyCode, modifiers: globeModifiers, display: "Fn", mode: .pushToTalk, fnProfile: .globeQualified, globeProof: proof); let callback = self.callback; uninstall(); callback?(capture); return
        }
        let modifiers = ConfiguredShortcutMatcher.normalizedModifiers(value.modifiers)
        if functionOnlyPending {
            guard value.kind == .flagsChanged, value.keyCode == ShortcutDescriptor.functionKeyCode, !modifiers.contains(.function) else { return }
            let capture = ShortcutCapture(keyCode: value.keyCode, modifiers: ShortcutModifier.function.rawValue, display: "Fn", mode: .pushToTalk, fnProfile: .functionModifier)
            let callback = self.callback; uninstall(); callback?(capture); return
        }
        // Fn alone is a modifier transition on macOS, not a keyDown. Capture
        // both edges before completing so neither half can leak through to the
        // macOS input-source switch. The live matcher mirrors these edges.
        if value.kind == .flagsChanged,
           value.keyCode == ShortcutDescriptor.functionKeyCode,
           modifiers == .function {
            functionOnlyPending = true; return
        }
        // Right Option has no keyDown edge.  The event-tap adapter samples
        // both physical sides on each flags transition; require those facts
        // so a left Option or a chord cannot become a right-Option shortcut.
        if rightOptionOnlyPending {
            if value.kind == .flagsChanged,
               value.keyCode == ShortcutDescriptor.rightOptionKeyCode,
               value.leftOptionIsDown == false,
               value.rightOptionIsDown == false,
               value.modifierIsDown == false,
               modifiers.isEmpty {
                let capture = ShortcutCapture(keyCode: ShortcutDescriptor.rightOptionKeyCode, modifiers: ShortcutModifier.option.rawValue, display: "Rechte Option", mode: .pushToTalk, fnProfile: .disabled)
                let callback = self.callback; uninstall(); callback?(capture); return
            }
            rightOptionOnlyPending = false
        }
        if value.kind == .flagsChanged,
           value.keyCode == ShortcutDescriptor.rightOptionKeyCode,
           value.leftOptionIsDown == false,
           value.rightOptionIsDown == true,
           value.modifierIsDown == true,
           modifiers == .option {
            rightOptionOnlyPending = true; return
        }
        guard value.kind == .keyDown, !value.isRepeat, value.keyCode <= 0x7f else { return }
        if modifiers.contains(.function), let current = identity.currentIdentity(), current.keyboardClass != .unknown {
            captureIdentity = current; globeIdentity = current; globeDown = true; globeKeyCode = value.keyCode; globeModifiers = modifiers.rawValue; return
        }
        let profile: ShortcutDraftFnProfile = modifiers.contains(.function) ? .functionModifier : .disabled
        let display = profile == .functionModifier ? "Fn" : value.keyCode == ShortcutDescriptor.rightOptionKeyCode ? "Rechte Option" : "Shortcut"
        let capture = ShortcutCapture(keyCode: value.keyCode, modifiers: modifiers.rawValue, display: display, mode: .pushToTalk, fnProfile: profile)
        let callback = self.callback; uninstall(); callback?(capture)
    }
    deinit { if let token { controller.endTemporaryCapture(token: token) } }
}

@MainActor public final class ProductionShortcutSetupIntent: ShortcutSetupIntent {
    private let configured: @Sendable () -> [ShortcutDescriptor]
    private let capturer: any TemporaryShortcutCapturing
    private let proofStore: (any FnGlobeCaptureProofStore)?
    private var captureGeneration: UInt64 = 0
    private var continuation: CheckedContinuation<ShortcutDraft, Error>?
    private var buffered: (UInt64, ShortcutDraft)?
    private var timeout: Task<Void, Never>?
    private let captureTimeoutNanoseconds: UInt64
    public init(configured: @escaping @Sendable () -> [ShortcutDescriptor] = { [] }, capturer: any TemporaryShortcutCapturing = NoopShortcutCapturer(), proofStore: (any FnGlobeCaptureProofStore)? = nil, captureTimeoutNanoseconds: UInt64 = 15_000_000_000) { self.configured = configured; self.capturer = capturer; self.proofStore = proofStore; self.captureTimeoutNanoseconds = captureTimeoutNanoseconds }
    public func beginCapture() throws -> UInt64 { guard captureTimeoutNanoseconds > 0 else { throw ServiceContractError.invalidConfiguration("capture-timeout") }; if timeout != nil || continuation != nil || buffered != nil { cancelActive() }; captureGeneration &+= 1; let generation = captureGeneration; try capturer.install(generation: generation, receive: { [weak self] value in self?.receive(value, generation: generation) }, terminate: { [weak self] in self?.terminal(generation: generation) }); guard captureGeneration == generation else { return generation }; timeout = Task { [weak self] in try? await Task.sleep(nanoseconds: self?.captureTimeoutNanoseconds ?? 1); await MainActor.run { self?.cancelCapture(generation: generation) } }; return generation }
    public func waitForCapture(generation: UInt64) async throws -> ShortcutDraft { guard generation == captureGeneration, continuation == nil else { throw CancellationError() }; if let buffered, buffered.0 == generation { self.buffered = nil; captureGeneration &+= 1; return buffered.1 }; return try await withCheckedThrowingContinuation { continuation = $0 } }
    public func cancelCapture(generation: UInt64) { guard generation == captureGeneration else { return }; captureGeneration &+= 1; cancelActive() }
    /// Composition lifecycle boundary; no capture generation leaks into the
    /// app shell, and cold composition never invokes this method.
    public func cancelActiveCapture() { guard timeout != nil || continuation != nil || buffered != nil else { return }; captureGeneration &+= 1; cancelActive() }
    /// Stale capture callbacks cannot overwrite a newer draft. Captures contain
    /// no keyboard device identifier or event-signature data.
    public func capture(_ value: ShortcutCapture, generation: UInt64) -> ShortcutDraft? {
        guard generation == captureGeneration, value.keyCode <= 0x7f, value.modifiers & ~UInt64(0x1f) == 0, !value.display.isEmpty, value.display.utf8.count <= 128 else { return nil }
        if value.fnProfile == .globeQualified { guard let proof = value.globeProof, proof.qualified, let stored = try? proofStore?.proof(for: proof.deviceIdentifierHash), stored == proof else { return nil } }
        return .init(display: value.display, mode: Self.displayMode(value.mode), usesFn: value.fnProfile != .disabled, keyCode: value.keyCode, modifiers: value.modifiers, typedMode: value.mode, fnProfile: value.fnProfile)
    }
    private func receive(_ value: ShortcutCapture, generation: UInt64) { guard let draft = capture(value, generation: generation) else { return }; timeout?.cancel(); timeout = nil; capturer.uninstall(); if let continuation { captureGeneration &+= 1; continuation.resume(returning: draft); self.continuation = nil } else { buffered = (generation, draft) } }
    private func terminal(generation: UInt64) { guard generation == captureGeneration else { return }; captureGeneration &+= 1; timeout?.cancel(); timeout = nil; continuation?.resume(throwing: CancellationError()); continuation = nil }
    private func cancelActive() { timeout?.cancel(); timeout = nil; capturer.uninstall(); continuation?.resume(throwing: CancellationError()); continuation = nil }
    public func validate(_ draft: ShortcutDraft) async throws -> ShortcutValidation {
        guard let candidate = descriptor(draft) else { return .blockedReservation }
        let conflicts = ShortcutConflictChecker().conflicts(candidate: candidate, configured: configured())
        if conflicts.contains(where: { if case .exactExisting = $0 { true } else { false } }) { return .blockedExactConflict }
        if conflicts.contains(where: { if case .macOSReservation = $0 { true } else { false } }) { return .blockedReservation }
        return .warningUnverifiable
    }
    private func descriptor(_ draft: ShortcutDraft) -> ShortcutDescriptor? {
        guard let code = draft.keyCode else { return nil }
        let profile: FnGlobeProfile = switch draft.fnProfile { case .disabled: .disabled; case .functionModifier: .functionModifier; case .globeQualified: .globeQualified }
        return try? .init(keyCode: code, modifiers: .init(rawValue: draft.modifiers), fnGlobeProfile: profile)
    }
    private static func displayMode(_ mode: ShortcutDraftMode) -> String { switch mode { case .pushToTalk: "Halten"; case .toggle: "Umschalten"; case .reinsert: "Erneut einfügen" } }
}

extension ProductionShortcutSetupIntent: PrefoundationShortcutCaptureLifecycle {}

// MARK: - Ephemeral test dictation

/// P7-06D must inject this same instance into the live coordinator bridge.
/// Until then no composition root is bound, but the C adapter exposes distinct
/// live/test leases so either side can fail closed while the other is active.
public actor EphemeralDictationArbiter {
    private var owner: UUID?
    public init() {}
    public func acquire() -> UUID? { guard owner == nil else { return nil }; let token = UUID(); owner = token; return token }
    public func acquireLive() -> UUID? { acquire() }
    public func release(_ token: UUID) { guard owner == token else { return }; owner = nil }
    public func isBusy() -> Bool { owner != nil }
}

extension EphemeralDictationArbiter: RecordingArbitrating {}

/// The narrow test boundary intentionally exposes only an ephemeral preview.
public protocol EphemeralDictationRunning: Sendable {
    func beginEphemeral(language: OnboardingLanguage) async throws
    func finishEphemeral() async throws -> String
    func cancelEphemeral() async
}
/// A failed reader reap retains the owned artifact and the shared audio lease.
/// Callers must present that as blocked instead of claiming the test path is
/// idle and admitting another recording.
public protocol EphemeralAdmissionBlocking: EphemeralDictationRunning {
    func isAdmissionBlocked() async -> Bool
}
/// A production runner that uses `AudioCoordinatorAdapter` obtains the shared
/// lease through that adapter; the intent must not take a second lease.
public protocol SharedArbiterManagedEphemeral: EphemeralDictationRunning {}

public protocol EphemeralAutomaticObserving: EphemeralDictationRunning {
    func setAutomaticHandler(_ handler: @escaping @Sendable (UUID, AudioCaptureCompletionReason, Result<String, Error>?) async -> Void) async
}
public actor ProductionEphemeralDictationRunner: SharedArbiterManagedEphemeral, EphemeralAdmissionBlocking, EphemeralAutomaticObserving {
    private let audio: any DictationAudio; private let helper: any LocalTranscribing; private var active: (session: DictationSessionID, language: OnboardingLanguage, readerMayHaveBeenAdmitted: Bool)?; private var reapConfirmation: [DictationSessionID: Bool] = [:]; private var admissionBlocked = false
    private var automaticHandler: (@Sendable (UUID, AudioCaptureCompletionReason, Result<String, Error>?) async -> Void)?
    public func setAutomaticHandler(_ handler: @escaping @Sendable (UUID, AudioCaptureCompletionReason, Result<String, Error>?) async -> Void) { automaticHandler = handler }
    public func owns(session: DictationSessionID) -> Bool { active?.session == session }
    private var startingSession: DictationSessionID?
    private var pendingAutomaticReason: AudioCaptureCompletionReason?
    private var completionGeneration: UInt64 = 0
    private var automaticResult: Result<String, Error>?
    private var finishing: (session: DictationSessionID, task: Task<String, Error>)?
    public init(audio: any DictationAudio, helper: any LocalTranscribing) { self.audio = audio; self.helper = helper }
    public func beginEphemeral(language: OnboardingLanguage) async throws {
        guard active == nil, finishing == nil, !admissionBlocked else { throw CancellationError() }; completionGeneration &+= 1; automaticResult = nil; let session = DictationSessionID(); active = (session, language, false); startingSession = session; pendingAutomaticReason = nil
        do {
            if let adapter = audio as? AudioCoordinatorAdapter {
                guard await adapter.registerEphemeralOwner(session: session, terminalHandler: { [weak self] in await self?.cancelOwnedSession(session) }, completionHandler: { [weak self] reason in await self?.finishAutomatically(session: session, reason: reason) }) else { throw CancellationError() }
                guard active?.session == session else { throw CancellationError() }
            }
            _ = try await audio.start(session: session, mode: .pushToTalk); guard active?.session == session else { throw CancellationError() }
            startingSession = nil
            if let reason = pendingAutomaticReason { pendingAutomaticReason = nil; await finishAutomatically(session: session, reason: reason) }
        } catch {
            // Start failed before any reader can be admitted.  Do not invent a
            // helper generation, but do release the audio-side reservation.
            await audio.cancelAndCleanup(session: session); if active?.session == session { active = nil }
            throw error
        }
    }
    /// Completion is retained for the existing onboarding stop/result action;
    /// it never inserts text or opens the encrypted foundation.
    private func cancelOwnedSession(_ session: DictationSessionID) async {
        guard active?.session == session else { return }
        let handler = automaticHandler
        await handler?(session.rawValue, .interrupted, nil)
        guard active?.session == session else { return }
        let nextGeneration = completionGeneration &+ 1
        await cancelEphemeral()
        guard completionGeneration == nextGeneration else { return }
        await handler?(session.rawValue, .interrupted, .failure(CancellationError()))
    }
    public func finishAutomatically(session: DictationSessionID, reason: AudioCaptureCompletionReason = .callbackLoss) async {
        guard active?.session == session else { return }
        if startingSession == session {
            pendingAutomaticReason = reason
            await automaticHandler?(session.rawValue, reason, nil)
            return
        }
        let generation = completionGeneration
        let handler = automaticHandler
        await handler?(session.rawValue, reason, nil)
        guard completionGeneration == generation, active?.session == session else { return }
        let result: Result<String, Error>
        do { result = .success(try await finishEphemeral()) }
        catch { result = .failure(error) }
        guard completionGeneration == generation else { return }
        automaticResult = result
        await handler?(session.rawValue, reason, result)
    }
    public func finishEphemeral() async throws -> String {
        if let result = automaticResult { automaticResult = nil; return try result.get() }
        if let finishing { return try await finishing.task.value }
        guard let running = active else { throw CancellationError() }
        let session = running.session
        let task = Task { try await self.finishRecording(session: session) }
        finishing = (session, task)
        defer { if finishing?.session == session { finishing = nil } }
        return try await task.value
    }
    private func finishRecording(session: DictationSessionID) async throws -> String {
        guard let running = active, running.session == session else { throw CancellationError() }
        var readerMayHaveBeenAdmitted = running.readerMayHaveBeenAdmitted
        do {
            let artifact = try await audio.stop(session: session)
            guard active?.session == session else { throw CancellationError() }
            readerMayHaveBeenAdmitted = true
            active = (session, running.language, true)
            let text = try await helper.transcribe(audio: artifact, session: session, language: running.language.transcriptionCode)
            guard active?.session == session else { throw CancellationError() }
            await audio.cancelAndCleanup(session: session)
            guard active?.session == session else { throw CancellationError() }
            active = nil
            return text
        } catch {
            await finishAfterFailure(session: session, readerMayHaveBeenAdmitted: readerMayHaveBeenAdmitted)
            throw error
        }
    }
    public func cancelEphemeral() async {
        completionGeneration &+= 1
        automaticResult = nil
        guard let running = active else { return }
        await finishAfterFailure(session: running.session, readerMayHaveBeenAdmitted: running.readerMayHaveBeenAdmitted)
    }
    public func cancel() async { await cancelEphemeral() }
    public func isAdmissionBlocked() async -> Bool { admissionBlocked }
    private func finishAfterFailure(session: DictationSessionID, readerMayHaveBeenAdmitted: Bool) async {
        guard active?.session == session else { return }
        guard readerMayHaveBeenAdmitted else {
            active = nil
            await audio.cancelAndCleanup(session: session)
            return
        }
        let confirmed = await readerEndConfirmedByReap(session)
        guard active?.session == session else { return }
        guard confirmed else {
            admissionBlocked = true
            active = nil
            return
        }
        await audio.cancelAndCleanup(session: session)
        if active?.session == session { active = nil }
    }
    private func readerEndConfirmedByReap(_ session: DictationSessionID) async -> Bool {
        if let known = reapConfirmation[session] { return known }
        let outcome = await helper.cancelAndReapOutcome(session: session)
        let confirmed: Bool
        switch outcome {
        case .graceful, .forced, .reaped: confirmed = true
        case .none, .outcomeUnknown: confirmed = false
        }
        reapConfirmation[session] = confirmed
        return confirmed
    }
}

@MainActor public final class StatefulTestDictationIntent: TestDictationIntent {
    public enum State: Sendable, Equatable { case idle, recording, processing, blocked }
    private let arbiter: EphemeralDictationArbiter; private let runner: any EphemeralDictationRunning; private var lease: UUID?
    private var generation: UInt64 = 0
    private var automaticObserved: UInt64?
    private var automaticHandler: (@MainActor @Sendable (TestDictationAutomaticEvent) -> Void)?
    public func setAutomaticHandler(_ handler: @escaping @MainActor @Sendable (TestDictationAutomaticEvent) -> Void) { automaticHandler = handler }
    public private(set) var state: State = .idle
    public init(arbiter: EphemeralDictationArbiter, runner: any EphemeralDictationRunning) { self.arbiter = arbiter; self.runner = runner }
    public func start(language: OnboardingLanguage) async throws {
        guard state == .idle else { throw CancellationError() }
        generation &+= 1
        let token = generation
        state = .processing
        if let observable = runner as? any EphemeralAutomaticObserving {
            await observable.setAutomaticHandler { [weak self] session, reason, result in await self?.receiveAutomatic(session: session, reason: reason, result: result, generation: token) }
        }
        guard generation == token else { throw CancellationError() }
        if runner is any SharedArbiterManagedEphemeral {
            do {
                try await runner.beginEphemeral(language: language)
                guard generation == token else { throw CancellationError() }
                if automaticObserved != token { state = .recording }
                return
            } catch { if generation == token { await settleAfterRunnerFailure(generation: token) }; throw error }
        }
        guard let leaseToken = await arbiter.acquire() else { if generation == token { state = .idle }; throw CancellationError() }
        guard generation == token else { await arbiter.release(leaseToken); throw CancellationError() }
        do {
            try await runner.beginEphemeral(language: language)
            guard generation == token else { throw CancellationError() }
            lease = leaseToken
            if automaticObserved != token { state = .recording }
        } catch {
            await arbiter.release(leaseToken)
            if generation == token { await settleAfterRunnerFailure(generation: token) }
            throw error
        }
    }
    private func receiveAutomatic(session: UUID, reason: AudioCaptureCompletionReason, result: Result<String, Error>?, generation token: UInt64) async {
        guard token == generation else { return }
        automaticObserved = token
        let uiReason: TestDictationAutomaticReason = switch reason { case .maximumDuration: .maximumDuration; case .callbackLoss: .callbackLoss; case .interrupted, .interruptedCopied, .lockedCopied: .interrupted }
        if let result {
            let preview = (try? result.get()).flatMap(TestDictationResult.init(preview:))
            await releaseLease()
            guard token == generation else { return }
            if preview == nil { await settleAfterRunnerFailure(generation: token) } else { state = .idle }
            guard token == generation else { return }
            automaticHandler?(.finished(session: session, reason: uiReason, result: preview))
        } else {
            state = .processing
            automaticHandler?(.processing(session: session, reason: uiReason))
        }
    }
    public func stopAndTranscribe() async throws -> TestDictationResult {
        guard state == .recording else { throw CancellationError() }
        let token = generation
        state = .processing
        do {
            let text = try await runner.finishEphemeral()
            guard token == generation, let result = TestDictationResult(preview: text) else { throw CancellationError() }
            await releaseLease()
            guard token == generation else { throw CancellationError() }
            state = .idle; return result
        } catch {
            guard token == generation else { throw error }
            await runner.cancelEphemeral()
            guard token == generation else { throw error }
            await releaseLease()
            guard token == generation else { throw error }
            await settleAfterRunnerFailure(generation: token)
            throw error
        }
    }
    public func cancel() async {
        generation &+= 1
        let token = generation
        guard state == .recording || state == .processing else { return }
        await runner.cancelEphemeral()
        guard token == generation else { return }
        await releaseLease()
        guard token == generation else { return }
        await settleAfterRunnerFailure(generation: token)
    }
    private func releaseLease() async { guard let lease else { return }; self.lease = nil; await arbiter.release(lease) }
    private func settleAfterRunnerFailure(generation token: UInt64) async {
        let blocked: Bool
        if let blocking = runner as? any EphemeralAdmissionBlocking { blocked = await blocking.isAdmissionBlocked() }
        else { blocked = false }
        guard token == generation else { return }
        state = blocked ? .blocked : .idle
    }
}

// MARK: - Completion persistence

@MainActor public protocol CompletionMarker: AnyObject { func completed() -> Bool; func setCompleted(_ value: Bool) }
@MainActor public final class UserDefaultsCompletionMarker: CompletionMarker {
    public static let key = "io.github.miggidev618.klangschrift.onboardingCompleted.v1"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func completed() -> Bool { defaults.bool(forKey: Self.key) }
    public func setCompleted(_ value: Bool) { defaults.set(value, forKey: Self.key) }
}

@MainActor public final class ProductionCompletionIntent: CompletionIntent {
    private let store: EncryptedSQLiteStore; private let retention: SettingsRetentionCoordinator; private let marker: any CompletionMarker; private let permissions: any PermissionStatusIntent
    public init(store: EncryptedSQLiteStore, retention: SettingsRetentionCoordinator = .init(), marker: any CompletionMarker = UserDefaultsCompletionMarker(), permissions: any PermissionStatusIntent = MacPermissionStatusIntent()) { self.store = store; self.retention = retention; self.marker = marker; self.permissions = permissions }
    public func load() async throws -> CompletionDraft? {
        // A persisted bit only routes the relaunch. Re-read the platform state
        // without prompting before presenting the dashboard.
        _ = try await permissions.refresh()
        guard marker.completed() else { return nil }
        let preferences = try await store.preferences()
        guard let shortcut = preferences.snapshot.shortcuts.first else { return nil }
        return .init(shortcut: Self.draft(shortcut), privacy: .init(historyEnabled: preferences.snapshot.historyEnabled, retention: Self.onboardingRetention(preferences.snapshot.retention)))
    }
    public func save(_ draft: CompletionDraft) async throws {
        guard let shortcut = Self.persisted(draft.shortcut) else { throw ServiceContractError.invalidConfiguration("onboarding_shortcut") }
        let current = try await store.preferences(); var snapshot = current.snapshot
        snapshot.shortcuts = [shortcut]
        snapshot.historyEnabled = draft.privacy.historyEnabled && draft.privacy.retention != .none
        snapshot.retention = Self.persistedRetention(draft.privacy.retention)
        let committed = try await store.savePreferences(snapshot, expectedRevision: current.revision)
        let retentionOutcome = await retention.applyCommitted(committed, historyStore: store)
        guard retentionOutcome == .applied || retentionOutcome == .notRequired else { throw ServiceContractError.invalidConfiguration("onboarding_retention_retry") }
        // This is deliberately only a completion bit; preferences remain the
        // source of truth and are committed before the marker is written.
        marker.setCompleted(true)
    }
    private static func persisted(_ draft: ShortcutDraft) -> PersistedShortcut? {
        guard let keyCode = draft.keyCode, keyCode <= 0x7f, draft.modifiers & ~UInt64(0x1f) == 0, draft.modifiers != 0 || draft.fnProfile != .disabled else { return nil }
        let mode: PersistedShortcutMode = switch draft.typedMode { case .pushToTalk: .pushToTalk; case .toggle: .toggle; case .reinsert: .reinsert }
        let profile: PersistedFnGlobeProfile = switch draft.fnProfile { case .disabled: .disabled; case .functionModifier: .functionModifier; case .globeQualified: .globeQualified }
        return .init(keyCode: keyCode, modifiers: draft.modifiers, mode: mode, fnGlobeProfile: profile)
    }
    private static func draft(_ value: PersistedShortcut) -> ShortcutDraft {
        let mode: ShortcutDraftMode = switch value.mode { case .pushToTalk: .pushToTalk; case .toggle: .toggle; case .reinsert: .reinsert }
        let profile: ShortcutDraftFnProfile = switch value.fnGlobeProfile { case .disabled: .disabled; case .functionModifier: .functionModifier; case .globeQualified: .globeQualified }
        return .init(display: "Shortcut", mode: mode == .pushToTalk ? "Halten" : mode == .toggle ? "Umschalten" : "Erneut einfügen", usesFn: profile != .disabled, keyCode: value.keyCode, modifiers: value.modifiers, typedMode: mode, fnProfile: profile)
    }
    private static func persistedRetention(_ value: KlangschriftUI.HistoryRetention) -> HistoryRetentionCodable { switch value { case .forever: .forever; case .days7: .days7; case .days14: .days14; case .days30: .days30; case .days90: .days90; case .none: .none } }
    private static func onboardingRetention(_ value: HistoryRetentionCodable) -> KlangschriftUI.HistoryRetention { switch value { case .forever: .forever; case .days7: .days7; case .days14: .days14; case .days30: .days30; case .days90: .days90; case .none: .none } }
}
