import ApplicationServices

/// HID state precedes event-tap suppression; session state can lose a key
/// consumed by our tap. Conflicting/unspecified Option-side facts keep audio.
public enum HardwareShortcutKeyState {
    public static func isDown(_ key: UInt16) -> Bool? {
        isDown(key, keyState: { CGEventSource.keyState($0, key: $1) },
               flagsState: { CGEventSource.flagsState($0) })
    }

    static func isDown(_ key: UInt16,
                       keyState: (CGEventSourceStateID, UInt16) -> Bool,
                       flagsState: (CGEventSourceStateID) -> CGEventFlags) -> Bool? {
        let down = keyState(.hidSystemState, key)
        guard key == 58 || key == 61 else { return down }
        let flags = flagsState(.hidSystemState)
        let sideMask: UInt64 = key == 61 ? 0x40 : 0x20
        if down || flags.rawValue & sideMask != 0 { return true }
        // Aggregate Option without a side cannot prove this key was released.
        if flags.contains(.maskAlternate) { return nil }
        return false
    }
}
