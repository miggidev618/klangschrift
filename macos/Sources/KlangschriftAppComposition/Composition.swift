import Foundation
import Dispatch
import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics
import ApplicationServices
import Carbon.HIToolbox
import KlangschriftAppAdapters
import KlangschriftAppCore
import KlangschriftAppIntegration
import KlangschriftPersistence
import KlangschriftPresentation
import KlangschriftUI
import KlangschriftAudio
import KlangschriftCore
import KlangschriftHotkeys
import KlangschriftTextInsertion
import KlangschriftDesktopModelProduct
import KlangschriftDesktopModels

@MainActor public protocol DashboardWindowOpening: AnyObject { func openDashboardWindow() }
/// Owns only the subscription lifetime. The graph remains the sole owner of
/// the AP04 pressure action, so discard and shutdown can detach it first.
@MainActor public protocol ModelMemoryPressureObserving: AnyObject {
    func start(_ deliver: @escaping @MainActor () async -> Void)
    func stop()
}

@MainActor public final class MacOSModelMemoryPressureObserver: ModelMemoryPressureObserving {
    private var source: DispatchSourceMemoryPressure?
    public init() {}
    public func start(_ deliver: @escaping @MainActor () async -> Void) {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { Task { @MainActor in await deliver() } }
        self.source = source
        source.resume()
    }
    public func stop() { source?.cancel(); source = nil }
}
/// AppKit-independent termination transaction.  A second request joins the
/// first; the reply closure is consumed once whether cleanup completes or the
/// bounded deadline wins. Cleanup is intentionally not cancelled on timeout.
@MainActor public final class ApplicationTerminationCoordinator {
    public enum Decision: Sendable, Equatable { case terminateNow, terminateLater }
    private enum CleanupState { case idle, cleaning, cleaned }
    private let shutdown: @MainActor () async -> Void
    private let timeout: @MainActor () async -> Void
    private var cleanupState: CleanupState = .idle
    private var activeReply: (id: UUID, reply: @MainActor (Bool) -> Void)?
    public init(shutdown: @escaping @MainActor () async -> Void, timeout: @escaping @MainActor () async -> Void = { try? await Task.sleep(nanoseconds: 10_000_000_000) }) { self.shutdown = shutdown; self.timeout = timeout }
    @discardableResult public func request(reply: @escaping @MainActor (Bool) -> Void) -> Decision {
        guard activeReply == nil else { return .terminateLater }
        if cleanupState == .cleaned { return .terminateNow }
        if cleanupState == .idle {
            cleanupState = .cleaning
            let shutdown = shutdown
            Task { @MainActor [weak self] in await shutdown(); self?.finishedCleanup() }
        }
        let transaction = UUID(); activeReply = (transaction, reply)
        let timeout = timeout
        Task { @MainActor [weak self] in await timeout(); self?.finish(transaction: transaction, result: false) }
        return .terminateLater
    }
    private func finishedCleanup() {
        cleanupState = .cleaned
        guard let transaction = activeReply?.id else { return }
        // The active transaction owns the only legal late success reply.
        finish(transaction: transaction, result: true)
    }
    private func finish(transaction: UUID, result: Bool) {
        guard let active = activeReply, active.id == transaction else { return }
        activeReply = nil
        active.reply(result)
    }
}

/// Read-only TCC preflight. This never requests permission and is only read
/// when an explicit operation reaches the P3 adapter.
public final class ProductionMicrophonePreflight: AudioPermissionPreflightChecking, @unchecked Sendable {
    public init() {}
    public func availability() -> ServiceAvailability { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .ready : .unavailable(code: "microphone") }
}

/// Narrow, observation-only lifecycle seam.  Production supplies the
/// NSWorkspace notifications below; cold tests can inject the same events
/// without posting process-wide macOS notifications.
public enum AudioLifecycleEvent: Sendable { case sleep, lock, wake }
public protocol AudioLifecycleEventSourcing: Sendable {
    func setHandler(_ handler: @escaping @Sendable (AudioLifecycleEvent) -> Void)
}

/// Owns one P3 capture adapter and only materializes an owned WAV on `stop`.
/// Construction is inert; no device enumeration or AVCapture session start is
/// performed before `start` is called by the coordinator.
public enum CurrentAudioDevicePreference: Sendable { case value(String?), unavailable }
/// Removes only a session directory whose ownership was established by this
/// service. The narrow boundary makes a failed remove retain ownership for a
/// targeted retry instead of silently forgetting a private artifact.
public protocol OwnedAudioArtifactRemoving: Sendable { func removeOwnedDirectory(_ directory: URL) throws }
public struct FileManagerOwnedAudioArtifactRemover: OwnedAudioArtifactRemoving {
    public init() {}
    public func removeOwnedDirectory(_ directory: URL) throws { try FileManager.default.removeItem(at: directory) }
}
public actor ProductionCoordinatorAudioService: CoordinatorAudioService {
    private let capture: AVAudioCaptureAdapter
    private let audioRoot: URL
    private let catalog: any AudioDeviceCataloging
    private let selectedDeviceUID: String?
    private let selectedDeviceUIDProvider: (@Sendable () async -> CurrentAudioDevicePreference)?
    private let terminal: (any AudioTerminalRouting)?
    private let artifactRemover: any OwnedAudioArtifactRemoving
    private let lifecycleEventSource: (any AudioLifecycleEventSourcing)?
    private var active: DictationSessionID?
    private var preRollSession: DictationSessionID?
    private var ownedArtifacts: [DictationSessionID: URL] = [:]
    private var artifactsWithPCM = Set<DictationSessionID>()
    private var deviceObserver: (any AudioDeviceObserving)?
    private var watchdog: Task<Void, Never>?
    /// Unlike the capture-health watchdog this remains alive after `stop()`.
    /// The coordinator still owns the session while helper inference runs, so
    /// a read-only microphone-permission revocation must invalidate that same
    /// generation before a late result can be inserted.
    private var permissionWatchdog: Task<Void, Never>?
    private let permissionCheckIntervalNanoseconds: UInt64
    private var lifecycleTokens: [NSObjectProtocol] = []
    private var lockToken: NSObjectProtocol?
    private var removalRetries: [DictationSessionID: Task<Void, Never>] = [:]
    public init(audioRoot: URL, selectedDeviceUID: String? = nil, selectedDeviceUIDProvider: (@Sendable () async -> CurrentAudioDevicePreference)? = nil, capture: AVAudioCaptureAdapter = .init(preflight: ProductionMicrophonePreflight()), catalog: any AudioDeviceCataloging = CoreAudioDeviceCatalog(), terminal: (any AudioTerminalRouting)? = nil, deviceObserver: (any AudioDeviceObserving)? = nil, artifactRemover: any OwnedAudioArtifactRemoving = FileManagerOwnedAudioArtifactRemover(), permissionCheckIntervalNanoseconds: UInt64 = 250_000_000, lifecycleEventSource: (any AudioLifecycleEventSourcing)? = nil) {
        self.audioRoot = audioRoot; self.selectedDeviceUID = selectedDeviceUID?.isEmpty == false ? selectedDeviceUID : nil; self.selectedDeviceUIDProvider = selectedDeviceUIDProvider; self.capture = capture; self.catalog = catalog; self.terminal = terminal; self.deviceObserver = deviceObserver; self.artifactRemover = artifactRemover; self.permissionCheckIntervalNanoseconds = max(1, permissionCheckIntervalNanoseconds); self.lifecycleEventSource = lifecycleEventSource
        deviceObserver?.setHandler { event in
            guard case let .lost(uid) = event else { return }
            _ = capture.handleDeviceLoss(uid: uid)
        }
        // These are observation-only lifecycle ports. They never wake or
        // start capture; they merely invalidate the owned session if one is
        // active. The same generation-bound terminal router handles audio,
        // lock, sleep and wake uniformly.
        if let lifecycleEventSource {
            lifecycleEventSource.setHandler { [weak self] _ in
                Task { await self?.captureTerminatedForLifecycle() }
            }
        } else {
            Task { [weak self] in await self?.installLifecycleObservers() }
        }
    }
    private func installLifecycleObservers() {
        guard lifecycleTokens.isEmpty else { return }
        // Session resignation is fast user switching, not a reliable screen-lock signal.
        lockToken = DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: nil) { [weak self] _ in
            Task { await self?.captureTerminatedForLifecycle() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification] {
            lifecycleTokens.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { await self?.captureTerminatedForLifecycle() }
            })
        }
    }
    public func armPreRoll() async throws { throw DictationError.unavailable("pre-roll requires session ownership") }
    public func disarmPreRoll() async { if let preRollSession { await stopCapture(session: preRollSession) } }
    public func armPreRoll(session: DictationSessionID) async throws {
        _ = try await startCapture(session: session, mode: .pushToTalk, preRoll: true)
    }
    public func start(session: DictationSessionID, mode: RecordingMode) async throws -> URL {
        try await startCapture(session: session, mode: mode, preRoll: false)
    }
    private func startCapture(session: DictationSessionID, mode: RecordingMode, preRoll: Bool) async throws -> URL {
        PerfLog.current?.mark(.audioServiceEntered)
        guard active == nil || (!preRoll && active == session && preRollSession == session) else { throw DictationError.busy(.recording) }
        active = session
        if preRoll { preRollSession = session }
        let configuredUID: String?
        if let selectedDeviceUIDProvider {
            let preference = await selectedDeviceUIDProvider()
            guard active == session else { throw DictationError.cancelled }
            switch preference {
            case .value(let current): configuredUID = current
            case .unavailable: capture.abort(.cancel); preRollSession = nil; active = nil; throw DictationError.unavailable("audio_preference")
            }
        } else { configuredUID = selectedDeviceUID }
        PerfLog.current?.mark(.devicePreferenceReady)
        // The actor may have yielded while reading encrypted preferences.  A
        // terminal/cancel in that interval owns the session; never open mic.
        guard active == session else { throw DictationError.cancelled }
        // AVAudioCaptureAdapter snapshots this callback before enqueueing an
        // asynchronous terminal notification. Capture the session here, not
        // `active` at delivery time, so a late S1 callback cannot abort S2.
        capture.setTerminalHandler { [weak self] status in Task { await self?.captureTerminated(session: session, status: status) } }
        let devices = catalog.devices()
        // A persisted selection is a binding, not a hint: do not silently
        // substitute the current default if it is absent during a session.
        let device = configuredUID.flatMap { wanted in devices.first(where: { $0.uid == wanted }) } ?? (configuredUID == nil ? (devices.first(where: \.isDefault) ?? devices.first) : nil)
        guard active == session, let device else { if active == session { capture.abort(.cancel); preRollSession = nil; active = nil }; throw DictationError.unavailable("audio_device") }
        PerfLog.current?.mark(.captureStartRequested)
        do { try capture.start(sessionID: session, device: device, mode: mode, now: DispatchTime.now().uptimeNanoseconds, preRoll: preRoll) }
        catch { capture.abort(.cancel); preRollSession = nil; active = nil; throw error }
        preRollSession = preRoll ? session : nil
        PerfLog.current?.mark(.captureStartReturned)
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                guard !Task.isCancelled, let self else { return }
                guard let deadline = self.capture.nextHealthDeadline() else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                if deadline > now { try? await Task.sleep(nanoseconds: deadline - now) }
                guard !Task.isCancelled else { return }
                if await self.watchdogAbortIfNeeded(session: session) { return }
            }
        }
        permissionWatchdog?.cancel()
        permissionWatchdog = Task { [weak self, permissionCheckIntervalNanoseconds] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: permissionCheckIntervalNanoseconds)
                guard !Task.isCancelled, let self else { return }
                if await self.permissionAbortIfNeeded(session: session) { return }
            }
        }
        // P3 writes the final owned artifact only after stop; the placeholder
        // never leaves this service or reaches the helper.
        return audioRoot.appendingPathComponent("pending.wav")
    }
    public func stop(session: DictationSessionID) async throws -> URL { try await stopResult(session: session).url }
    public func stopResult(session: DictationSessionID) async throws -> AudioCaptureResult {
        guard active == session else { throw DictationError.cancelled }
        let result = try capture.stopResult(in: audioRoot, session: session)
        ownedArtifacts[session] = result.url
        if result.sampleCount > 0 { artifactsWithPCM.insert(session) }
        return result
    }
    public func interrupt(session: DictationSessionID) async -> Bool {
        guard active == session else { return false }
        if artifactsWithPCM.contains(session) { return true }
        return capture.interruptRetainingPCM()
    }
    public func stopCapture(session: DictationSessionID) async {
        guard active == session else { return }
        watchdog?.cancel(); watchdog = nil
        permissionWatchdog?.cancel(); permissionWatchdog = nil
        capture.abort(.cancel)
        preRollSession = nil; active = nil
    }
    public func cleanup(session: DictationSessionID) async {
        // Idempotent and exact: remove only the directory created for this
        // session's newly-written WAV, never scan the audio root or old data.
        if active == session { await stopCapture(session: session) }
        guard let artifact = ownedArtifacts[session] else { return }
        let directory = artifact.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().standardizedFileURL == audioRoot.standardizedFileURL else { return }
        do {
            try artifactRemover.removeOwnedDirectory(directory)
            ownedArtifacts.removeValue(forKey: session)
            artifactsWithPCM.remove(session)
            removalRetries.removeValue(forKey: session)?.cancel()
        } catch {
            scheduleRemovalRetry(session: session, remaining: 2)
        }
    }
    private func watchdogAbortIfNeeded(session: DictationSessionID) async -> Bool {
        guard active == session else { return true }
        guard capture.enforceCaptureHealth(now: DispatchTime.now().uptimeNanoseconds) else { return false }
        // enforceCaptureHealth emits the capture terminal callback carrying
        // this session token; routing here as well would double-cancel.
        return true
    }
    private func permissionAbortIfNeeded(session: DictationSessionID) async -> Bool {
        guard active == session else { return true }
        guard case .ready = capture.permissionAvailability() else {
            await captureTerminated(session: session)
            return true
        }
        return false
    }
    private func captureTerminatedForLifecycle() async {
        guard let active else { return }
        if preRollSession == active { await captureTerminated(session: active); return }
        if artifactsWithPCM.contains(active) {
            await terminal?.routeCompletion(session: active, reason: .lockedCopied)
        } else if !capture.interruptRetainingPCM(reason: .lockedCopied) {
            await captureTerminated(session: active)
        }
    }
    private func captureTerminated(session: DictationSessionID, status: PCMExtractionStatus) async {
        guard active == session else { return }
        if case .completed(let reason) = status {
            let snapshot = capture.safeDiagnosticsSnapshot()
            // An explicit stop may already have consumed the retained PCM.
            // Its queued notification must not cancel ongoing transcription.
            guard case .finishing(let finishedSession) = snapshot.state, finishedSession == session else { return }
            guard snapshot.bufferedSamples > 0 else { await captureTerminated(session: session); return }
            watchdog?.cancel(); watchdog = nil
            // Keep permission observation and ownership alive through helper
            // processing, exactly as for an explicit stop. Never abort PCM here.
            await terminal?.routeCompletion(session: session, reason: reason)
        } else {
            await captureTerminated(session: session)
        }
    }
    private func captureTerminated(session: DictationSessionID) async {
        guard active == session else { return }
        watchdog?.cancel(); watchdog = nil
        permissionWatchdog?.cancel(); permissionWatchdog = nil
        capture.abort(.cancel)
        preRollSession = nil; active = nil
        await terminal?.routeTerminal(session: session)
    }
    private func scheduleRemovalRetry(session: DictationSessionID, remaining: Int) {
        guard remaining > 0, removalRetries[session] == nil else { return }
        removalRetries[session] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            await self?.retryRemoval(session: session, remaining: remaining)
        }
    }
    private func retryRemoval(session: DictationSessionID, remaining: Int) async {
        removalRetries[session] = nil
        guard let artifact = ownedArtifacts[session] else { return }
        let directory = artifact.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().standardizedFileURL == audioRoot.standardizedFileURL else { return }
        do { try artifactRemover.removeOwnedDirectory(directory); ownedArtifacts.removeValue(forKey: session)
            artifactsWithPCM.remove(session) }
        catch { scheduleRemovalRetry(session: session, remaining: remaining - 1) }
    }
}

/// The sole production P2 intake wrapper. Its constructor only allocates the
/// existing tap adapter; `install()` is the explicit post-preflight action.
public final class ProductionInputMonitoringPreflight: EventTapPreflightChecking, @unchecked Sendable {
    public init() {}
    public func availability() -> ServiceAvailability { CGPreflightListenEventAccess() ? .ready : .unavailable(code: "input-monitoring") }
}
/// Lock-protected, typed in-memory projection of encrypted preferences. The
/// event-tap callback only reads this cache; it never synchronously opens the
/// database and therefore cannot leak keyboard facts into persistence.
public final class ProductionShortcutConfigurationCache: @unchecked Sendable {
    private let store: EncryptedSQLiteStore
    private let globeLaunchEvidence: ProductionGlobeLaunchEvidence?
    private let lock = NSLock()
    private var values: [ConfiguredShortcut] = []
    public init(store: EncryptedSQLiteStore, globeLaunchEvidence: ProductionGlobeLaunchEvidence? = nil) { self.store = store; self.globeLaunchEvidence = globeLaunchEvidence }
    public func snapshot() -> [ConfiguredShortcut] { lock.withLock { values } }
    public func refresh() async {
        let next: [ConfiguredShortcut]
        if let preferences = try? await store.preferences() {
            next = preferences.snapshot.shortcuts.compactMap { Self.productionConfiguration($0, globeQualifiedAllowed: globeLaunchEvidence?.qualifiesLaunchLoad() ?? false) }
        } else { next = [] }
        lock.withLock { values = next }
    }
    public static func productionConfiguration(_ value: PersistedShortcut, globeQualifiedAllowed: Bool = false) -> ConfiguredShortcut? {
        // Globe-qualified bindings load only through the audited launch
        // evidence (a qualified, device-bound proof for a currently connected
        // keyboard); without it they stay excluded, fail-closed by design.
        // Secure reinsert has no production owner yet, so persisted reinsert
        // bindings are excluded before they can reach the dispatcher.
        guard value.mode != .reinsert else { return nil }
        if value.fnGlobeProfile == .globeQualified, !globeQualifiedAllowed { return nil }
        guard let profile = FnGlobeProfile(rawValue: value.fnGlobeProfile.rawValue),
              let mode = ConfiguredShortcutMode(rawValue: value.mode.rawValue),
              let descriptor = try? ShortcutDescriptor(keyCode: value.keyCode, modifiers: .init(rawValue: value.modifiers), fnGlobeProfile: profile) else { return nil }
        return .init(descriptor: descriptor, mode: mode)
    }
}
public final class ProductionHotkeyEventSource: HotkeyEventSource, @unchecked Sendable {
    public struct PhysicalDispatch: Sendable, Equatable { public let actions: [HotkeyAction]; public let suppressSystemEvent: Bool; public init(actions: [HotkeyAction], suppressSystemEvent: Bool) { self.actions = actions; self.suppressSystemEvent = suppressSystemEvent } }
    /// A production callback can be queued behind a settings reload or disable.
    /// The consumer checks this token immediately before consuming a batch so
    /// an already-enqueued old start action is harmless.
    public struct ActionBatch: @unchecked Sendable {
        public let actions: [HotkeyAction]
        public let perfTiming: PerfInputTiming?
        private let valid: @Sendable () -> Bool
        fileprivate init(actions: [HotkeyAction], perfTiming: PerfInputTiming?, valid: @escaping @Sendable () -> Bool) { self.actions = actions; self.perfTiming = perfTiming; self.valid = valid }
        public func isCurrent() -> Bool { valid() }
    }
    private let preflight: any EventTapPreflightChecking
    private let receive: @Sendable ([HotkeyAction]) -> Void
    private let receiveBatch: (@Sendable (ActionBatch) -> Void)?
    private let schedulesTimer: Bool
    private let beforeTickDelivery: (@Sendable () -> Void)?
    private let temporaryCapture: EventTapTemporaryCaptureController?
    private let descriptorProvider: @Sendable () -> [ConfiguredShortcut]
    private let matcher: ConfiguredShortcutMatcher
    private let dispatcher: ModeAwareShortcutDispatcher
    private lazy var tap: CGEventTapAdapter = CGEventTapAdapter(preflight: preflight, rawHandler: { [weak self] observation in
        guard let self else { return false }
        let (dispatch, batch) = self.dispatchBoundFromTap(observation)
        self.deliver(batch)
        return dispatch.suppressSystemEvent
    }, temporaryCapture: temporaryCapture)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var actionGeneration: UInt64 = 0
    private var gestureDownAt: UInt64?
    private var gestureUpAt: UInt64?
    private var gestureEventAt: UInt64 = 0
    private var pendingToggleExpiry: UInt64?
    private let doubleTapWindow: UInt64
    private var gestureStarted = false
    public init(preflight: any EventTapPreflightChecking = ProductionInputMonitoringPreflight(), temporaryCapture: EventTapTemporaryCaptureController? = nil, descriptorProvider: @escaping @Sendable () -> [ConfiguredShortcut] = { [] }, keyboardIdentity: (any CurrentKeyboardIdentityObserving)? = nil, fnQualification: FnGlobeQualificationService? = nil, configuration: HotkeyConfiguration = .init(), reinsertIntent: @escaping @Sendable () -> Void = {}, receive: @escaping @Sendable ([HotkeyAction]) -> Void = { _ in }, receiveBatch: (@Sendable (ActionBatch) -> Void)? = nil, schedulesTimer: Bool = true, physicalKeyIsDown: @escaping @Sendable (UInt16) -> Bool? = { HardwareShortcutKeyState.isDown($0) }, beforeTickDelivery: (@Sendable () -> Void)? = nil) {
        self.doubleTapWindow = configuration.doubleTapWindowNanoseconds; self.preflight = preflight; self.temporaryCapture = temporaryCapture; self.descriptorProvider = descriptorProvider; self.matcher = .init(configured: descriptorProvider(), identity: keyboardIdentity, qualification: fnQualification); self.dispatcher = .init(configuration: configuration, onReinsert: reinsertIntent, physicalKeyIsDown: physicalKeyIsDown); self.receive = receive; self.receiveBatch = receiveBatch; self.schedulesTimer = schedulesTimer; self.beforeTickDelivery = beforeTickDelivery
    }
    public func install() throws { reloadSettings(); try tap.installIfReady() }
    public func uninstall() { neutralizeGestureAndCancel(); tap.uninstall() }
    /// Called after an explicit successful settings save, and before each
    /// physical install. Replacing config atomically invalidates any old key.
    public func reloadSettings() {
        let configured = descriptorProvider()
        let batch = lock.withLock {
            resetLocked()
            matcher.replaceConfigured(configured)
            return bindLocked([.cancelRecording])
        }
        deliver(batch)
    }
    public func receiveFromTap(_ observation: RawShortcutObservation) -> [HotkeyAction] {
        dispatchFromTap(observation).actions
    }
    public func dispatchFromTap(_ observation: RawShortcutObservation) -> PhysicalDispatch {
        dispatchBoundFromTap(observation).0
    }
    func dispatchBoundFromTap(_ observation: RawShortcutObservation) -> (PhysicalDispatch, ActionBatch?) {
        if temporaryCapture?.receive(observation) == true { return (.init(actions: [], suppressSystemEvent: true), nil) }
        return lock.withLock {
            if observation.kind == .keyDown, observation.keyCode == 53 {
                resetLocked()
                let batch = bindLocked([.cancelRecording])
                return (.init(actions: [.cancelRecording], suppressSystemEvent: false), batch)
            }
            guard let matched = matcher.consume(observation) else { return (.init(actions: [], suppressSystemEvent: false), nil) }
            measureGesture(matched)
            let actions = dispatcher.consume(matched)
            let batch = bindLocked(actions)
            if case .keyUp = matched.event, matched.mode == .pushToTalk, !gestureStarted { gestureDownAt = nil; gestureUpAt = nil; pendingToggleExpiry = nil }
            rescheduleTimerLocked()
            return (.init(actions: actions, suppressSystemEvent: matched.suppressesSystemEvent), batch)
        }
    }
    public func nextActions(for observation: RawShortcutObservation) -> [HotkeyAction] {
        lock.withLock {
            guard let matched = matcher.consume(observation) else { return [] }
            measureGesture(matched)
            let actions = dispatcher.consume(matched)
            _ = bindLocked(actions)
            if case .keyUp = matched.event, matched.mode == .pushToTalk, !gestureStarted { gestureDownAt = nil; gestureUpAt = nil; pendingToggleExpiry = nil }
            rescheduleTimerLocked()
            return actions
        }
    }
    /// Reducer transition and token binding share one source lock with tap/reset.
    /// Delivery (including the deterministic test barrier) occurs outside it.
    public func tick(timestamp: UInt64) -> [HotkeyAction] {
        let batch = lock.withLock {
            let actions = dispatcher.tick(timestamp: timestamp)
            if !gestureStarted, let expiry = pendingToggleExpiry, timestamp > expiry {
                gestureDownAt = nil; gestureUpAt = nil; pendingToggleExpiry = nil
            }
            let batch = bindLocked(actions)
            rescheduleTimerLocked()
            return batch
        }
        beforeTickDelivery?()
        deliver(batch)
        return batch?.actions ?? []
    }
    public func nextActions(for event: HotkeyPlatformEvent) -> [HotkeyAction] {
        let now = DispatchTime.now().uptimeNanoseconds
        let input: HotkeyEvent = switch event { case .keyDown: .keyDown(timestamp: now, isRepeat: false); case .keyUp: .keyUp(timestamp: now); case .flagsChanged: .tick(timestamp: now); case .tapDisabled: .tapDisabled; case .wake: .wake }
        // Compatibility/lifecycle seam only. Physical key events enter through
        // `RawShortcutObservation` above and are matched first.
        switch event {
        case .tapDisabled, .wake: break
        case .keyDown, .keyUp, .flagsChanged: return []
        }
        return lock.withLock {
            let actions = dispatcher.consume(.init(event: input, mode: .toggle))
            _ = bindLocked(actions)
            rescheduleTimerLocked()
            return actions
        }
    }
    private func rescheduleTimerLocked() {
        guard schedulesTimer else { return }
        let deadline = dispatcher.nextDeadline()
        timer?.setEventHandler {}; timer?.cancel(); timer = nil
        guard let deadline else { return }
        let created = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        created.schedule(deadline: .init(uptimeNanoseconds: deadline))
        created.setEventHandler { [weak self] in
            _ = self?.tick(timestamp: DispatchTime.now().uptimeNanoseconds)
        }
        timer = created; created.resume()
    }
    /// Coordinator has validated the owning session before calling this. No
    /// cancel batch is emitted: retained audio is already being finalized.
    public func completeProcessing() { neutralizeAfterAudioCompletion() }
    public func neutralizeAfterAudioCompletion() { lock.withLock { resetLocked() } }
    private func resetLocked() {
        actionGeneration &+= 1
        matcher.cancelActiveGesture(); dispatcher.reset()
        gestureDownAt = nil; gestureUpAt = nil; pendingToggleExpiry = nil; gestureStarted = false
        timer?.setEventHandler {}; timer?.cancel(); timer = nil
    }
    private func neutralizeGestureAndCancel() {
        let batch = lock.withLock { resetLocked(); return bindLocked([.cancelRecording]) }
        deliver(batch)
    }
    /// Called only while holding the source lock, immediately after reducing.
    private func measureGesture(_ matched: MatchedShortcutEvent) {
        switch matched.event {
        case .keyDown(let timestamp, let isRepeat):
            gestureEventAt = timestamp
            guard !isRepeat, matched.mode != .reinsert else { return }
            if !gestureStarted, let expiry = pendingToggleExpiry, timestamp > expiry {
                gestureDownAt = nil; gestureUpAt = nil; pendingToggleExpiry = nil
            }
            if gestureDownAt == nil { gestureDownAt = timestamp; gestureStarted = false }
        case .keyUp(let timestamp):
            gestureEventAt = timestamp
            if gestureStarted, matched.mode == .pushToTalk { gestureUpAt = timestamp }
            if !gestureStarted, matched.mode == .toggle || matched.physicalKeyCode == ShortcutDescriptor.rightOptionKeyCode { pendingToggleExpiry = timestamp &+ doubleTapWindow }
        default: break
        }
    }
    private func bindLocked(_ actions: [HotkeyAction]) -> ActionBatch? {
        guard !actions.isEmpty else { return nil }
        if (actions.contains(.stopAndProcess) || actions.contains(.maximumDurationReached)) || actions.contains(.cancelRecording) || actions.contains(.resetInputTap) || actions.contains(.disarmPreRoll) || actions.contains(.discardPreRoll) {
            actionGeneration &+= 1
        }
        let generation = actionGeneration
        let isStop = (actions.contains(.stopAndProcess) || actions.contains(.maximumDurationReached))
        let timing = gestureDownAt.map { PerfInputTiming(downAt: $0, upAt: gestureUpAt, stopAt: isStop ? (gestureUpAt ?? gestureEventAt) : nil) }
        if actions.contains(.startPushToTalk) || actions.contains(.startToggle) { gestureStarted = true }
        if (actions.contains(.stopAndProcess) || actions.contains(.maximumDurationReached)) { gestureDownAt = nil; gestureUpAt = nil; pendingToggleExpiry = nil; gestureStarted = false }
        if actions.contains(.cancelRecording) || actions.contains(.resetInputTap) || ((actions.contains(.disarmPreRoll) || actions.contains(.discardPreRoll)) && !actions.contains(.armPreRoll)) { gestureDownAt = nil; gestureUpAt = nil; pendingToggleExpiry = nil; gestureStarted = false }
        return .init(actions: actions, perfTiming: timing, valid: { [weak self] in self?.lock.withLock { self?.actionGeneration == generation } ?? false })
    }
    private func deliver(_ batch: ActionBatch?) {
        guard let batch else { return }
        // Never relabel already reduced actions with the generation at delivery.
        guard let receiveBatch else { if batch.isCurrent() { receive(batch.actions) }; return }
        receiveBatch(batch)
    }

}

public struct ProductionCompositionClock: DictationMonotonicClock, KlangschriftTextInsertion.MonotonicClock { public init() {} ; public func nowNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds } }
public struct ProductionDiagnostics: DictationDiagnostics, RuntimeDiagnosticsRecording, PrivacyDiagnosticSink { public init() {} ; public func record(code: String) {} ; public func recordInsertion(event: InsertionDiagnosticEvent) { InsertionLog.record(.event(event)) } }
public struct ProductionSleeper: Sleeper { public init() {} ; public func sleep(nanoseconds: UInt64) async { try? await Task.sleep(nanoseconds: nanoseconds) } }
/// Ephemeral, single-session recovery storage. This is intentionally neither
/// history nor a pasteboard: unsafe outcomes remain local until the user
/// chooses the existing Copy action.
public actor ProductionRecoveryPresenter: RecoveryPresenter, DictationDraftPresenting {
    private var draft: (session: UUID?, revision: UInt64, text: String)?
    private var activeSession: UUID?
    private var revision: UInt64 = 0
    public init() {}
    public func presentRecovery() async {}
    public func presentRecovery(draft: String) async { publish(draft, session: nil) }
    public func presentRecovery(draft: String, session: UUID?) async {
        // A terminal result belongs only to the recording session that owns the
        // recovery slot.  Once a newer session starts, a late older result must
        // never replace its draft.
        if let session, let activeSession, session != activeSession { return }
        publish(draft, session: session)
    }
    /// Normal successful results enter the same session-owned local draft as
    /// recovery text. No history or pasteboard side effect is involved.
    public func beginDraft(session: DictationSessionID) async { await beginRecovery(session: session.rawValue) }
    public func publishDraft(_ text: String, session: DictationSessionID) async {
        guard activeSession == session.rawValue else { return }
        publish(text, session: session.rawValue)
    }
    public func latestDraft() -> AP05LatestDraft? { draft.map { .init(sessionID: $0.session, revision: $0.revision, text: $0.text) } }
    public func replaceLatestDraft(_ text: String, sessionID: UUID?, revision expectedRevision: UInt64) -> AP05LatestDraft? {
        guard let draft, draft.session == sessionID, draft.revision == expectedRevision, activeSession == sessionID else { return nil }
        publish(text, session: sessionID)
        return self.draft.map { .init(sessionID: $0.session, revision: $0.revision, text: $0.text) }
    }
    public func beginRecovery(session: UUID) async {
        activeSession = session
        // A new recording boundary makes an older recovery draft unavailable.
        draft = nil
        revision &+= 1
    }
    public func presentClipboardRestoreFailed() async {}
    public func takeLatest() -> String? { draft?.text }
    public func clearRecovery(session: UUID) async {
        guard draft?.session == session else { return }
        draft = nil
    }
    public func clear() async { draft = nil; activeSession = nil; revision &+= 1 }
    private func publish(_ text: String, session: UUID?) { revision &+= 1; draft = (session, revision, text) }
}

/// Composition owns the sole dashboard/rail pasteboard gateway. Constructing
/// it is cold: `NSPasteboard.general` is resolved only after an explicit click.
public struct ProductionInterruptedTextCopier: InterruptedTextCopying {
    public init() {}
    public func copy(_ text: String, session: DictationSessionID) async -> Bool {
        await MainActor.run { guard !Task.isCancelled else { return false }; return ProductionDashboardClipboardWriter().write(text) }
    }
}
@MainActor public final class ProductionDashboardClipboardWriter: DashboardClipboardWriting {
    private let performWrite: @MainActor (String) -> Bool
    public init() {
        performWrite = { text in
            let pasteboard = NSPasteboard.general
            pasteboard.prepareForNewContents(with: .currentHostOnly)
            return pasteboard.setString(text, forType: .string)
        }
    }
    public init(write: @escaping @MainActor (String) -> Bool) { performWrite = write }
    public func write(_ text: String) -> Bool { performWrite(text) }
}

@MainActor public protocol SelectedTextReading: AnyObject { func selectedText() -> String? }
public enum SelectedTextSanitizer {
    public static func sanitize(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty, !normalized.contains("\0"), normalized.utf8.count <= 4_096 else { return nil }
        return normalized
    }
}
public enum AXStringAttributeResult: Equatable, Sendable { case value(String), missing, invalidType, failed }
public enum SelectedTextAXDecision {
    public static func selectedText(role: AXStringAttributeResult, subrole: AXStringAttributeResult, readSelectedText: () -> AXStringAttributeResult) -> String? {
        guard case let .value(roleValue) = role, !isSecure(roleValue) else { return nil }
        switch subrole {
        case .missing: break
        case let .value(value): guard !isSecure(value) else { return nil }
        case .invalidType, .failed: return nil
        }
        guard case let .value(selected) = readSelectedText() else { return nil }
        return SelectedTextSanitizer.sanitize(selected)
    }
    private static func isSecure(_ value: String) -> Bool {
        value == (kAXSecureTextFieldSubrole as String) || value.localizedCaseInsensitiveContains("secure")
    }
}
@MainActor public final class ProductionAXSelectedTextReader: SelectedTextReading {
    public init() {}
    public func selectedText() -> String? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var applicationValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &applicationValue) == .success,
              let application = validatedElement(applicationValue) else { return nil }
        var elementValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &elementValue) == .success,
              let element = validatedElement(elementValue) else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.20)
        let role = stringAttribute(element, name: kAXRoleAttribute as CFString)
        let subrole = stringAttribute(element, name: kAXSubroleAttribute as CFString)
        return SelectedTextAXDecision.selectedText(role: role, subrole: subrole) {
            self.stringAttribute(element, name: kAXSelectedTextAttribute as CFString)
        }
    }
    private func stringAttribute(_ element: AXUIElement, name: CFString) -> AXStringAttributeResult {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name, &value)
        if result == .noValue || result == .attributeUnsupported { return .missing }
        guard result == .success else { return .failed }
        guard let string = value as? String else { return .invalidType }
        return .value(string)
    }
    private func validatedElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}

@MainActor public final class GraphPresentationActions: DictationPresentationActions {
    private var runtime: AppRuntime?
    private weak var graph: ProductionAppGraph?
    private var quit: (@MainActor () async -> Void)?
    private var dashboardOpen: (@MainActor () -> Void)?
    private var recoveryCopy: (@MainActor () async -> PresentationActionOutcome)?
    func attach(runtime: AppRuntime) { guard self.runtime == nil else { return }; self.runtime = runtime }
    func attach(graph: ProductionAppGraph) { self.graph = graph }
    func attachQuit(_ value: @escaping @MainActor () async -> Void) { quit = value }
    func attachDashboardOpen(_ value: @escaping @MainActor () -> Void) { dashboardOpen = value }
    func attachRecoveryCopy(_ value: @escaping @MainActor () async -> PresentationActionOutcome) { recoveryCopy = value }
    public func openDashboard() { dashboardOpen?() }
    public func requestStartOrStop() async { await graph?.startIfReady() }
    public func requestStopAndProcess() async { guard let runtime else { return }; await runtime.coordinator.consume(.stopAndProcess) }
    public func requestCancel() async { guard let runtime else { return }; await runtime.coordinator.consume(.cancelRecording) }
    /// Explicit recovery action: the draft was never put on the clipboard by
    /// the unsafe insertion path, so this is the sole conscious copy route.
    public func requestInsertLastRecovery() async {
        if let recoveryCopy { _ = await recoveryCopy() }
        else if let graph { _ = await graph.copyRecoveryDraft() }
    }
    public func railContext() async -> RailContext { await graph?.railContext() ?? .init() }
    public func selectRail(_ kind: String, id: String) async -> PresentationActionOutcome { await graph?.selectRail(kind, id: id) ?? .unavailable }
    public func copyRailTranscript(_ id: UUID) async -> PresentationActionOutcome { await graph?.copyRailTranscript(id) ?? .unavailable }
    public func copyNewestTranscript() async -> PresentationActionOutcome { await graph?.copyNewestTranscript() ?? .unavailable }
    public func addSelectedTextAsRecognitionHint() async -> PresentationActionOutcome { await graph?.addSelectedTextAsRecognitionHint() ?? .unavailable }
    public func requestCloseRail() async -> PresentationActionOutcome { await graph?.closeRail() ?? .failed }
    public func requestQuit() { Task { if let quit { await quit() } else { await self.graph?.shutdown() } } }
}
/// One attach-once bridge from the coordinator to the visible controller. The
/// bridge carries only presentation metadata, never transcript or audio data.
@MainActor public final class AttachablePresentationSink: DictationUIState, @unchecked Sendable {
    private weak var controller: DictationPresentationController?
    private weak var statisticsOwner: DashboardViewModel?
    private weak var historyOwner: DashboardViewModel?
    private var statisticsOwnerAttached = false
    private var historyOwnerAttached = false
    private var latestGeneration: UInt64 = 0
    private var latestSessionID: UUID?
    private var pendingStatisticsGeneration: UInt64?
    private var pendingHistoryGeneration: UInt64?
    private var completedStatisticsGeneration: UInt64?
    private var completedHistoryGeneration: UInt64?
    private var terminalPresentationGeneration: UInt64?
    private var dashboardRefreshTask: Task<Void, Never>?
    public init() {}
    public func attach(_ controller: DictationPresentationController) -> Bool { guard self.controller == nil else { return false }; self.controller = controller; return true }
    public func attachStatisticsRefresh(_ owner: DashboardViewModel) -> Bool { guard !statisticsOwnerAttached else { return false }; statisticsOwnerAttached = true; statisticsOwner = owner; return true }
    public func attachHistoryRefresh(_ owner: DashboardViewModel) -> Bool { guard !historyOwnerAttached else { return false }; historyOwnerAttached = true; historyOwner = owner; return true }
    public func historyDidPersist(session: DictationSessionID) {
        guard session.rawValue == latestSessionID else { return }
        pendingHistoryGeneration = latestGeneration
    }
    public func showAudioCompletion(_ reason: AudioCaptureCompletionReason, metadata: DictationUIStateMetadata) async {
        guard metadata.generation == latestGeneration, metadata.sessionID?.rawValue == latestSessionID else { return }
        let notice: DictationPresentationNotice = switch reason { case .maximumDuration: .maximumDuration; case .callbackLoss: .callbackLoss; case .interrupted: .interrupted; case .interruptedCopied: .interruptedCopied; case .lockedCopied: .lockedCopied }
        controller?.showNotice(notice)
    }
    public func waitForPendingDashboardRefreshes() async { await dashboardRefreshTask?.value }
    public func show(_ state: DictationCoordinator.State) async { await show(state, metadata: .init(sessionID: nil, generation: 0)) }
    public func show(_ state: DictationCoordinator.State, metadata: DictationUIStateMetadata) async {
        guard metadata.generation >= latestGeneration else { return }
        let sessionID = metadata.sessionID?.rawValue
        if metadata.generation > latestGeneration {
            latestGeneration = metadata.generation
            latestSessionID = sessionID
            pendingStatisticsGeneration = nil
            pendingHistoryGeneration = nil
            terminalPresentationGeneration = nil
        } else if let sessionID, let latestSessionID, sessionID != latestSessionID {
            return
        } else if latestSessionID == nil, sessionID != nil {
            latestSessionID = sessionID
        }
        if state == .persisting, sessionID != nil { pendingStatisticsGeneration = metadata.generation }
        if state == .failed {
            pendingStatisticsGeneration = nil
            pendingHistoryGeneration = nil
            terminalPresentationGeneration = metadata.generation
        } else if state == .recovery {
            terminalPresentationGeneration = metadata.generation
        } else if state == .idle, sessionID == nil {
            pendingStatisticsGeneration = nil
            pendingHistoryGeneration = nil
        }
        let completedWithActiveSession = state == .idle && sessionID != nil
        let recoveryWithActiveSession = state == .recovery && sessionID != nil
        let phase: DictationPresentationPhase = switch state { case .idle: completedWithActiveSession ? .success : .idle; case .prearming: .busy; case .listening: .listening; case .failed: .error; case .recovery: .recoveryCopied; case .finalizing, .transcribing, .transforming, .persisting, .inserting: .processing }
        let value = DictationPresentationState(phase: phase, sessionID: metadata.sessionID?.rawValue, generation: metadata.generation, listeningStartedAt: phase == .listening ? Date() : nil, failure: metadata.failure.flatMap { DictationPresentationFailure(rawValue: $0.rawValue) })
        let suppressTerminalFollowupIdle = state == .idle && terminalPresentationGeneration == metadata.generation
        if !suppressTerminalFollowupIdle { controller?.apply(value) }
        let terminalSuccess = completedWithActiveSession || recoveryWithActiveSession
        let refreshStatistics = terminalSuccess
            && pendingStatisticsGeneration == metadata.generation
            && completedStatisticsGeneration != metadata.generation
        let refreshHistory = terminalSuccess
            && pendingHistoryGeneration == metadata.generation
            && completedHistoryGeneration != metadata.generation
        if refreshStatistics {
            completedStatisticsGeneration = metadata.generation
            pendingStatisticsGeneration = nil
        }
        if refreshHistory {
            completedHistoryGeneration = metadata.generation
            pendingHistoryGeneration = nil
        }
        scheduleDashboardRefresh(statistics: refreshStatistics, history: refreshHistory)
    }
    private func scheduleDashboardRefresh(statistics: Bool, history: Bool) {
        guard statistics || history else { return }
        let previous = dashboardRefreshTask
        let statisticsOwner = statistics ? self.statisticsOwner : nil
        let historyOwner = history ? self.historyOwner : nil
        dashboardRefreshTask = Task { @MainActor in
            await previous?.value
            if statistics { await statisticsOwner?.statisticsDidChange() }
            if history { await historyOwner?.historyDidChange() }
        }
    }
}
@MainActor private final class GraphPresentationPreflight: PresentationPreflightChecking {
    func checkPresentationPreflight() async -> PresentationPreflight {
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if !microphone { return .needsMicrophone }
        return .ready
    }
}

public struct RecognitionHintRecord: Equatable, Sendable {
    public let id: UUID; public let source: String; public let recognitionHint: String?; public let enabled: Bool; public let sortOrder: Int64; public let revision: Int64
    public init(id: UUID, source: String, recognitionHint: String?, enabled: Bool, sortOrder: Int64, revision: Int64) { self.id = id; self.source = source; self.recognitionHint = recognitionHint; self.enabled = enabled; self.sortOrder = sortOrder; self.revision = revision }
}
@MainActor public protocol RecognitionHintPersisting: AnyObject {
    func recognitionHints() async throws -> [RecognitionHintRecord]
    func createRecognitionHint(_ value: String) async throws
    func enableRecognitionHint(_ record: RecognitionHintRecord, value: String) async throws
}
@MainActor public final class RecognitionHintAction {
    private let persistence: any RecognitionHintPersisting
    private var isRunning = false
    public init(persistence: any RecognitionHintPersisting) { self.persistence = persistence }
    public func add(_ value: String) async -> PresentationActionOutcome {
        guard !isRunning else { return .unavailable }
        isRunning = true
        defer { isRunning = false }
        do {
            let entries = try await persistence.recognitionHints()
            if let existing = entries.first(where: { $0.source == value && $0.recognitionHint == value }) {
                if !existing.enabled { try await persistence.enableRecognitionHint(existing, value: value) }
            } else {
                try await persistence.createRecognitionHint(value)
            }
            return .success
        } catch { return .failed }
    }
}
@MainActor private final class ProductionRecognitionHintPersistence: RecognitionHintPersisting {
    private let store: EncryptedSQLiteStore
    init(store: EncryptedSQLiteStore) { self.store = store }
    func recognitionHints() async throws -> [RecognitionHintRecord] {
        try await store.dictionaryEntries().filter { $0.kind == .recognitionHint }.map { .init(id: $0.id, source: $0.source, recognitionHint: $0.recognitionHint, enabled: $0.enabled, sortOrder: $0.sortOrder, revision: $0.revision) }
    }
    func createRecognitionHint(_ value: String) async throws {
        _ = try await store.createDictionaryEntry(.init(kind: .recognitionHint, source: value, replacement: "", recognitionHint: value, enabled: true, matchMode: .literal, caseSensitive: false, sortOrder: 0))
    }
    func enableRecognitionHint(_ record: RecognitionHintRecord, value: String) async throws {
        _ = try await store.updateDictionaryEntry(id: record.id, draft: .init(kind: .recognitionHint, source: value, replacement: "", recognitionHint: value, enabled: true, matchMode: .literal, caseSensitive: false, sortOrder: record.sortOrder), expectedRevision: record.revision)
    }
}

/// Owned production graph. All UI models receive concrete store-backed or
/// platform-backed intents; it never falls back to dashboard/onboarding demos.
@MainActor public protocol AppGraphLifecycle: AnyObject {
    var runtimeHandle: AppRuntime? { get }
    var storeIdentity: ObjectIdentifier { get }
    var rootSurface: AnyView { get }
    var menuSurface: AnyView { get }
    func presentationDidPublish()
    func enableHotkeyAfterExplicitAction() async throws
    func recoverBeforeAcceptingInput() async
    func shutdown() async
}
@MainActor public final class ProductionAppGraph {
    public let runtime: AppRuntime
    public let hotkey: ProductionHotkeyEventSource
    public let hotkeyBridge: HotkeyCoordinatorBridge
    public let dashboard: DashboardViewModel
    public let onboarding: OnboardingRouter
    public let permissions: any PermissionStatusIntent
    /// UI state only; it reuses the composition's existing permission port.
    public var permissionRecovery: PermissionRecoveryViewModel?
    public let presentation: DictationPresentationController
    /// Optional until AP07 places the fixed manifest and bounded native worker
    /// into the installed bundle. Legacy MLX selection is intentionally separate.
    public let modelPresenter: (any AP05ModelPresenting)?
    private let modelLifecycle: (any AP05DesktopModelLifecycleControlling)?
    private let pressureObserver: any ModelMemoryPressureObserving
    private let backingStore: EncryptedSQLiteStore
    private let retentionScheduler: PersistedRetentionScheduler
    private var retentionRunInFlight = false
    private var shutDown = false
    private let actions: GraphPresentationActions
    private let shortcutCache: ProductionShortcutConfigurationCache
    private let clipboard: any DashboardClipboardWriting
    private let selectedTextReader: any SelectedTextReading
    private let recognitionHintAction: RecognitionHintAction
    private let recoveryDraft: ProductionRecoveryPresenter
    public init(runtime: AppRuntime, audio: AudioCoordinatorAdapter, arbiter: EphemeralDictationArbiter, store: EncryptedSQLiteStore, presentation: DictationPresentationController, actions: GraphPresentationActions, modelPresenter: (any AP05ModelPresenting)? = nil, modelLifecycle: (any AP05DesktopModelLifecycleControlling)? = nil, pressureObserver: any ModelMemoryPressureObserving = MacOSModelMemoryPressureObserver(), clipboard: any DashboardClipboardWriting = ProductionDashboardClipboardWriter(), selectedTextReader: any SelectedTextReading = ProductionAXSelectedTextReader(), recognitionHintAction: RecognitionHintAction? = nil, recoveryDraft: ProductionRecoveryPresenter = .init(), retentionScheduler: PersistedRetentionScheduler = .init(), hotkeyPreflight: any EventTapPreflightChecking = ProductionInputMonitoringPreflight(), launchAtLogin: any LaunchAtLoginService = MainAppLaunchAtLoginService()) {
        self.runtime = runtime
        self.backingStore = store
        self.retentionScheduler = retentionScheduler
        self.clipboard = clipboard
        self.selectedTextReader = selectedTextReader
        self.recognitionHintAction = recognitionHintAction ?? RecognitionHintAction(persistence: ProductionRecognitionHintPersistence(store: store))
        self.recoveryDraft = recoveryDraft
        self.modelPresenter = modelPresenter
        self.modelLifecycle = modelLifecycle
        self.pressureObserver = pressureObserver
        actions.attachRecoveryCopy { [weak recoveryDraft, clipboard] in
            guard let draft = await recoveryDraft?.takeLatest() else { return .unavailable }
            return clipboard.write(draft) ? .success : .failed
        }
        let temporaryCapture = EventTapTemporaryCaptureController()
        let proofStore = UserDefaultsFnGlobeCaptureProofStore(defaults: .standard)
        let shortcutCache = ProductionShortcutConfigurationCache(store: store, globeLaunchEvidence: ProductionGlobeLaunchEvidence(proofStore: proofStore, currentRawDeviceIdentifiers: { ProductionKeyboardDeviceEnumeration.connectedKeyboardIdentifiers() }))
        let source = ProductionHotkeyEventSource(preflight: hotkeyPreflight, temporaryCapture: temporaryCapture, descriptorProvider: {
            // The provider is a cache read only. The encrypted store is only
            // refreshed from explicit app actions below.
            return shortcutCache.snapshot()
        }, receiveBatch: { batch in Task {
            guard batch.isCurrent() else { return }
            await runtime.coordinator.consume(batch.actions, perfTiming: batch.perfTiming, isValid: { batch.isCurrent() })
        } })
        self.hotkey = source
        let hotkeyBridge = HotkeyCoordinatorBridge(source: source, preflight: hotkeyPreflight, coordinator: runtime.coordinator)
        self.hotkeyBridge = hotkeyBridge
        let shortcut = ProductionShortcutSetupIntent(capturer: CompositionShortcutCapturer(source: source, base: TemporaryCGEventShortcutCapturer(controller: temporaryCapture, qualification: .init(store: proofStore)), restore: {
            await hotkeyBridge.uninstall()
            try? await hotkeyBridge.install()
        }), proofStore: proofStore)
        let repository = DashboardRepositoryAdapters(store: store, afterPreferencesSave: {
            await shortcutCache.refresh()
            source.reloadSettings()
            await hotkeyBridge.uninstall()
            try? await hotkeyBridge.install()
            if let record = try? await store.preferences() {
                presentation.setPreferenceEnabled(record.snapshot.floatingControlEnabled)
                presentation.setHistoryCapabilityAvailable(record.snapshot.historyEnabled && record.snapshot.retention != .none)
            }
        })
        self.dashboard = DashboardViewModel(statistics: repository, history: repository, dictionary: repository, preferences: repository, shortcut: shortcut, clipboard: clipboard, launchAtLogin: launchAtLogin)
        let testRunner = ProductionEphemeralDictationRunner(audio: audio, helper: runtime.sameRuntimeTranscriber())
        let testIntent = StatefulTestDictationIntent(arbiter: arbiter, runner: testRunner)
        let permissions = MacPermissionStatusIntent()
        self.permissions = permissions
        self.onboarding = OnboardingRouter(dashboard: dashboard, permissions: permissions, microphone: MicrophoneLevelTester(sampler: AVOneFrameMicrophoneSampler()), shortcut: shortcut, testDictation: testIntent, completion: ProductionCompletionIntent(store: store))
        self.presentation = presentation
        self.actions = actions
        self.shortcutCache = shortcutCache
        actions.attach(graph: self)
        pressureObserver.start { [weak self] in await self?.modelMemoryPressure() }
    }
    /// Existing persisted retention/purge contract, retried on a later activation on failure.
    /// Load current preferences each time; this path never saves settings or owns a timer.
    public func applicationDidBecomeActive() async {
        dashboard.refreshLaunchAtLoginStatus()
        guard !shutDown, !retentionRunInFlight else { return }
        retentionRunInFlight = true
        defer { retentionRunInFlight = false }
        guard let record = try? await backingStore.preferences(), !shutDown else { return }
        let retention: KlangschriftPersistence.HistoryRetention = switch record.snapshot.retention {
        case .forever: .forever; case .none: .none
        case .days7: .days7; case .days14: .days14; case .days30: .days30; case .days90: .days90
        }
        if (try? await retentionScheduler.runIfDue(retention: retention, store: backingStore)) == true {
            await dashboard.historyDidChange()
        }
    }
    public func presentationDidPublish() { onboarding.showDashboard(); presentation.activateRail() }
    public func railContext() async -> RailContext {
        var result = RailContext()
        guard let preferences = try? await backingStore.preferences() else { return result }
        let devices = CoreAudioDeviceCatalog().devices()
        result.microphones = [.init(id: "", title: L("Systemmikrofon"))] + devices.map { .init(id: $0.uid, title: $0.displayName) }
        result.microphoneID = preferences.snapshot.selectedInputDeviceUID ?? ""
        result.microphoneAvailable = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized && (result.microphoneID.isEmpty ? !devices.isEmpty : devices.contains { $0.uid == result.microphoneID })
        let cards = await modelPresenter?.cards(language: nil, installedOnly: true) ?? []
        result.models = cards.filter(\.installed).map { .init(id: $0.id, title: $0.title) }
        result.modelID = cards.first(where: \.selected)?.id ?? ""
        result.language = preferences.snapshot.language.rawValue
        if let shortcut = preferences.snapshot.shortcuts.first {
            result.shortcutLabel = switch shortcut.keyCode { case 61: L("Rechte Option (⌥)"); case 63: "Fn"; default: L("Eigene Taste") }
        }
        if preferences.snapshot.historyEnabled, preferences.snapshot.retention != .none,
           let page = try? await backingStore.historyPage(limit: 3) {
            result.transcripts = page.entries.map { .init(id: $0.id, preview: $0.text) }
        }
        return result
    }
    public func selectRail(_ kind: String, id: String) async -> PresentationActionOutcome {
        guard presentation.state.phase == .idle else { return .unavailable }
        do {
            if kind == "model" {
                guard let modelPresenter else { return .unavailable }
                let cards = await modelPresenter.cards(language: nil, installedOnly: true)
                guard cards.contains(where: { $0.id == id && $0.installed }), presentation.state.phase == .idle else { return .unavailable }
                try await modelPresenter.select(modelID: id)
            } else {
                let old = try await backingStore.preferences()
                var next = old.snapshot
                if kind == "language", let language = SettingsLanguage(rawValue: id), ["de", "en"].contains(id) { next.language = language }
                else if kind == "microphone", id.isEmpty || CoreAudioDeviceCatalog().devices().contains(where: { $0.uid == id }) { next.selectedInputDeviceUID = id.isEmpty ? nil : id }
                else { return .unavailable }
                guard presentation.state.phase == .idle else { return .unavailable }
                _ = try await backingStore.savePreferences(next, expectedRevision: old.revision)
                await dashboard.load()
            }
            return .success
        } catch { return .failed }
    }
    public func copyRailTranscript(_ id: UUID) async -> PresentationActionOutcome {
        guard !presentation.contentActionsDisabled else { return .unavailable }
        do {
            let preferences = try await backingStore.preferences()
            guard preferences.snapshot.historyEnabled, preferences.snapshot.retention != .none,
                  let entry = try await backingStore.historyEntry(id: id), !presentation.contentActionsDisabled else { return .unavailable }
            return clipboard.write(entry.text) ? .success : .failed
        } catch { return .failed }
    }
    public func copyNewestTranscript() async -> PresentationActionOutcome {
        do {
            let preferences = try await backingStore.preferences()
            guard preferences.snapshot.historyEnabled, preferences.snapshot.retention != .none,
                  let newest = try await backingStore.historyPage(limit: 1).entries.first else { return .unavailable }
            return clipboard.write(newest.text) ? .success : .failed
        } catch { return .failed }
    }
    public func copyRecoveryDraft() async -> PresentationActionOutcome {
        guard let draft = await recoveryDraft.takeLatest() else { return .unavailable }
        return clipboard.write(draft) ? .success : .failed
    }
    public func latestDraft() async -> AP05LatestDraft? { await recoveryDraft.latestDraft() }
    public func replaceLatestDraft(_ text: String, sessionID: UUID?, revision: UInt64) async -> AP05LatestDraft? { await recoveryDraft.replaceLatestDraft(text, sessionID: sessionID, revision: revision) }
    public func copyLatestDraft(sessionID: UUID?, revision: UInt64, text: String) async -> PresentationActionOutcome {
        guard let draft = await recoveryDraft.latestDraft(), draft.sessionID == sessionID, draft.revision == revision, draft.text == text else { return .unavailable }
        return clipboard.write(text) ? .success : .failed
    }
    public func addSelectedTextAsRecognitionHint() async -> PresentationActionOutcome {
        guard let selected = selectedTextReader.selectedText() else { return .unavailable }
        let outcome = await recognitionHintAction.add(selected)
        if outcome == .success {
            await dashboard.refreshDictionary()
        }
        return outcome
    }
    public func closeRail() async -> PresentationActionOutcome { await dashboard.setFloatingControlEnabled(false) ? .success : .failed }
    /// Explicit post-onboarding/user action. The bridge itself validates the
    /// positive input-monitoring preflight before it can install a tap.
    public func enableHotkeyAfterExplicitAction() async throws {
        await shortcutCache.refresh()
        hotkey.reloadSettings()
        try await hotkeyBridge.install()
    }
    /// The dashboard/onboarding save path calls this only after its encrypted
    /// optimistic save succeeded; a failed save leaves the live shortcut as-is.
    public func reloadHotkeyAfterExplicitSettingsSave() async {
        await shortcutCache.refresh()
        hotkey.reloadSettings()
    }
    /// The only interactive start route. Status checks are read-only; helper
    /// preparation remains deferred to this explicit user action's pipeline.
    public func startIfReady() async {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        switch await runtime.readiness.status() {
        case .shuttingDown, .stopped, .unavailable: return
        case .unprepared, .preparing, .ready: break
        }
        await runtime.coordinator.startManualDictation()
    }
    public func shutdown() async {
        guard !shutDown else { return }; shutDown = true
        pressureObserver.stop()
        await hotkeyBridge.uninstall()
        await modelLifecycle?.invalidateAndDrain()
        await runtime.coordinator.recoverAfterRestart()
        _ = await runtime.readiness.shutdown()
        presentation.tearDown()
    }
    /// Routes menu opening through the SwiftUI window owner. It never builds a
    /// second composition or starts recording as a side effect.
    public func openDashboard() {
        onboarding.showDashboard()
        actions.openDashboard()
    }
    /// The active macOS pressure subscription and cold test source both enter
    /// this graph-owned port; neither learns native runtime details.
    public func modelMemoryPressure() async { await modelLifecycle?.memoryPressure() }
    func attachCompositionQuit(_ value: @escaping @MainActor () async -> Void) { actions.attachQuit(value) }
    func attachDashboardOpen(_ value: @escaping @MainActor () -> Void) { actions.attachDashboardOpen(value) }
}
extension ProductionAppGraph: AppGraphLifecycle {
    public var runtimeHandle: AppRuntime? { runtime }
    public var storeIdentity: ObjectIdentifier { ObjectIdentifier(backingStore) }
    public func recoverBeforeAcceptingInput() async {
        await runtime.coordinator.recoverAfterRestart()
        await applicationDidBecomeActive()
        await loadPersistedShortcutsBeforeAcceptingInput()
    }

    /// Startup-time shortcut load. The configuration cache is otherwise only
    /// refreshed by explicit settings saves, which left a persisted binding
    /// unregistered until the user rebinded it after every relaunch.
    private func loadPersistedShortcutsBeforeAcceptingInput() async {
        await shortcutCache.refresh()
        hotkey.reloadSettings()
        try? await hotkeyBridge.install()
    }
    public var rootSurface: AnyView { AnyView(AP05DashboardShell(router: onboarding, presentation: presentation, modelPresenter: modelPresenter, draftPort: self, permissionIntent: permissions, permissionRecovery: permissionRecovery)) }
    public var menuSurface: AnyView { AnyView(MenuBarPresentationView(controller: presentation)) }
}
extension ProductionAppGraph: AP05LatestDraftPresenting {}

/// Shared candidate transaction used by production completion and the
/// composition harness. A candidate is never published until recovery and
/// persistence both succeed; every failing/stale path shuts it down once.
@MainActor public enum CandidatePublishMachine {
    public static func run(candidate: any AppGraphLifecycle, stillCurrent: @escaping @MainActor () -> Bool, save: @escaping @MainActor () async throws -> Void) async throws {
        do {
            await candidate.recoverBeforeAcceptingInput()
            guard stillCurrent() else { throw CancellationError() }
            try await save()
            guard stillCurrent() else { throw CancellationError() }
        } catch {
            await candidate.shutdown()
            throw error
        }
    }
}

/// The cold-launch counterpart to `CandidatePublishMachine`.  It deliberately
/// knows neither AppFoundation nor any macOS adapter, so the composition
/// harness can exercise the exact production ordering without constructing a
/// Keychain, TCC, audio, or event-tap object.  A candidate is owned locally
/// until `publish` succeeds; every error or stale generation shuts it down
/// exactly once.
@MainActor public enum ResumePublishMachine {
    public static func run<Foundation, Candidate>(
        markerCompleted: @escaping @MainActor () -> Bool,
        refreshPermissions: @escaping @MainActor () async throws -> PermissionSnapshot,
        permissionsAllowed: @escaping @MainActor (PermissionSnapshot) -> Bool,
        bootstrap: @escaping @MainActor () async throws -> Foundation,
        shortcutAllowed: @escaping @MainActor (Foundation) -> Bool,
        assemble: @escaping @MainActor (Foundation) async throws -> Candidate,
        recover: @escaping @MainActor (Candidate) async -> Void,
        publish: @escaping @MainActor (Foundation, Candidate) async throws -> Void,
        shutdown: @escaping @MainActor (Candidate) async -> Void,
        stillCurrent: @escaping @MainActor () -> Bool
    ) async -> Bool {
        // The marker is intentionally the first read.  A false marker must
        // remain entirely cold: no permission/TCC call, foundation, or graph.
        guard markerCompleted(), stillCurrent() else { return false }
        var candidate: Candidate?
        do {
            let snapshot = try await refreshPermissions()
            guard stillCurrent(), permissionsAllowed(snapshot) else { return false }
            let foundation = try await bootstrap()
            guard stillCurrent(), shortcutAllowed(foundation) else { return false }
            let created = try await assemble(foundation)
            candidate = created
            guard stillCurrent() else { await shutdown(created); candidate = nil; return false }
            await recover(created)
            guard stillCurrent() else { await shutdown(created); candidate = nil; return false }
            try await publish(foundation, created)
            candidate = nil
            return true
        } catch {
            if let candidate { await shutdown(candidate) }
            return false
        }
    }
}

/// Resources for the one pre-foundation test run.  The type deliberately has
/// no persistence or insertion capability: a test can only record, ask the
/// local helper once, and then be torn down.
public struct EphemeralTestResources: Sendable {
    public let runner: any EphemeralDictationRunning
    private let drain: @Sendable () async -> Void
    private let terminate: @Sendable () async -> Void
    public init(runner: any EphemeralDictationRunning, drain: @escaping @Sendable () async -> Void, terminate: @escaping @Sendable () async -> Void) {
        self.runner = runner; self.drain = drain; self.terminate = terminate
    }
    public func cancelAndDrain() async {
        await drain()
        await terminate()
    }
}

/// The pre-foundation owner is intentionally narrower than an AppRuntime.  It
/// creates its model/helper configuration only for an explicit test button;
/// therefore onboarding rendering cannot touch Keychain, a store, or Python.
@MainActor public protocol PrefoundationLifecycleOwner: TestDictationIntent {
    func cancelAndDrain() async
    func isIdle() async -> Bool
}

@MainActor public final class PrefoundationEphemeralTestOwner: PrefoundationLifecycleOwner {
    public typealias ConfigurationFactory = @Sendable () throws -> EphemeralRuntimeConfiguration
    public typealias ResourceFactory = @Sendable (EphemeralRuntimeConfiguration, EphemeralDictationArbiter, @escaping @Sendable () async -> Void) async throws -> EphemeralTestResources
    private let configuration: ConfigurationFactory
    private let resources: ResourceFactory
    private let arbiter: EphemeralDictationArbiter
    private var observationGeneration: UInt64 = 0
    private var completedAutomaticToken: UUID?
    private var automaticHandler: (@MainActor @Sendable (TestDictationAutomaticEvent) -> Void)?
    public func setAutomaticHandler(_ handler: @escaping @MainActor @Sendable (TestDictationAutomaticEvent) -> Void) { automaticHandler = handler }
    private var pending: UUID?
    private var cancelled = Set<UUID>()
    private var active: (token: UUID, resources: EphemeralTestResources)?

    public init(arbiter: EphemeralDictationArbiter = .init(), configuration: @escaping ConfigurationFactory, resources: @escaping ResourceFactory) {
        self.arbiter = arbiter; self.configuration = configuration; self.resources = resources
    }
    public convenience init(applicationSupport: URL, snapshot: URL, python: URL, helper: URL, arbiter: EphemeralDictationArbiter = .init()) {
        self.init(arbiter: arbiter, configuration: {
            try EphemeralRuntimeConfigurationFactory.make(applicationSupport: applicationSupport, snapshot: snapshot, python: python, helper: helper)
        }, resources: { configuration, arbiter, terminalCancel in
            let terminal = BindableAudioTerminalRouter()
            let catalog = CoreAudioDeviceCatalog()
            let audio = AudioCoordinatorAdapter(service: ProductionCoordinatorAudioService(audioRoot: configuration.paths.audio, catalog: catalog, terminal: terminal, deviceObserver: CoreAudioDeviceObserver(catalog: catalog)), terminal: terminal, recordingArbiter: arbiter)
            guard await terminal.bind({ _ in await terminalCancel() }) else { throw AppFoundationFailure.invalidConfiguration }
            let runtime = try AppRuntimeFactory.makeEphemeral(launch: configuration.launch, runtimeDiagnostics: ProductionDiagnostics())
            let runner = ProductionEphemeralDictationRunner(audio: audio, helper: runtime)
            guard await terminal.bindCompletion({ session, reason in await runner.finishAutomatically(session: session, reason: reason) }) else { throw AppFoundationFailure.invalidConfiguration }
            return EphemeralTestResources(runner: runner, drain: {
                await runner.cancel()
            }, terminate: {
                _ = await runtime.shutdown()
            })
        })
    }
    public func start(language: OnboardingLanguage) async throws {
        guard pending == nil, active == nil else { throw CancellationError() }
        observationGeneration &+= 1
        let observation = observationGeneration
        completedAutomaticToken = nil
        let token = UUID(); pending = token
        let configuration: EphemeralRuntimeConfiguration
        do { configuration = try self.configuration() }
        catch { pending = nil; throw error }
        let resource: EphemeralTestResources
        do {
            resource = try await resources(configuration, arbiter, { [weak self] in await self?.cancelAndDrain() })
        } catch { pending = nil; cancelled.remove(token); throw error }
        guard pending == token, !cancelled.contains(token) else { await resource.cancelAndDrain(); pending = nil; cancelled.remove(token); throw CancellationError() }
        pending = nil; active = (token, resource)
        do {
            if let observable = resource.runner as? any EphemeralAutomaticObserving {
                await observable.setAutomaticHandler { [weak self] session, reason, result in await self?.receiveAutomatic(token: token, observation: observation, session: session, reason: reason, result: result) }
            }
            guard active?.token == token else { throw CancellationError() }
            try await resource.runner.beginEphemeral(language: language)
            guard active?.token == token || completedAutomaticToken == token else { throw CancellationError() }
        } catch {
            _ = await finish(token)
            throw error
        }
    }
    private func receiveAutomatic(token: UUID, observation: UInt64, session: UUID, reason: AudioCaptureCompletionReason, result: Result<String, Error>?) async {
        guard observationGeneration == observation, active?.token == token else { return }
        let uiReason: TestDictationAutomaticReason = switch reason { case .maximumDuration: .maximumDuration; case .callbackLoss: .callbackLoss; case .interrupted, .interruptedCopied, .lockedCopied: .interrupted }
        if let result {
            let preview = (try? result.get()).flatMap(TestDictationResult.init(preview:))
            completedAutomaticToken = token
            _ = await finish(token)
            guard observationGeneration == observation else { return }
            automaticHandler?(.finished(session: session, reason: uiReason, result: preview))
        } else { automaticHandler?(.processing(session: session, reason: uiReason)) }
    }
    public func stopAndTranscribe() async throws -> TestDictationResult {
        guard let current = active else { throw CancellationError() }
        do {
            let preview = try await current.resources.runner.finishEphemeral()
            guard await finish(current.token) || completedAutomaticToken == current.token else { throw CancellationError() }
            guard let result = TestDictationResult(preview: preview) else { throw CancellationError() }
            return result
        } catch {
            _ = await finish(current.token)
            throw error
        }
    }
    /// Both onboarding navigation and terminal P3 notifications use this
    /// method. It releases all ephemeral state before completion can open the
    /// encrypted foundation.
    public func cancelAndDrain() async {
        observationGeneration &+= 1
        if let active { self.active = nil; await active.resources.cancelAndDrain() }
        else if let pending { cancelled.insert(pending) }
    }
    public func cancel() async { await cancelAndDrain() }
    public func isIdle() async -> Bool {
        guard pending == nil, active == nil else { return false }
        return !(await arbiter.isBusy())
    }
    private func finish(_ token: UUID) async -> Bool {
        guard let active, active.token == token else { return false }
        self.active = nil
        await active.resources.cancelAndDrain()
        return true
    }
}

/// Installs a real, temporary P2 tap only while the user is recording a
/// shortcut.  The capture controller is supplied by AppComposition and shared
/// with the later live hotkey source, so two taps cannot own a capture token.
@MainActor private final class CompositionShortcutCapturer: TemporaryShortcutCapturing {
    private let source: ProductionHotkeyEventSource
    private let base: TemporaryCGEventShortcutCapturer
    private let restore: @MainActor @Sendable () async -> Void
    private var active = false
    init(source: ProductionHotkeyEventSource, base: TemporaryCGEventShortcutCapturer, restore: @escaping @MainActor @Sendable () async -> Void = {}) { self.source = source; self.base = base; self.restore = restore }
    func install(generation: UInt64, receive: @escaping @MainActor (ShortcutCapture) -> Void, terminate: @escaping @MainActor () -> Void) throws {
        try source.install()
        do {
            active = true
            try base.install(generation: generation, receive: { [weak self] value in self?.uninstall(); receive(value) }, terminate: { [weak self] in self?.uninstall(); terminate() })
        } catch { active = false; source.uninstall(); Task { await restore() }; throw error }
    }
    func uninstall() { guard active else { return }; active = false; base.uninstall(); source.uninstall(); Task { await restore() } }
}

/// Builds the concrete local graph from one encrypted store. It is deliberately
/// cold: this method creates adapters only; no tap is installed and neither
/// recording nor helper preparation starts here.
public enum ProductionAssemblyFactory {
    public struct RuntimeParts: Sendable { public let runtime: AppRuntime; public let audio: AudioCoordinatorAdapter; public let arbiter: EphemeralDictationArbiter; public let recoveryDraft: ProductionRecoveryPresenter }
    public static func makeParts(foundation: AppFoundation, recordingArbiter: EphemeralDictationArbiter = .init(), presentation: any DictationUIState = RuntimePresentationBridge(sink: { _ in }), historyDidPersist: @escaping @Sendable (DictationSessionID) async -> Void = { _ in }, initialPreferences: PreferencesSnapshot? = nil, modelTranscriber: (any DesktopModelTranscribing)? = nil, levelHandler: (@Sendable (Double) -> Void)? = nil) async throws -> RuntimeParts {
        let terminal = BindableAudioTerminalRouter()
        let arbiter = recordingArbiter
        let catalog = CoreAudioDeviceCatalog()
        let capture = AVAudioCaptureAdapter(preflight: ProductionMicrophonePreflight())
        capture.setLevelHandler(levelHandler)
        let audio = AudioCoordinatorAdapter(service: ProductionCoordinatorAudioService(audioRoot: foundation.paths.audio, selectedDeviceUID: initialPreferences?.selectedInputDeviceUID, selectedDeviceUIDProvider: {
            guard let snapshot = try? await foundation.store.preferences().snapshot else { return .unavailable }
            return .value(snapshot.selectedInputDeviceUID)
        }, capture: capture, catalog: catalog, terminal: terminal, deviceObserver: CoreAudioDeviceObserver(catalog: catalog)), terminal: terminal, recordingArbiter: arbiter)
        let focus = MacOSFocusTargeting()
        let mutation = MacOSAXMutation(focus: focus)
        // Automatic insertion stays bound to one captured AX element. Rich
        // fields use the service's selection-witnessed paste path; unavailable
        // or unsafe fields enter the explicit local recovery flow instead.
        let insertionPolicy = InsertionPolicy()
        let recoveryDraft = ProductionRecoveryPresenter()
        let insertion = InsertionCoordinatorAdapter(service: TextInsertionService(focus: focus, ax: mutation, pasteboard: MacOSPasteboardGateway(), poster: MacOSPasteEventPoster(), verifier: mutation, clock: ProductionCompositionClock(), sleeper: ProductionSleeper(), recovery: recoveryDraft, diagnostics: ProductionDiagnostics(), policy: insertionPolicy))
        let decorate: (@Sendable (any LocalTranscribing) -> any LocalTranscribing)?
        if let desktop = modelTranscriber {
            let store = foundation.store
            decorate = { legacy in
                SelectedDesktopDictationTranscriber(desktop: desktop, legacy: legacy, recognitionHints: {
                    (try? await store.activeRecognitionHints(limit: RecognitionHintPrompt.maximumEntries)) ?? []
                })
            }
        } else { decorate = nil }
        let runtime = try AppRuntimeFactory.make(.init(launch: foundation.coldRuntime.launch, projection: foundation.coldRuntime.projection, audio: audio, dictionary: RepositoryDictionaryAdapter(store: foundation.store), history: RepositoryHistoryAdapter(store: foundation.store, afterPersist: historyDidPersist), statistics: RepositoryStatisticsAdapter(store: foundation.store, dayIdentifier: LocalGregorianDayIdentifierProvider()), settings: RepositorySettingsAdapter(store: foundation.store), insertion: insertion, draft: recoveryDraft, ui: presentation, diagnostics: ProductionDiagnostics(), clock: ProductionCompositionClock(), runtimeDiagnostics: ProductionDiagnostics(), decorateTranscriber: decorate))
        await runtime.coordinator.bindInterruptionCopy(ProductionInterruptedTextCopier())
        guard await terminal.bind({ session in await runtime.coordinator.cancelForAudioTerminal(session: session) }) else { throw AppFoundationFailure.invalidConfiguration }
        guard await terminal.bindCompletion({ session, reason in
            await runtime.coordinator.finishForAudioTerminal(session: session, reason: reason)
        }) else { throw AppFoundationFailure.invalidConfiguration }
        return .init(runtime: runtime, audio: audio, arbiter: arbiter, recoveryDraft: recoveryDraft)
    }
    public static func make(foundation: AppFoundation, presentation: any DictationUIState = RuntimePresentationBridge(sink: { _ in })) async throws -> AppRuntime { try await makeParts(foundation: foundation, presentation: presentation).runtime }
    @MainActor public static func makeGraph(foundation: AppFoundation, recordingArbiter: EphemeralDictationArbiter = .init(), modelPresenter: (any AP05ModelPresenting)? = nil, modelLifecycle: (any AP05DesktopModelLifecycleControlling)? = nil) async throws -> ProductionAppGraph {
        let actions = GraphPresentationActions()
        let initialPreferences = (try? await foundation.store.preferences())?.snapshot
        // A temporarily unavailable preference record must not make the rail
        // disappear after an active dictation. The persisted value still wins
        // whenever it was loaded successfully.
        let initialFloatingEnabled = initialPreferences?.floatingControlEnabled ?? true
        let initialHistoryCapability = initialPreferences.map { $0.historyEnabled && $0.retention != .none } ?? false
        let controller = DictationPresentationController(actions: actions, checker: GraphPresentationPreflight(), clock: SystemPresentationClock(), panelHost: AppKitFloatingPanelHost(), floatingPreferenceEnabled: initialFloatingEnabled, historyCapabilityAvailable: initialHistoryCapability)
        let sink = AttachablePresentationSink()
        guard sink.attach(controller) else { throw AppFoundationFailure.invalidConfiguration }
        let parts = try await makeParts(foundation: foundation, recordingArbiter: recordingArbiter, presentation: sink, historyDidPersist: { session in
            await sink.historyDidPersist(session: session)
        }, initialPreferences: initialPreferences, modelTranscriber: modelPresenter as? any DesktopModelTranscribing, levelHandler: { [weak controller] value in
            Task { @MainActor in controller?.updateMicrophoneLevel(value) }
        })
        actions.attach(runtime: parts.runtime)
        let graph = ProductionAppGraph(runtime: parts.runtime, audio: parts.audio, arbiter: parts.arbiter, store: foundation.store, presentation: controller, actions: actions, modelPresenter: modelPresenter, modelLifecycle: modelLifecycle, recoveryDraft: parts.recoveryDraft)
        await parts.runtime.coordinator.bindHotkeyNeutralizer { [weak source = graph.hotkey] _ in source?.neutralizeAfterAudioCompletion() }
        guard sink.attachStatisticsRefresh(graph.dashboard) else { throw AppFoundationFailure.invalidConfiguration }
        guard sink.attachHistoryRefresh(graph.dashboard) else { throw AppFoundationFailure.invalidConfiguration }
        return graph
    }
}

/// The only owner allowed to turn a validated foundation into a running app.
/// Its initializer is deliberately cold: it does not touch Keychain, TCC,
/// AVFoundation, AX, pasteboard, event taps, Python or the helper process.
@MainActor public final class AppComposition: ObservableObject {
    public enum ClosedCode: String, Equatable, Sendable { case startupUnavailable, unavailableDuringShutdown }
    public enum State: Equatable { case cold, starting, needsOnboarding, ready, unavailable(ClosedCode), shuttingDown, stopped }
    @Published public private(set) var state: State = .needsOnboarding
    @Published public private(set) var safeErrorCode: String?
    public private(set) var foundation: AppFoundation?
    public private(set) var runtime: AppRuntime?
    public private(set) var graph: (any AppGraphLifecycle)?
    public private(set) var store: EncryptedSQLiteStore?
    private let bootstrap: @Sendable () async throws -> AppFoundation
    private let bootstrapWithKeyAccess: (@Sendable (ExistingDatabaseKeyAccess) async throws -> AppFoundation)?
    private let assemble: @MainActor @Sendable (AppFoundation) async throws -> any AppGraphLifecycle
    private let testingGraph: (@MainActor @Sendable () async throws -> any AppGraphLifecycle)?
    private let prefoundationRouterFactory: (@MainActor @Sendable (any CompletionIntent) -> OnboardingRouter)?
    private let prefoundationTestFactory: @MainActor @Sendable (EphemeralDictationArbiter) -> any PrefoundationLifecycleOwner
    private let completionSave: @MainActor @Sendable (EncryptedSQLiteStore, CompletionDraft) async throws -> Void
    private var applicationTerminationRequest: (@MainActor () -> Void)?
    private weak var dashboardWindowOpening: (any DashboardWindowOpening)?
    private let resumeMarker: any CompletionMarker
    private let resumePermissions: any PermissionStatusIntent
    // Join concurrent marker resumes so two root-surface tasks cannot race
    // into two foundations.  Explicit onboarding boot invalidates this task
    // through `generation`; it never clears resources owned by a newer boot.
    private var resumeTask: Task<Bool, Never>?
    private var generation: UInt64 = 0
    private var shutdownGeneration: UInt64?
    private let prefoundationArbiter: EphemeralDictationArbiter
    private lazy var temporaryCaptureController = EventTapTemporaryCaptureController()
    private lazy var prefoundationInputSource = ProductionHotkeyEventSource(temporaryCapture: temporaryCaptureController)
    private let prefoundationShortcutLifecycle: (any PrefoundationShortcutCaptureLifecycle)?
    private var materializedPrefoundationShortcut: (any PrefoundationShortcutCaptureLifecycle)?
    private var materializedPrefoundationTest: (any PrefoundationLifecycleOwner)?
    private func prefoundationTestOwner() -> any PrefoundationLifecycleOwner {
        if let materializedPrefoundationTest { return materializedPrefoundationTest }
        let value = prefoundationTestFactory(prefoundationArbiter); materializedPrefoundationTest = value; return value
    }
    private lazy var prefoundationCompletion = PrefoundationCompletionBridge(owner: self)
    /// One passive status reader is shared by startup, scene activation and the
    /// ready dashboard; it never requests macOS access on its own.
    public lazy var permissionRecovery = PermissionRecoveryViewModel(permissions: resumePermissions)
    public lazy var prefoundationOnboarding: OnboardingRouter = {
        if let prefoundationRouterFactory {
            // Keep the injected test owner under composition lifecycle control
            // even when a harness supplies its own router presentation.
            _ = prefoundationTestOwner()
            return prefoundationRouterFactory(prefoundationCompletion)
        }
        let proofStore = UserDefaultsFnGlobeCaptureProofStore(defaults: .standard)
        let base = TemporaryCGEventShortcutCapturer(controller: temporaryCaptureController, qualification: .init(store: proofStore))
        let shortcut = ProductionShortcutSetupIntent(capturer: CompositionShortcutCapturer(source: prefoundationInputSource, base: base), proofStore: proofStore)
        materializedPrefoundationShortcut = shortcut
        return OnboardingRouter(permissions: resumePermissions, microphone: MicrophoneLevelTester(sampler: AVOneFrameMicrophoneSampler()), shortcut: shortcut, testDictation: prefoundationTestOwner(), completion: prefoundationCompletion)
    }()

    public init(bootstrap: @escaping @Sendable () async throws -> AppFoundation, bootstrapWithKeyAccess: (@Sendable (ExistingDatabaseKeyAccess) async throws -> AppFoundation)? = nil, assemble: @escaping @MainActor @Sendable (AppFoundation) async throws -> any AppGraphLifecycle, prefoundationRouter: (@MainActor @Sendable (any CompletionIntent) -> OnboardingRouter)? = nil, prefoundationTest: (@MainActor @Sendable (EphemeralDictationArbiter) -> any PrefoundationLifecycleOwner)? = nil, prefoundationShortcutLifecycle: (any PrefoundationShortcutCaptureLifecycle)? = nil, recordingArbiter: EphemeralDictationArbiter = .init(), completionSave: @escaping @MainActor @Sendable (EncryptedSQLiteStore, CompletionDraft) async throws -> Void = { store, draft in try await ProductionCompletionIntent(store: store).save(draft) }, resumeMarker: any CompletionMarker = UserDefaultsCompletionMarker(), resumePermissions: any PermissionStatusIntent = MacPermissionStatusIntent()) {
        self.bootstrap = bootstrap; self.bootstrapWithKeyAccess = bootstrapWithKeyAccess; self.assemble = assemble; self.testingGraph = nil; self.prefoundationRouterFactory = prefoundationRouter; self.prefoundationTestFactory = prefoundationTest ?? Self.defaultPrefoundationTest; self.prefoundationShortcutLifecycle = prefoundationShortcutLifecycle; self.prefoundationArbiter = recordingArbiter; self.completionSave = completionSave; self.resumeMarker = resumeMarker; self.resumePermissions = resumePermissions
    }
    /// Harness-only cold seam. It cannot be selected by the production factory.
    public init(testingGraph: @escaping @MainActor @Sendable () async throws -> any AppGraphLifecycle, resumeMarker: any CompletionMarker = UserDefaultsCompletionMarker(), resumePermissions: any PermissionStatusIntent = FakePermissionStatusIntent()) {
        self.bootstrap = { throw AppFoundationFailure.invalidConfiguration }
        self.bootstrapWithKeyAccess = nil
        self.assemble = { _ in throw AppFoundationFailure.invalidConfiguration }
        self.testingGraph = testingGraph
        self.prefoundationRouterFactory = nil
        self.prefoundationTestFactory = Self.defaultPrefoundationTest
        self.prefoundationShortcutLifecycle = nil
        self.prefoundationArbiter = .init()
        self.completionSave = { store, draft in try await ProductionCompletionIntent(store: store).save(draft) }
        self.resumeMarker = resumeMarker
        self.resumePermissions = resumePermissions
    }

    /// Opens the workspace without granting or requesting global permissions.
    /// An optional setup probe must release its audio lease before publication.
    public func openManualWorkspace() async -> Bool {
        (materializedPrefoundationShortcut ?? prefoundationShortcutLifecycle)?.cancelActiveCapture()
        if let test = materializedPrefoundationTest {
            await test.cancelAndDrain()
            guard await test.isIdle() else { return false }
        }
        return await bootAfterExplicitOnboardingAction()
    }

    /// May only be called from an explicit eligible UI action. Concurrent or
    /// stale requests are ignored; no partial runtime is ever published.
    public func bootAfterExplicitOnboardingAction(existingKeyAccess: ExistingDatabaseKeyAccess = .noninteractiveProbe) async -> Bool {
        // An explicit completion/boot supersedes a passive marker-resume even
        // while that resume is awaiting its read-only permission refresh.
        // Other startup work remains non-reentrant.
        let supersedesResume = resumeTask != nil && state == .starting
        guard state == .cold || state == .needsOnboarding || supersedesResume else { return state == .ready }
        invalidateActiveResumeIfNeeded()
        generation &+= 1; let request = generation; state = .starting; safeErrorCode = nil
        do {
            let foundation: AppFoundation?
            if testingGraph != nil { foundation = nil }
            else if let bootstrapWithKeyAccess { foundation = try await bootstrapWithKeyAccess(existingKeyAccess) }
            else { foundation = try await bootstrap() }
            guard request == generation, shutdownGeneration == nil else { return false }
            let graph: any AppGraphLifecycle
            if let testingGraph { graph = try await testingGraph() }
            else { graph = try await assemble(foundation!) }
            guard request == generation, shutdownGeneration == nil else { await graph.shutdown(); return false }
            await graph.recoverBeforeAcceptingInput()
            guard request == generation, shutdownGeneration == nil else { await graph.shutdown(); return false }
            if let production = graph as? ProductionAppGraph { production.permissionRecovery = permissionRecovery; production.attachCompositionQuit { [weak self] in await self?.requestApplicationTermination() }; production.attachDashboardOpen { [weak self] in self?.dashboardWindowOpening?.openDashboardWindow() } }
            self.foundation = foundation; self.store = foundation?.store; self.runtime = graph.runtimeHandle; self.graph = graph; state = .ready; graph.presentationDidPublish()
            return true
        } catch {
            guard request == generation else { return false }
            // Error values may contain paths or platform details.  The UI only
            // receives this stable non-content-bearing code.
            safeErrorCode = Self.startupCode(error); state = .unavailable(.startupUnavailable)
            return false
        }
    }
    private static func startupCode(_ error: Error) -> String {
        if error is LegacyMLXImportEntryError { return "legacy_import_invalid" }
        switch error as? AppFoundationFailure {
        case .keychainLocked: return "keychain_locked"
        case .keychainDenied: return "keychain_denied"
        case .keychainCancelled: return "keychain_cancelled"
        case .missingKey: return "keychain_missing"
        case .invalidKey: return "keychain_invalid"
        default: return "startup_unavailable"
        }
    }
    public var startupFailureMessage: String {
        switch safeErrorCode {
        case "keychain_locked": return L("Der Schlüsselbund ist gesperrt. Gib den Zugriff frei, um deine vorhandenen Daten zu öffnen.")
        case "keychain_denied", "keychain_cancelled": return L("Der Zugriff auf den vorhandenen Datenbankschlüssel wurde nicht freigegeben. Du kannst es erneut versuchen.")
        case "keychain_missing", "keychain_invalid": return L("Der Schlüssel für deine vorhandenen Daten ist nicht verfügbar. Deine Daten wurden nicht verändert.")
        default: return L("Die lokale Einrichtung konnte nicht vorbereitet werden.")
        }
    }
    public var canRequestExistingKeyAccess: Bool {
        bootstrapWithKeyAccess != nil && ["keychain_locked", "keychain_denied", "keychain_cancelled"].contains(safeErrorCode ?? "")
    }
    /// Only the visible retry button may request interactive existing-key access.
    public func retryExistingKeyAccess() async -> Bool {
        guard case .unavailable = state, canRequestExistingKeyAccess else { return false }
        state = .needsOnboarding
        return await bootAfterExplicitOnboardingAction(existingKeyAccess: .explicitUserAccess)
    }
    /// Called only by the completion intent after the existing onboarding VM
    /// validated every permission, shortcut, microphone and test requirement.
    fileprivate func completeOnboarding(_ draft: CompletionDraft) async throws {
        guard state == .needsOnboarding || state == .cold else { throw CancellationError() }
        // A pre-foundation preview is never retained past setup.  Drain before
        // any Keychain/store operation and fail closed if a live/test lease
        // remains, rather than creating a second recording owner.
        let test = prefoundationTestOwner(); await test.cancelAndDrain()
        guard await test.isIdle() else { throw CancellationError() }
        prefoundationOnboarding.clearEphemeralPreview()
        generation &+= 1; let request = generation; state = .starting
        var candidate: (any AppGraphLifecycle)?
        do {
            let foundation = try await bootstrap()
            guard request == generation, shutdownGeneration == nil else { throw CancellationError() }
            let graph = try await assemble(foundation); candidate = graph
            do { try await CandidatePublishMachine.run(candidate: graph, stillCurrent: { request == self.generation && self.shutdownGeneration == nil }, save: { try await self.completionSave(foundation.store, draft) }) }
            catch { candidate = nil; throw error }
            if let production = graph as? ProductionAppGraph { production.permissionRecovery = permissionRecovery; production.attachCompositionQuit { [weak self] in await self?.requestApplicationTermination() }; production.attachDashboardOpen { [weak self] in self?.dashboardWindowOpening?.openDashboardWindow() } }
            self.foundation = foundation; self.store = foundation.store; self.runtime = graph.runtimeHandle; self.graph = graph; state = .ready; graph.presentationDidPublish()
            candidate = nil
        } catch {
            if let candidate { await candidate.shutdown() }
            graph = nil; runtime = nil; store = nil; foundation = nil; state = .needsOnboarding
            throw error
        }
    }

    /// Ordered, idempotent exit. Recovery is first so no incomplete history is
    /// left as successful, then the helper is reaped, then references release.
    public func quit() async {
        guard shutdownGeneration == nil else { return }
        shutdownGeneration = generation; generation &+= 1; state = .shuttingDown
        (materializedPrefoundationShortcut ?? prefoundationShortcutLifecycle)?.cancelActiveCapture()
        if let test = materializedPrefoundationTest { await test.cancelAndDrain() }
        if let graph { await graph.shutdown() }
        else if let runtime { await runtime.coordinator.recoverAfterRestart(); _ = await runtime.readiness.shutdown() }
        self.graph = nil; self.runtime = nil; self.store = nil; self.foundation = nil
        state = .stopped
    }
    /// Installed by the executable delegate.  The fallback keeps library and
    /// harness callers deterministic without ever invoking AppKit.
    public func attachApplicationTerminationRequest(_ request: @escaping @MainActor () -> Void) {
        applicationTerminationRequest = request
    }
    public func attachDashboardWindowOpening(_ opening: any DashboardWindowOpening) {
        dashboardWindowOpening = opening
    }
    public func applicationDidBecomeActive() async {
        await permissionRecovery.applicationDidBecomeActive()
        await (graph as? ProductionAppGraph)?.applicationDidBecomeActive()
    }

    /// A marker never supplies preferences or a demo surface. Only a positive
    /// marker performs a fresh read-only permission snapshot, followed by the
    /// normal validated bootstrap/assembly transaction. Failure leaves the
    /// marker intact and the locked onboarding surface in place.
    public func resumeFromCompletedMarkerIfNeeded() async -> Bool {
        if let resumeTask { return await resumeTask.value }
        guard state == .needsOnboarding || state == .cold else { return false }
        generation &+= 1
        let request = generation
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            var recoverySnapshot: PermissionSnapshot?
            let result = await ResumePublishMachine.run(
                markerCompleted: { self.resumeMarker.completed() },
                refreshPermissions: {
                    // No visible intermediate ready state exists: this is the
                    // first transition and only follows a positive marker.
                    self.state = .starting
                    return try await self.resumePermissions.refresh()
                },
                permissionsAllowed: { snapshot in
                    // Global shortcuts and insertion remain optional for the
                    // manual dictate-and-copy route. Microphone is the only
                    // startup prerequisite for a recording-capable workspace.
                    let allowed = snapshot[.microphone].authorization == .granted
                    if !allowed { recoverySnapshot = snapshot }
                    return allowed
                },
                bootstrap: { self.testingGraph == nil ? try await self.bootstrap() : nil },
                shortcutAllowed: { foundation in foundation?.preferences.snapshot.shortcuts.contains { $0.fnGlobeProfile != .globeQualified } ?? true },
                assemble: { foundation in
                    if let testingGraph = self.testingGraph { return try await testingGraph() }
                    return try await self.assemble(foundation!)
                },
                recover: { graph in await graph.recoverBeforeAcceptingInput() },
                publish: { foundation, graph in
                    guard request == self.generation, self.shutdownGeneration == nil else { throw CancellationError() }
                    if let production = graph as? ProductionAppGraph {
                        production.permissionRecovery = self.permissionRecovery
                        production.attachCompositionQuit { [weak self] in await self?.requestApplicationTermination() }
                        production.attachDashboardOpen { [weak self] in self?.dashboardWindowOpening?.openDashboardWindow() }
                    }
                    self.foundation = foundation; self.store = foundation?.store; self.runtime = graph.runtimeHandle; self.graph = graph; self.state = .ready; graph.presentationDidPublish()
                },
                shutdown: { graph in await graph.shutdown() },
                stillCurrent: { request == self.generation && self.shutdownGeneration == nil }
            )
            // A stale resume is forbidden from resetting a newer explicit
            // boot/complete state or releasing its published resources.
            if !result, request == self.generation, self.shutdownGeneration == nil {
                self.state = .needsOnboarding
                if let recoverySnapshot {
                    self.prefoundationOnboarding.onboarding.configurePermissionRecovery(snapshot: recoverySnapshot) { [weak self] in
                        guard let self else { return false }
                        return await self.resumeFromCompletedMarkerIfNeeded()
                    }
                }
            }
            return result
        }
        resumeTask = task
        let result = await task.value
        resumeTask = nil
        return result
    }
    private func invalidateActiveResumeIfNeeded() {
        guard resumeTask != nil else { return }
        generation &+= 1
        resumeTask?.cancel()
    }
    private func requestApplicationTermination() async {
        if let applicationTerminationRequest { applicationTerminationRequest() }
        else { await quit() }
    }
    private static func defaultPrefoundationTest(_ arbiter: EphemeralDictationArbiter) -> PrefoundationEphemeralTestOwner {
        let applicationSupport = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let pins = ProductionRuntimeLocations.legacyMLXPins(applicationSupport: applicationSupport, profile: .whisperLargeV3)
        return productionPrefoundationTest(applicationSupport: applicationSupport, snapshot: pins.allowedSnapshot, python: nil, helper: nil, pins: pins, arbiter: arbiter)
    }
    static func productionPrefoundationTest(applicationSupport: URL, snapshot: URL, python: URL?, helper: URL?, pins: LocalModelPins, arbiter: EphemeralDictationArbiter) -> PrefoundationEphemeralTestOwner {
        PrefoundationEphemeralTestOwner(arbiter: arbiter, configuration: {
            let bundledPython = try python ?? ProductionRuntimeLocations.bundledPython()
            let imports: URL?
            if python == nil { imports = try ProductionRuntimeLocations.bundledPythonImportRoot() }
            else { imports = nil }
            return try EphemeralRuntimeConfigurationFactory.make(applicationSupport: applicationSupport, snapshot: snapshot, python: bundledPython, helper: try helper ?? ProductionRuntimeLocations.bundledHelper(), pins: pins, isolatedImportRoot: imports)
        }, resources: { configuration, arbiter, terminalCancel in
            let terminal = BindableAudioTerminalRouter()
            let catalog = CoreAudioDeviceCatalog()
            let audio = AudioCoordinatorAdapter(service: ProductionCoordinatorAudioService(audioRoot: configuration.paths.audio, catalog: catalog, terminal: terminal, deviceObserver: CoreAudioDeviceObserver(catalog: catalog)), terminal: terminal, recordingArbiter: arbiter)
            guard await terminal.bind({ _ in await terminalCancel() }) else { throw AppFoundationFailure.invalidConfiguration }
            let runtime = try AppRuntimeFactory.makeEphemeral(launch: configuration.launch, runtimeDiagnostics: ProductionDiagnostics())
            let runner = ProductionEphemeralDictationRunner(audio: audio, helper: runtime)
            guard await terminal.bindCompletion({ session, reason in await runner.finishAutomatically(session: session, reason: reason) }) else { throw AppFoundationFailure.invalidConfiguration }
            return EphemeralTestResources(runner: runner, drain: { await runner.cancel() }, terminate: { _ = await runtime.shutdown() })
        })
    }
}

/// Production defaults are values only. Calling `make()` remains cold and is
/// safe for SwiftUI construction and preview discovery.
@MainActor public enum ProductionCompositionFactory {
    public static func make(applicationSupport: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true), snapshot: URL? = nil, python: URL? = nil, helper: URL? = nil, legacyImport: LegacyMLXImportRequest? = nil, startupFailure: LegacyMLXImportEntryError? = nil, recordingArbiter: EphemeralDictationArbiter = .init(), assemble: @escaping @MainActor @Sendable (AppFoundation) async throws -> any AppGraphLifecycle) -> AppComposition {
        let primaryPins = ProductionRuntimeLocations.legacyMLXPins(applicationSupport: applicationSupport, profile: .whisperLargeV3)
        let turboPins = ProductionRuntimeLocations.legacyMLXPins(applicationSupport: applicationSupport, profile: .whisperLargeV3Turbo)
        let resolvedSnapshot = snapshot ?? primaryPins.allowedSnapshot
        let pins: [LocalModelProfile: LocalModelPins] = [.whisperLargeV3: primaryPins, .whisperLargeV3Turbo: turboPins]
        let bootstrapOperation: @Sendable (ExistingDatabaseKeyAccess) async throws -> AppFoundation = { access in
            if let startupFailure { throw startupFailure }
            let bundledPython = try python ?? ProductionRuntimeLocations.bundledPython()
            let imports: URL?
            if python == nil { imports = try ProductionRuntimeLocations.bundledPythonImportRoot() }
            else { imports = nil }
            return try await AppFoundationComposition.bootstrap(applicationSupport: applicationSupport, keyProvider: KeychainDatabaseKeyProvider(), snapshot: resolvedSnapshot, python: bundledPython, helper: try helper ?? ProductionRuntimeLocations.bundledHelper(), pins: primaryPins, modelPinsOverride: pins, isolatedImportRoot: imports, legacyImport: legacyImport, existingKeyAccess: access)
        }
        return AppComposition(bootstrap: { try await bootstrapOperation(.noninteractiveProbe) }, bootstrapWithKeyAccess: bootstrapOperation, assemble: assemble, prefoundationTest: { arbiter in
            AppComposition.productionPrefoundationTest(applicationSupport: applicationSupport, snapshot: resolvedSnapshot, python: python, helper: helper, pins: primaryPins, arbiter: arbiter)
        }, recordingArbiter: recordingArbiter)
    }
}

/// Production UI never uses the demo dashboard. Until the encrypted store is
/// available it stays visibly locked instead of inventing transcript content.
public struct ProductionRootView: View {
    @ObservedObject private var composition: AppComposition
    @State private var showsOptionalSetup = false
    @Environment(\.scenePhase) private var scenePhase
    public init(composition: AppComposition) { self.composition = composition }
    public var body: some View {
        PermissionRecoveryHost(recovery: composition.permissionRecovery) {
            Group {
            switch composition.state {
            case .cold, .needsOnboarding:
                if showsOptionalSetup {
                    StudioStartupSetupView(title: L("Einrichtung")) {
                        Button(L("Klangschrift öffnen")) { Task { _ = await composition.openManualWorkspace() } }
                            .buttonStyle(StudioProminentButtonStyle())
                    } content: {
                        OnboardingRouterView(router: composition.prefoundationOnboarding)
                    }
                } else {
                    ProductionStateCard(title: "Klangschrift", message: L("Diktieren und kopieren. Alles lokal auf diesem Mac.")) {
                        Button(L("Klangschrift öffnen")) { Task { _ = await composition.openManualWorkspace() } }
                            .buttonStyle(StudioProminentButtonStyle())
                        Button(L("Optionale Einrichtung")) { showsOptionalSetup = true }
                            .buttonStyle(StudioProminentButtonStyle())
                        Text(L("Mikrofonzugriff wird für Aufnahmen benötigt. Globale Kurzbefehle und Einfügen sind optional."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            case .starting:
                ProductionStateCard(title: "Klangschrift", message: L("Klangschrift wird gestartet …"), isStarting: true)
            case .ready:
                if let graph = composition.graph { graph.rootSurface }
                else { ProductionStateCard(title: L("Einrichtung nicht verfügbar"), message: L("Die lokale Einrichtung konnte nicht geladen werden.")) }
            case .unavailable:
                ProductionStateCard(title: L("Start nicht möglich"), message: composition.startupFailureMessage) {
                    if composition.canRequestExistingKeyAccess {
                        Button(L("Schlüsselbundzugriff freigeben")) { Task { _ = await composition.retryExistingKeyAccess() } }
                            .buttonStyle(StudioProminentButtonStyle())
                    }
                }
            case .shuttingDown, .stopped:
                ProductionStateCard(title: L("Klangschrift beendet"))
            }
            }
        }
        .klangschriftTheme()
        .task {
            await composition.permissionRecovery.startupRefresh()
            _ = await composition.resumeFromCompletedMarkerIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await composition.applicationDidBecomeActive() }
        }
    }
}

/// `AppComposition` and the recovery view model publish independently. This
/// host observes the latter directly, so a passive refresh can present or
/// close its sheet even when the composition state itself is unchanged.
private struct PermissionRecoveryHost<Content: View>: View {
    @ObservedObject var recovery: PermissionRecoveryViewModel
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .sheet(isPresented: $recovery.isPresented, onDismiss: { recovery.dismiss() }) {
                PermissionRecoveryDialog(model: recovery)
            }
    }
}

private struct ProductionStateCard<Actions: View>: View {
    let title: String
    let message: String?
    let isStarting: Bool
    let actions: Actions
    init(title: String, message: String? = nil, isStarting: Bool = false, @ViewBuilder actions: () -> Actions) {
        self.title = title; self.message = message; self.isStarting = isStarting; self.actions = actions()
    }
    var body: some View {
        StudioStartupView(title: title, message: message, isStarting: isStarting) { actions }
    }
}
private extension ProductionStateCard where Actions == EmptyView {
    init(title: String, message: String? = nil, isStarting: Bool = false) {
        self.init(title: title, message: message, isStarting: isStarting) { EmptyView() }
    }
}

@MainActor private final class PrefoundationCompletionBridge: CompletionIntent {
    private weak var owner: AppComposition?
    init(owner: AppComposition) { self.owner = owner }
    /// Marker resume belongs to AppComposition so this lazy pre-foundation UI
    /// cannot invent a draft or surface a demo dashboard.
    func load() async throws -> CompletionDraft? { nil }
    func save(_ draft: CompletionDraft) async throws { guard let owner else { throw CancellationError() }; try await owner.completeOnboarding(draft) }
}
