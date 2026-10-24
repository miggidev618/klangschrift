import AppKit
import SwiftUI
import KlangschriftDesignSystem
import KlangschriftPresentation

public struct DashboardSidebar: View {
    @ObservedObject var model: DashboardViewModel
    @Environment(\.colorScheme) private var scheme
    public init(model: DashboardViewModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                StudioStartupLogo(size: 32).foregroundStyle(Color.semantic(.accent, scheme))
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "Klangschrift").font(.system(size: 20, weight: .bold)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    Text(verbatim: "You speak. It writes.").font(.system(size: 11)).lineLimit(1).fixedSize(horizontal: true, vertical: false).foregroundStyle(Color.semantic(.secondary, scheme))
                }
            }
            .padding(.bottom, 16)
            ForEach(DashboardRoute.allCases) { route in
                Button {
                    model.route = route
                } label: {
                    Label(route.title, systemImage: route.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.semantic(.primary, scheme))
                .background(
                    model.route == route ? Color.semantic(.accentSurface, scheme) : .clear,
                    in: RoundedRectangle(cornerRadius: KlangschriftToken.controlRadius)
                )
                .accessibilityLabel(route.title)
                .accessibilityAddTraits(model.route == route ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color.semantic(.elevated, scheme))
    }
}
struct DashboardKeyboardShortcuts: View {
    @ObservedObject var model: DashboardViewModel
    var body: some View {
        Group {
            Button(L("Diktieren öffnen")) { model.selectShortcut(1) }.keyboardShortcut("1", modifiers: .command)
            Button(L("Modelle öffnen")) { model.route = .models }.keyboardShortcut("2", modifiers: .command)
            Button(L("Verlauf öffnen")) { model.selectShortcut(2) }.keyboardShortcut("3", modifiers: .command)
            Button(L("Wörterbuch öffnen")) { model.selectShortcut(3) }.keyboardShortcut("4", modifiers: .command)
            Button(L("Einstellungen öffnen")) { model.selectShortcut(4) }.keyboardShortcut("5", modifiers: .command)
            Button(L("Verlauf durchsuchen")) { model.focusHistorySearch() }.keyboardShortcut("f", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
