import SwiftUI
import KlangschriftDesignSystem

/// Resolves both appearances at the host boundary, including native controls
/// that still read accentColor instead of tint on macOS.
/// Native focus rings, text selection and NSMenu highlights remain OS-owned.
private struct StudioTheme: ViewModifier {
    let paintsCanvas: Bool
    @Environment(\.colorScheme) private var scheme
    private func color(_ role: KlangschriftPaletteRole) -> Color {
        let value = KlangschriftPalette.color(role, dark: scheme == .dark)
        return Color(red: value.red, green: value.green, blue: value.blue)
    }
    func body(content: Content) -> some View {
        content
            .environment(\.locale, AppLocalization.locale)
            .tint(color(.accent))
            .accentColor(color(.accent))
            .foregroundStyle(color(.primary))
            .background(paintsCanvas ? color(.canvas) : .clear)
    }
}

public extension View {
    func klangschriftTheme(paintsCanvas: Bool = true) -> some View { modifier(StudioTheme(paintsCanvas: paintsCanvas)) }
}

/// Keeps the label readable on the light apricot accent in dark appearance.
public struct StudioProminentButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        let dark = scheme == .dark
        let accent = KlangschriftPalette.color(.accent, dark: dark)
        let label = KlangschriftPalette.onAccent(dark: dark)
        let foreground = Color(red: label.red, green: label.green, blue: label.blue)
        return configuration.label
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(red: accent.red, green: accent.green, blue: accent.blue), in: RoundedRectangle(cornerRadius: KlangschriftToken.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: KlangschriftToken.controlRadius)
                    .stroke(foreground.opacity(configuration.isPressed ? 0.5 : 0), lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.5)
    }
}
