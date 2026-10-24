import Foundation

public enum KlangschriftToken { public static let spacing: [Double] = [4, 8, 12, 16, 24, 32, 40, 56]; public static let controlRadius: Double = 10; public static let cardRadius: Double = 14; public static let tileRadius: Double = 20; public static let compactShadowOpacity: Double = 0.12; public static let standardMotionSeconds: Double = 0.22; public static let reducedMotionSeconds: Double = 0 }
public enum BrandAsset {
    public static let logoName = "KlangschriftLogo"
    public static let logoFileName = "KlangschriftLogo.png"
}
/// Studio keeps the user-selected light/dark/system preference intact. The
/// palettes share one apricot action signal, not a forced global appearance.
public enum KlangschriftColorToken: String, CaseIterable, Sendable { case ink = "F5F0E9", inkSecondary = "C8BFB6", canvas = "191817", surface = "2A2825", line = "645C54", accent = "F29B62", listening = "BE4D58", success = "176B52", busy = "8C4A22", error = "B9323D" }
public enum KlangschriftStatus: String, CaseIterable, Sendable { case idle, listening, processing, success, busy, error }
public enum KlangschriftTypography: String, CaseIterable, Sendable { case display, title, headline, body, caption }

public struct KlangschriftRGBA: Sendable, Equatable { public let red: Double; public let green: Double; public let blue: Double; public init(_ red: Double, _ green: Double, _ blue: Double) { self.red = red; self.green = green; self.blue = blue } }
public enum KlangschriftPaletteRole: String, CaseIterable, Sendable { case canvas, surface, elevated, accentSurface, primary, secondary, separator, accent, listening, processing, success, busy, error }
public enum KlangschriftPalette {
    /// Contrast-safe foreground for a solid accent-filled control.
    public static func onAccent(dark: Bool) -> KlangschriftRGBA {
        dark ? color(.canvas, dark: true) : .init(1, 1, 1)
    }

    public static func color(_ role: KlangschriftPaletteRole, dark: Bool) -> KlangschriftRGBA { switch (role, dark) {
    case (.canvas, false): .init(0.988, 0.973, 0.953)
    case (.surface, false): .init(1, 1, 1)
    case (.elevated, false): .init(0.945, 0.914, 0.882)
    case (.accentSurface, false): .init(0.976, 0.871, 0.796)
    case (.primary, false): .init(0.169, 0.141, 0.125)
    case (.secondary, false): .init(0.302, 0.267, 0.243)
    case (.separator, false): .init(0.478, 0.435, 0.396)
    case (.accent, false), (.processing, false): .init(0.643, 0.278, 0.094)
    case (.listening, false): .init(0.647, 0.149, 0.247)
    case (.success, false): .init(0.141, 0.400, 0.180)
    case (.busy, false): .init(0.459, 0.294, 0)
    case (.error, false): .init(0.631, 0.102, 0.169)
    case (.canvas, true): .init(0.098, 0.094, 0.090)
    case (.surface, true): .init(0.165, 0.157, 0.145)
    case (.elevated, true): .init(0.192, 0.180, 0.169)
    case (.accentSurface, true): .init(0.290, 0.204, 0.157)
    case (.primary, true): .init(0.961, 0.941, 0.914)
    case (.secondary, true): .init(0.784, 0.749, 0.714)
    case (.separator, true): .init(0.392, 0.361, 0.329)
    case (.accent, true), (.processing, true): .init(0.949, 0.608, 0.384)
    case (.listening, true): .init(1, 0.62, 0.70)
    case (.success, true): .init(0.45, 0.88, 0.67)
    case (.busy, true): .init(1, 0.79, 0.43)
    case (.error, true): .init(1, 0.57, 0.62)
    } }
    public static func contrast(_ foreground: KlangschriftRGBA, _ background: KlangschriftRGBA) -> Double { func l(_ c: KlangschriftRGBA) -> Double { let v = [c.red,c.green,c.blue].map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }; return 0.2126*v[0]+0.7152*v[1]+0.0722*v[2] }; let a=l(foreground), b=l(background); return (max(a,b)+0.05)/(min(a,b)+0.05) }
}
