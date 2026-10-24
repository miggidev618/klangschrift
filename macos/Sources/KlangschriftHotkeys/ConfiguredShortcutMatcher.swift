import Foundation
import ApplicationServices

/// The persisted intent associated with a physical shortcut.  The matcher
/// deliberately returns only a typed event and mode; raw keyboard facts never
/// leave this P2 boundary or enter storage/diagnostics.
public enum ConfiguredShortcutMode: String, Sendable, Equatable {
    case pushToTalk
    case toggle
    case reinsert
}

public struct ConfiguredShortcut: Sendable, Equatable {
    public let descriptor: ShortcutDescriptor
    public let mode: ConfiguredShortcutMode
    public init(descriptor: ShortcutDescriptor, mode: ConfiguredShortcutMode) {
        self.descriptor = descriptor
        self.mode = mode
    }
}

public struct MatchedShortcutEvent: Sendable {
    public let event: HotkeyEvent
    public let physicalKeyCode: UInt16?
    public let mode: ConfiguredShortcutMode
    /// Observation and event-tap suppression are intentionally independent.
    /// The side Option gesture must be observed for cancellation/release but
    /// never consumes the user's physical modifier event.
    public let suppressesSystemEvent: Bool
    public init(event: HotkeyEvent, mode: ConfiguredShortcutMode, suppressesSystemEvent: Bool = true, physicalKeyCode: UInt16? = nil) {
        self.physicalKeyCode = physicalKeyCode
        self.event = event; self.mode = mode; self.suppressesSystemEvent = suppressesSystemEvent
    }
}

/// Matches the *currently configured* shortcut before any event reaches the
/// state machine.  Replacing configuration clears an in-flight key so an old
/// key-up can never finish a newly configured gesture.
public final class ConfiguredShortcutMatcher: @unchecked Sendable {
    private enum ModifierGesture: Sendable, Equatable { case function, rightOption }
    private struct Active: Sendable { let keyCode: UInt16; let mode: ConfiguredShortcutMode; let modifierGesture: ModifierGesture? }
    private let lock = NSLock()
    private var configured: [ConfiguredShortcut]
    private var active: Active?
    private var leftOptionDown = false
    private var rightOptionDown = false
    private let identity: (any CurrentKeyboardIdentityObserving)?
    private let qualification: FnGlobeQualificationService?

    public init(configured: [ConfiguredShortcut] = [], identity: (any CurrentKeyboardIdentityObserving)? = nil, qualification: FnGlobeQualificationService? = nil) {
        self.configured = configured
        self.identity = identity
        self.qualification = qualification
    }

    /// One locked replacement is the settings-reload transaction.
    public func replaceConfigured(_ values: [ConfiguredShortcut]) {
        lock.lock(); configured = values; active = nil; leftOptionDown = false; rightOptionDown = false; lock.unlock()
    }
    /// Terminal actions (Escape/settings/disable) must invalidate an in-flight
    /// physical gesture without pretending either Option side was released.
    public func cancelActiveGesture() { lock.withLock { active = nil } }

    public func consume(_ observation: RawShortcutObservation) -> MatchedShortcutEvent? {
        lock.lock(); defer { lock.unlock() }
        switch observation.kind {
        case .tapDisabled:
            active = nil
            leftOptionDown = false; rightOptionDown = false
            return .init(event: .tapDisabled, mode: .toggle)
        case .wake:
            active = nil
            leftOptionDown = false; rightOptionDown = false
            return .init(event: .wake, mode: .toggle)
        case .mouseDown:
            guard let active, active.modifierGesture == .rightOption else { return nil }
            self.active = nil
            return .init(event: .cancel, mode: active.mode, suppressesSystemEvent: false)
        case .keyDown:
            if let active {
                if active.modifierGesture == .rightOption {
                    self.active = nil
                    return .init(event: .cancel, mode: active.mode, suppressesSystemEvent: false)
                }
                guard active.keyCode == observation.keyCode else { return nil }
                return .init(event: .keyDown(timestamp: observation.timestamp, isRepeat: true), mode: active.mode)
            }
            guard !observation.isRepeat,
                  let shortcut = configured.first(where: { matches($0.descriptor, observation) }) else { return nil }
            let gesture: ModifierGesture? = shortcut.descriptor.isFunctionOnly ? .function : shortcut.descriptor.isRightOptionHoldOnly ? .rightOption : nil
            active = .init(keyCode: observation.keyCode, mode: shortcut.mode, modifierGesture: gesture)
            return .init(event: .keyDown(timestamp: observation.timestamp, isRepeat: false), mode: shortcut.mode, physicalKeyCode: observation.keyCode)
        case .keyUp:
            guard let active, active.keyCode == observation.keyCode else { return nil }
            self.active = nil
            return .init(event: .keyUp(timestamp: observation.timestamp), mode: active.mode)
        case .flagsChanged:
            let normalized = Self.normalizedModifiers(observation.modifiers)
            // macOS' aggregate Alternate mask cannot tell which Option side
            // remains down. The tap supplies an independent physical key-state
            // fact for 58/61; unknown facts never manufacture a new gesture.
            if let left = observation.leftOptionIsDown { leftOptionDown = left }
            else if observation.keyCode == 58, let isDown = observation.modifierIsDown { leftOptionDown = isDown }
            if let right = observation.rightOptionIsDown { rightOptionDown = right }
            else if observation.keyCode == 61, let isDown = observation.modifierIsDown { rightOptionDown = isDown }
            if let active, let gesture = active.modifierGesture {
                switch gesture {
                case .function:
                    guard active.keyCode == observation.keyCode else { return nil }
                    if normalized == .function { return .init(event: .tick(timestamp: observation.timestamp), mode: active.mode) }
                    self.active = nil
                    return .init(event: .keyUp(timestamp: observation.timestamp), mode: active.mode)
                case .rightOption:
                    // A flags event for another physical key is a chord, not
                    // a right-Option release.  Observe/cancel, then pass it.
                    guard active.keyCode == observation.keyCode else {
                        self.active = nil
                        return .init(event: .cancel, mode: active.mode, suppressesSystemEvent: false)
                    }
                    // Normal release clears alternate when no left Option is
                    // down.  With left Option already observed, the right
                    // side must not start in the first place; this branch is
                    // therefore a fail-closed release/cancel rather than a
                    // synthetic extra down.
                    guard rightOptionDown else {
                        self.active = nil
                        let event: HotkeyEvent = leftOptionDown ? .cancel : .keyUp(timestamp: observation.timestamp)
                        return .init(event: event, mode: active.mode, suppressesSystemEvent: false)
                    }
                    guard !leftOptionDown else { self.active = nil; return .init(event: .cancel, mode: active.mode, suppressesSystemEvent: false) }
                    return .init(event: .tick(timestamp: observation.timestamp), mode: active.mode, suppressesSystemEvent: false)
                }
            }
            if active == nil,
               let shortcut = configured.first(where: {
                   guard ($0.descriptor.isFunctionOnly || $0.descriptor.isRightOptionHoldOnly), matches($0.descriptor, observation) else { return false }
                   return !$0.descriptor.isRightOptionHoldOnly || ($0.mode == .pushToTalk && rightOptionDown && !leftOptionDown)
               }) {
                let gesture: ModifierGesture = shortcut.descriptor.isRightOptionHoldOnly ? .rightOption : .function
                active = .init(keyCode: observation.keyCode, mode: shortcut.mode, modifierGesture: gesture)
                return .init(event: .keyDown(timestamp: observation.timestamp, isRepeat: false), mode: shortcut.mode, suppressesSystemEvent: gesture != .rightOption, physicalKeyCode: observation.keyCode)
            }
            // A flags event for another physical key must never advance a
            // gesture.  The key code is intentionally compared, not logged.
            guard let active, active.keyCode == observation.keyCode else { return nil }
            return .init(event: .tick(timestamp: observation.timestamp), mode: active.mode)
        }
    }

    private func matches(_ descriptor: ShortcutDescriptor, _ observation: RawShortcutObservation) -> Bool {
        guard descriptor.keyCode == observation.keyCode,
              Self.normalizedModifiers(observation.modifiers) == descriptor.modifiers else { return false }
        if descriptor.isRightOptionHoldOnly { return observation.kind == .flagsChanged }
        switch descriptor.fnGlobeProfile {
        case .disabled:
            return true
        case .functionModifier:
            return descriptor.modifiers.contains(.function)
        case .globeQualified:
            guard let identity = identity?.currentIdentity(), let qualification else { return false }
            return (try? qualification.activation(for: descriptor, rawDeviceIdentifier: identity.device, rawObservedSignature: identity.signature, keyboardClass: identity.keyboardClass)) == .enabled
        }
    }

    /// Normalizes only the five modifiers that are valid in a descriptor.
    /// All other CG flags are ignored instead of becoming persistence surface.
    public static func normalizedModifiers(_ raw: UInt64) -> ShortcutModifier {
        let flags = CGEventFlags(rawValue: raw)
        var result: ShortcutModifier = []
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskSecondaryFn) { result.insert(.function) }
        return result
    }
}
