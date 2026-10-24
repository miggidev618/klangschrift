import Foundation
import ApplicationServices
import CryptoKit
import KlangschriftCore

public struct ShortcutModifier: OptionSet, Sendable, Hashable { public let rawValue: UInt64; public init(rawValue: UInt64) { self.rawValue = rawValue }; public static let command = Self(rawValue: 1 << 0); public static let option = Self(rawValue: 1 << 1); public static let control = Self(rawValue: 1 << 2); public static let shift = Self(rawValue: 1 << 3); public static let function = Self(rawValue: 1 << 4); public static let known: Self = [.command,.option,.control,.shift,.function] }
public enum FnGlobeProfile: String, Sendable, Codable { case disabled, functionModifier, globeQualified }
public struct ShortcutDescriptor: Sendable, Hashable {
    public static let functionKeyCode: UInt16 = 63
    /// ISO/ANSI right Option.  It is deliberately a separate physical gesture,
    /// never an alias for the left Option modifier (key code 58).
    public static let rightOptionKeyCode: UInt16 = 61
    public let keyCode: UInt16; public let modifiers: ShortcutModifier; public let fnGlobeProfile: FnGlobeProfile
    public init(keyCode: UInt16, modifiers: ShortcutModifier, fnGlobeProfile: FnGlobeProfile = .disabled) throws {
        guard keyCode <= 0x7f, modifiers.subtracting(.known).isEmpty, !modifiers.isEmpty || fnGlobeProfile != .disabled else { throw ServiceContractError.invalidConfiguration("shortcut") }
        // Modifier-only right Option is valid only as its isolated physical
        // hold.  This prevents a persisted left Option or chord binding from
        // silently acquiring the privileged side-key semantics.
        guard keyCode != Self.rightOptionKeyCode || (modifiers == .option && fnGlobeProfile == .disabled) else { throw ServiceContractError.invalidConfiguration("right-option") }
        self.keyCode = keyCode; self.modifiers = modifiers; self.fnGlobeProfile = fnGlobeProfile
    }
    public var isFunctionOnly: Bool { keyCode == Self.functionKeyCode && modifiers == .function && fnGlobeProfile == .functionModifier }
    public var isRightOptionHoldOnly: Bool { keyCode == Self.rightOptionKeyCode && modifiers == .option && fnGlobeProfile == .disabled }
}
public enum KeyboardDeviceClass: String, Sendable, Codable { case internalKeyboard, externalKeyboard, unknown }

/// Fixed SHA-256 representation used only as a local correlation key. Its
/// initializer rejects anything but canonical lowercase 64-hex persistence.
public struct FnGlobeHash: Sendable, Equatable, Hashable, Codable {
    public let persistedValue: String
    public init?(persistedValue: String) {
        guard persistedValue.count == 64,
              persistedValue.unicodeScalars.allSatisfy({ ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102) }) else { return nil }
        self.persistedValue = persistedValue
    }
    fileprivate static func localSHA256(_ raw: Data) -> Self {
        let encoded = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        // SHA-256 construction always has canonical length/format.
        return Self(persistedValue: encoded)!
    }
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = Self(persistedValue: value) else { throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "invalid Fn/Globe hash") }
        self = parsed
    }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(persistedValue) }
}

/// A local proof contains only canonical hashes, never raw hardware IDs or
/// event signatures. Its initializer is module-internal: the qualification
/// service below is the sole production factory.
public struct FnGlobeCaptureProof: Sendable, Equatable, Codable, Hashable {
    public let deviceIdentifierHash: FnGlobeHash
    public let keyboardClass: KeyboardDeviceClass
    public let observedSignatureHash: FnGlobeHash
    public let sawDown: Bool
    public let sawUp: Bool
    public let sawFlagsChanged: Bool
    init(deviceIdentifierHash: FnGlobeHash, keyboardClass: KeyboardDeviceClass, observedSignatureHash: FnGlobeHash, sawDown: Bool, sawUp: Bool, sawFlagsChanged: Bool) {
        self.deviceIdentifierHash = deviceIdentifierHash; self.keyboardClass = keyboardClass; self.observedSignatureHash = observedSignatureHash
        self.sawDown = sawDown; self.sawUp = sawUp; self.sawFlagsChanged = sawFlagsChanged
    }
    public var qualified: Bool { keyboardClass != .unknown && sawDown && sawUp && sawFlagsChanged }
}

/// Persistence is local and keyed by a canonical, already-hashed device ID.
/// Implementations must not log the keys or proof values.
public protocol FnGlobeCaptureProofStore: Sendable {
    func proof(for deviceIdentifierHash: FnGlobeHash) throws -> FnGlobeCaptureProof?
    func save(_ proof: FnGlobeCaptureProof) throws
    func invalidateProofs(except deviceIdentifierHash: FnGlobeHash?) throws
}

/// Concrete isolated settings adapter. Callers supply a dedicated suite; tests
/// must use a unique suite and remove its persistent domain afterwards.
public final class UserDefaultsFnGlobeCaptureProofStore: FnGlobeCaptureProofStore, @unchecked Sendable {
    public static let storageKey = "io.github.miggidev618.klangschrift.fnGlobeProofs.v1"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults = defaults }
    private func load() throws -> [FnGlobeCaptureProof] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        do {
            let values = try JSONDecoder().decode([FnGlobeCaptureProof].self, from: data)
            guard values.allSatisfy(\.qualified) else { throw ServiceContractError.invalidConfiguration("fn-globe-proof") }
            return values
        } catch { throw ServiceContractError.invalidConfiguration("fn-globe-proof") }
    }
    private func write(_ values: [FnGlobeCaptureProof]) throws {
        let data = try JSONEncoder().encode(values); defaults.set(data, forKey: Self.storageKey)
    }
    public func proof(for deviceIdentifierHash: FnGlobeHash) throws -> FnGlobeCaptureProof? { try load().first { $0.deviceIdentifierHash == deviceIdentifierHash } }
    public func save(_ proof: FnGlobeCaptureProof) throws {
        guard proof.qualified else { throw ServiceContractError.invalidConfiguration("fn-globe-proof") }
        var values = try load().filter { $0.deviceIdentifierHash != proof.deviceIdentifierHash }
        values.append(proof); try write(values)
    }
    public func invalidateProofs(except deviceIdentifierHash: FnGlobeHash?) throws { try write(try load().filter { $0.deviceIdentifierHash == deviceIdentifierHash }) }
}

public enum FnGlobeActivation: Sendable, Equatable { case enabled, disabledNeedsCaptureProof }

/// The only production flow that creates and validates proofs. Raw device IDs
/// and signatures enter as ephemeral Data, are SHA-256 hashed locally, and are
/// not retained beyond this call.
public struct FnGlobeQualificationService: Sendable {
    private let store: any FnGlobeCaptureProofStore
    public init(store: any FnGlobeCaptureProofStore) { self.store = store }
    @discardableResult public func recordQualifiedCapture(rawDeviceIdentifier: Data, rawObservedSignature: Data, keyboardClass: KeyboardDeviceClass, sawDown: Bool, sawUp: Bool, sawFlagsChanged: Bool) throws -> Bool {
        guard !rawDeviceIdentifier.isEmpty, !rawObservedSignature.isEmpty, keyboardClass != .unknown, sawDown && sawUp && sawFlagsChanged else { return false }
        let proof = FnGlobeCaptureProof(deviceIdentifierHash: .localSHA256(rawDeviceIdentifier), keyboardClass: keyboardClass, observedSignatureHash: .localSHA256(rawObservedSignature), sawDown: sawDown, sawUp: sawUp, sawFlagsChanged: sawFlagsChanged)
        try store.save(proof); return true
    }
    /// Controlled proof handoff for the temporary capture boundary. The value
    /// contains hashes only and is revalidated by the consumer's proof store.
    public func recordQualifiedCaptureProof(rawDeviceIdentifier: Data, rawObservedSignature: Data, keyboardClass: KeyboardDeviceClass, sawDown: Bool, sawUp: Bool, sawFlagsChanged: Bool) throws -> FnGlobeCaptureProof? {
        guard try recordQualifiedCapture(rawDeviceIdentifier: rawDeviceIdentifier, rawObservedSignature: rawObservedSignature, keyboardClass: keyboardClass, sawDown: sawDown, sawUp: sawUp, sawFlagsChanged: sawFlagsChanged) else { return nil }
        return try store.proof(for: .localSHA256(rawDeviceIdentifier))
    }
    public func activation(for shortcut: ShortcutDescriptor, rawDeviceIdentifier: Data, rawObservedSignature: Data, keyboardClass: KeyboardDeviceClass) throws -> FnGlobeActivation {
        guard shortcut.fnGlobeProfile == .globeQualified else { return .enabled }
        guard !rawDeviceIdentifier.isEmpty, !rawObservedSignature.isEmpty else { return .disabledNeedsCaptureProof }
        let deviceHash = FnGlobeHash.localSHA256(rawDeviceIdentifier)
        let signatureHash = FnGlobeHash.localSHA256(rawObservedSignature)
        guard let proof = try store.proof(for: deviceHash), proof.qualified, proof.keyboardClass == keyboardClass, proof.observedSignatureHash == signatureHash else { return .disabledNeedsCaptureProof }
        return .enabled
    }
    public func keyboardDidChange(rawDeviceIdentifier: Data?) throws {
        let active = rawDeviceIdentifier.map(FnGlobeHash.localSHA256)
        try store.invalidateProofs(except: active)
    }
}

/// Compatibility capture data for live event collection. Convert it to a proof
/// only after the caller supplies a stable hashed device identifier and signature.
public struct FnGlobeCaptureProfile: Sendable, Equatable { public let device: KeyboardDeviceClass; public let sawDown: Bool; public let sawUp: Bool; public let sawFlagsChanged: Bool; public init(device: KeyboardDeviceClass, sawDown: Bool, sawUp: Bool, sawFlagsChanged: Bool) { self.device = device; self.sawDown = sawDown; self.sawUp = sawUp; self.sawFlagsChanged = sawFlagsChanged }; public var qualified: Bool { device != .unknown && sawDown && sawUp && sawFlagsChanged } }
public enum ShortcutConflict: Sendable, Equatable { case exactExisting(ShortcutDescriptor); case macOSReservation(String); case notReliablyDetectable }
public struct ShortcutConflictChecker: Sendable {
    public init() {}
    public func conflicts(candidate: ShortcutDescriptor, configured: [ShortcutDescriptor]) -> [ShortcutConflict] {
        var result = configured.filter { $0 == candidate }.map { ShortcutConflict.exactExisting($0) }
        if candidate.fnGlobeProfile == .globeQualified { result.append(.macOSReservation("double-fn-dictation")) }
        result.append(.notReliablyDetectable); return result
    }
}
/// Audited launch gate for persisted Globe-qualified bindings. A binding may
/// load at start only when the store holds a qualified proof whose device
/// hash belongs to a currently connected keyboard. The raw device identifiers
/// are injected by the app shell; enumeration failure and empty results
/// decide strictly NO.
public struct ProductionGlobeLaunchEvidence: Sendable {
    public let proofStore: any FnGlobeCaptureProofStore
    private let currentRawDeviceIdentifiers: @Sendable () -> [Data]
    public init(proofStore: any FnGlobeCaptureProofStore, currentRawDeviceIdentifiers: @escaping @Sendable () -> [Data]) {
        self.proofStore = proofStore
        self.currentRawDeviceIdentifiers = currentRawDeviceIdentifiers
    }
    /// Recomputed on every decision so an already-unplugged keyboard can
    /// never keep admitting a stale binding.
    public var currentDeviceIdentifierHashes: Set<FnGlobeHash> {
        Set(currentRawDeviceIdentifiers().filter { !$0.isEmpty }.map(FnGlobeHash.localSHA256))
    }
    public func qualifiesLaunchLoad() -> Bool {
        for hash in currentDeviceIdentifierHashes {
            guard let proof = try? proofStore.proof(for: hash), proof.qualified else { continue }
            return true
        }
        return false
    }
}

public protocol EventTapPreflightChecking: ServicePreflightChecking { }
public final class CGEventTapAdapter: @unchecked Sendable {
    /// Event-local device-side Option bits from IOLLEvent.h. They are facts of
    /// this callback's flags, unlike global key-state sampling.
    public static func normalizeTemporaryObservation(kind: RawShortcutEventKind, keyCode: UInt16, flags: UInt64, isRepeat: Bool, timestamp: UInt64) -> RawShortcutObservation {
        let left = kind == .flagsChanged ? (flags & 0x20) != 0 : nil
        let right = kind == .flagsChanged ? (flags & 0x40) != 0 : nil
        let side = keyCode == 58 ? left : keyCode == 61 ? right : nil
        return .init(kind: kind, keyCode: keyCode, modifiers: flags, isRepeat: isRepeat, modifierIsDown: side, leftOptionIsDown: left, rightOptionIsDown: right, timestamp: timestamp)
    }
    private final class CallbackBox {
        let handler: @Sendable (HotkeyPlatformEvent) -> Void
        let rawHandler: @Sendable (RawShortcutObservation) -> Bool
        let statusHandler: @Sendable (EventTapRecoveryStatus) -> Void
        let keyboardChangeHandler: @Sendable () -> Void
        let temporaryCapture: EventTapTemporaryCaptureController?
        weak var owner: CGEventTapAdapter?
        init(handler: @escaping @Sendable (HotkeyPlatformEvent) -> Void, rawHandler: @escaping @Sendable (RawShortcutObservation) -> Bool, statusHandler: @escaping @Sendable (EventTapRecoveryStatus) -> Void, keyboardChangeHandler: @escaping @Sendable () -> Void, temporaryCapture: EventTapTemporaryCaptureController?) { self.handler = handler; self.rawHandler = rawHandler; self.statusHandler = statusHandler; self.keyboardChangeHandler = keyboardChangeHandler; self.temporaryCapture = temporaryCapture }
    }
    private let preflight: any EventTapPreflightChecking; private let runLoop: CFRunLoop; private let lock = NSLock(); private var tap: CFMachPort?; private var source: CFRunLoopSource?; private var box: Unmanaged<CallbackBox>?
    public init(preflight: any EventTapPreflightChecking, runLoop: CFRunLoop = CFRunLoopGetMain(), handler: @escaping @Sendable (HotkeyPlatformEvent) -> Void = { _ in }, rawHandler: @escaping @Sendable (RawShortcutObservation) -> Bool = { _ in false }, statusHandler: @escaping @Sendable (EventTapRecoveryStatus) -> Void = { _ in }, keyboardChangeHandler: @escaping @Sendable () -> Void = {}, temporaryCapture: EventTapTemporaryCaptureController? = nil) {
        self.preflight = preflight; self.runLoop = runLoop
        let retained = Unmanaged.passRetained(CallbackBox(handler: handler, rawHandler: rawHandler, statusHandler: statusHandler, keyboardChangeHandler: keyboardChangeHandler, temporaryCapture: temporaryCapture)); self.box = retained; retained.takeUnretainedValue().owner = self
    }
    deinit { uninstall(); box?.release() }
    /// Does not request TCC and does not install until the caller explicitly invokes `installIfReady`.
    private static let callback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
        // A physical tap-disable must always be recovered before temporary
        // capture suppression is considered. It has no trustworthy keycode.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let status = box.owner?.reactivateAfterDisable() ?? .failedClosed
            _ = box.temporaryCapture?.terminateActive(with: .init(kind: .tapDisabled, timestamp: event.timestamp))
            box.statusHandler(status)
            // The raw delivery is required for the configured matcher to
            // cancel an active matched gesture. Legacy platform handlers are
            // retained for existing clients, but production listens only here.
            _ = box.rawHandler(.init(kind: .tapDisabled, timestamp: event.timestamp))
            box.handler(.tapDisabled)
            return Unmanaged.passUnretained(event)
        }
        let rawKind: RawShortcutEventKind? = switch type { case .keyDown: .keyDown; case .keyUp: .keyUp; case .flagsChanged: .flagsChanged; case .leftMouseDown, .rightMouseDown, .otherMouseDown: .mouseDown; default: nil }
        let rawKeyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard rawKeyCode >= 0, rawKeyCode <= Int64(UInt16.max) else { return Unmanaged.passUnretained(event) }
        if let rawKind {
            let keyCode = UInt16(rawKeyCode)
            let observation = CGEventTapAdapter.normalizeTemporaryObservation(kind: rawKind, keyCode: keyCode, flags: UInt64(event.flags.rawValue), isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, timestamp: event.timestamp)
            // Returning nil is the actual CGEventTap suppression boundary. It
            // prevents a captured/configured Fn event from also triggering the
            // macOS input-source switch while leaving all unrelated keys alone.
            if box.temporaryCapture?.receive(observation) == true { return nil }
            if box.rawHandler(observation) { return nil }
        }
        switch type {
        case .keyDown: box.handler(.keyDown)
        case .keyUp: box.handler(.keyUp)
        case .flagsChanged: box.handler(.flagsChanged)
        default: break
        }
        return Unmanaged.passUnretained(event)
    }
    public func installIfReady() throws {
        guard case .ready = preflight.availability() else { throw ServiceContractError.unavailable("input-monitoring") }
        lock.lock(); defer { lock.unlock() }; guard tap == nil, let box else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.otherMouseDown.rawValue)
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: Self.callback, userInfo: box.toOpaque()), let createdSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else { throw ServiceContractError.unavailable("event-tap") }
        tap = created; source = createdSource; CFRunLoopAddSource(runLoop, createdSource, .commonModes); CGEvent.tapEnable(tap: created, enable: true)
    }
    private func uninstallLocked() { if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }; if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }; tap = nil; source = nil }
    public func uninstall() { _ = box?.takeUnretainedValue().temporaryCapture?.terminateActive(); lock.lock(); defer { lock.unlock() }; uninstallLocked() }
    /// Called by the callback on the exact tap that macOS disabled. Failure tears
    /// the tap down; callers receive `failedClosed` and must not keep recording.
    private func reactivateAfterDisable() -> EventTapRecoveryStatus {
        lock.lock(); defer { lock.unlock() }
        guard let tap else { return .failedClosed }
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else { uninstallLocked(); return .failedClosed }
        return .reactivated
    }
    /// Wake recovery is coordinator-owned. It never runs implicitly from an OS
    /// notification and requires a fresh positive input-monitoring preflight.
    public func resumeAfterWakeIfReady() throws {
        _ = box?.takeUnretainedValue().temporaryCapture?.terminateActive(with: .init(kind: .wake, timestamp: 0))
        guard case .ready = preflight.availability() else { uninstall(); throw ServiceContractError.unavailable("input-monitoring") }
        uninstall(); try installIfReady()
    }
    /// Entry point for the concrete keyboard-device monitor owned by the app
    /// shell. It deliberately does not receive or retain a raw device ID; the
    /// injected qualification service performs immediate local hashing.
    public func handleKeyboardDeviceChange() { box?.takeUnretainedValue().keyboardChangeHandler() }
    public func normalize(type: CGEventType) -> HotkeyPlatformEvent? { switch type { case .keyDown: return .keyDown; case .keyUp: return .keyUp; case .flagsChanged: return .flagsChanged; case .tapDisabledByTimeout, .tapDisabledByUserInput: return .tapDisabled; default: return nil } }
}
public enum EventTapRecoveryStatus: Sendable, Equatable { case reactivated, failedClosed }
public enum HotkeyPlatformEvent: Sendable { case keyDown, keyUp, flagsChanged, tapDisabled, wake }
