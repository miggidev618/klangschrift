#if canImport(UIKit)
import UIKit

/// Studio tokens shared by host and keyboard; solid controls use onAction.
enum KlangPalette {
    private static func pair(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
    static let canvas = pair(0xFCF8F3, 0x191817)
    static let surface = pair(0xFFFFFF, 0x2A2825)
    static let ink = pair(0x2B2420, 0xF5F0E9)
    static let secondary = pair(0x4D443E, 0xC8BFB6)
    static let accent = pair(0xA44718, 0xF29B62)
    static let action = accent
    static let onAction = pair(0xFFFFFF, 0x191817)
    static let selected = pair(0xF9DECB, 0x4A3428)
    static let separator = pair(0x7A6F65, 0x645C54)
    static let error = pair(0xA11A2B, 0xFF919E)
    // A filled stop control retains white-label contrast in both modes.
    static let stopAction = pair(0xA11A2B, 0xA11A2B)
}
#endif
