import Foundation
import KlangschriftCore

/// Ephemeral P2-only event facts. They are deliberately not Codable and have
/// no logging/persistence API.
public enum RawShortcutEventKind: Sendable, Equatable { case keyDown, keyUp, flagsChanged, mouseDown, tapDisabled, wake }
public struct RawShortcutObservation: Sendable {
    public let kind: RawShortcutEventKind; public let keyCode: UInt16; public let modifiers: UInt64; public let isRepeat: Bool; public let modifierIsDown: Bool?; public let leftOptionIsDown: Bool?; public let rightOptionIsDown: Bool?; public let timestamp: UInt64
    public init(kind: RawShortcutEventKind, keyCode: UInt16 = 0, modifiers: UInt64 = 0, isRepeat: Bool = false, modifierIsDown: Bool? = nil, leftOptionIsDown: Bool? = nil, rightOptionIsDown: Bool? = nil, timestamp: UInt64) { self.kind = kind; self.keyCode = keyCode; self.modifiers = modifiers; self.isRepeat = isRepeat; self.modifierIsDown = modifierIsDown; self.leftOptionIsDown = leftOptionIsDown; self.rightOptionIsDown = rightOptionIsDown; self.timestamp = timestamp }
}
/// Raw identity is confined to the P2/AppAdapters boundary; it must never
/// cross into UI, diagnostics, persistence or Codable representations.
public struct RawKeyboardIdentityObservation: Sendable { public let device: Data; public let signature: Data; public let keyboardClass: KeyboardDeviceClass; public init(device: Data, signature: Data, keyboardClass: KeyboardDeviceClass) { self.device = device; self.signature = signature; self.keyboardClass = keyboardClass } }
public protocol CurrentKeyboardIdentityObserving: Sendable { func currentIdentity() -> RawKeyboardIdentityObservation? }
public protocol EventTapTemporaryCaptureControlling: Sendable {
    func beginTemporaryCapture(token: UUID, receive: @escaping @Sendable (UUID, RawShortcutObservation) -> Void) throws
    func endTemporaryCapture(token: UUID)
}
/// Exclusive capture state shared by the physical event-tap owner. While a
/// token is active live hotkey delivery is suppressed; every terminal fact is
/// forwarded once and the owner must call `endTemporaryCapture` idempotently.
public final class EventTapTemporaryCaptureController: EventTapTemporaryCaptureControlling, @unchecked Sendable {
    private let lock = NSLock(); private var token: UUID?; private var callback: (@Sendable (UUID, RawShortcutObservation) -> Void)?
    public init() {}
    public func beginTemporaryCapture(token: UUID, receive: @escaping @Sendable (UUID, RawShortcutObservation) -> Void) throws { lock.lock(); defer { lock.unlock() }; guard self.token == nil else { throw ServiceContractError.unavailable("temporary-capture-busy") }; self.token = token; callback = receive }
    public func endTemporaryCapture(token: UUID) { lock.lock(); defer { lock.unlock() }; guard self.token == token else { return }; self.token = nil; callback = nil }
    /// Called by the existing physical CGEventTapAdapter callback after it has
    /// normalized keyCode/modifiers. Returns true when live delivery is
    /// suppressed by exclusive temporary capture.
    @discardableResult public func receive(_ observation: RawShortcutObservation) -> Bool {
        if observation.kind == .tapDisabled || observation.kind == .wake { return terminateActive(with: observation) }
        // Capture observes keyboard only. Pointer input must remain available
        // for the visible cancel control and normal window interaction.
        guard observation.kind != .mouseDown else { return false }
        lock.lock(); let token = self.token, callback = self.callback; lock.unlock()
        guard let token, let callback else { return false }; callback(token, observation); return true
    }
    /// Delivers an OS/lifecycle terminal fact at most once, then releases the
    /// exclusive token before invoking client code. This prevents a stale
    /// callback from suppressing live delivery after the physical tap changed.
    @discardableResult public func terminateActive(with observation: RawShortcutObservation = .init(kind: .wake, timestamp: 0)) -> Bool {
        lock.lock(); let token = self.token, callback = self.callback; self.token = nil; self.callback = nil; lock.unlock()
        guard let token, let callback else { return false }; callback(token, observation); return true
    }
    deinit { lock.lock(); token = nil; callback = nil; lock.unlock() }
}
