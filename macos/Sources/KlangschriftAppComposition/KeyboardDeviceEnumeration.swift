import Foundation
import IOKit
import IOKit.hid

/// Minimal read-only enumeration of currently attached keyboard HID devices.
/// It backs the audited Globe launch provider and returns opaque identifier
/// bytes only; nothing about the hardware is logged or retained beyond local
/// hashing. Any failure yields an empty result, which every consumer must
/// treat as a fail-closed NO.
public enum ProductionKeyboardDeviceEnumeration {
    public static func connectedKeyboardIdentifiers() -> [Data] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard] as CFDictionary
        IOHIDManagerSetDeviceMatching(manager, matching)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty else { return [] }
        var identifiers: [Data] = []
        for device in devices {
            guard let vendor = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int,
                  let product = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int else { continue }
            var serial = ""
            if let value = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String { serial = value }
            identifiers.append(Data("\(vendor)-\(product)-\(serial)".utf8))
        }
        return identifiers
    }
}
