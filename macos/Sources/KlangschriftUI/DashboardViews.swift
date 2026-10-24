import AppKit
import SwiftUI
import KlangschriftDesignSystem
import KlangschriftPresentation

public struct DashboardRootView: View {
    @ObservedObject private var model: DashboardViewModel
    private let presentation: DictationPresentationController?
    private let modelPresenter: (any AP05ModelPresenting)?
    private let draftPort: (any AP05LatestDraftPresenting)?
    private let permissionIntent: (any PermissionStatusIntent)?
    private let permissionRecovery: PermissionRecoveryViewModel?
    @Environment(\.colorScheme) private var scheme
    public init(
        model: DashboardViewModel,
        presentation: DictationPresentationController? = nil,
        modelPresenter: (any AP05ModelPresenting)? = nil,
        draftPort: (any AP05LatestDraftPresenting)? = nil,
        permissionIntent: (any PermissionStatusIntent)? = nil,
        permissionRecovery: PermissionRecoveryViewModel? = nil
    ) {
        self.model = model
        self.presentation = presentation
        self.modelPresenter = modelPresenter
        self.draftPort = draftPort
        self.permissionIntent = permissionIntent
        self.permissionRecovery = permissionRecovery
    }
    public var body: some View {
        HSplitView {
            DashboardSidebar(model: model)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 196, idealWidth: 204, maxWidth: 224)
                .background(Color.semantic(.elevated, scheme))
            Group { switch model.route { case .overview: DictationWorkspaceView(model: model, presentation: presentation, draftPort: draftPort, permissionIntent: permissionIntent); case .models: ModelManagementPage(presenter: modelPresenter); case .history: HistoryView(model: model, focusSearch: $model.requestSearchFocus); case .dictionary: DictionaryView(model: model); case .settings: SettingsPage(model: model, permissionRecovery: permissionRecovery, modelPresenter: modelPresenter) } }
                .frame(minWidth: 600, minHeight: 560)
                .foregroundStyle(Color.semantic(.primary, scheme))
                .background(Color.semantic(.canvas, scheme))
        }
        .frame(minWidth: 800, minHeight: 560)
        .klangschriftTheme()
        .background { DashboardKeyboardShortcuts(model: model) }
        .preferredColorScheme(preferredColorScheme).task { await model.load() }
            .onChange(of: model.shortcutCaptureRecoveryIssue) { _, issue in
                guard let issue, let permissionRecovery else { return }
                Task { await permissionRecovery.presentForShortcutCaptureFailure(issue) }
            }
            .alert(L("Ausgewählte Transkripte löschen?"), isPresented: $model.showDeleteConfirmation) { Button(L("Abbrechen"), role: .cancel) {}; Button(L("Löschen"), role: .destructive) { Task { await model.deleteSelection() } } } message: { Text(L("Die Auswahl wird in den Papierkorb verschoben und kann dort innerhalb des Undo-Zeitraums wiederhergestellt werden.")) }.onExitCommand { model.showDeleteConfirmation = false }
            .alert(L("Transkript konnte nicht kopiert werden"), isPresented: $model.showHistoryCopyFailure) { Button(L("OK")) {} } message: { Text(L("Die Zwischenablage war nicht verfügbar. Bitte erneut versuchen.")) }
            .alert(rangeDeleteTitle, isPresented: Binding(get: { model.pendingDeleteRangeDays != nil }, set: { if !$0 { model.pendingDeleteRangeDays = nil } })) { Button(L("Abbrechen"), role: .cancel) {}; Button(L("Löschen"), role: .destructive) { Task { await model.confirmDeleteRange() } } } message: { Text(rangeDeleteMessage) }
            .alert(L("Gesamten Verlauf löschen?"), isPresented: $model.showClearAllConfirmation) { Button(L("Abbrechen"), role: .cancel) {}; Button(L("Alles löschen"), role: .destructive) { Task { await model.clearAllConfirmed() } } } message: { Text(L("Alle Transkripte werden endgültig entfernt. Dieser Schritt wird NICHT in den Papierkorb verschoben und kann nicht rückgängig gemacht werden.")) }
    }
    private var rangeDeleteDays: Int { model.pendingDeleteRangeDays ?? 0 }
    private var rangeDeleteTitle: String { L("Transkripte älter als %@ Tage löschen?", String(describing: rangeDeleteDays)) }
    private var rangeDeleteMessage: String { L("Transkripte, die älter als %@ Tage sind, werden in den Papierkorb verschoben. Wiederherstellen ist nur solange möglich, wie die App läuft.", String(describing: rangeDeleteDays)) }
    private var preferredColorScheme: ColorScheme? { switch model.preferences.appearance { case .system: nil; case .light: .light; case .dark: .dark } }
}

private struct ModelManagementPage: View {
    let presenter: (any AP05ModelPresenting)?
    var body: some View {
        Group {
            if let presenter {
                AP05ModelSettingsPanel(presenter: presenter)
                    .padding(32)
            } else {
                ContentUnavailableView {
                    Label(L("Modellverwaltung wird verbunden"), systemImage: "cpu")
                } description: {
                    Text(L("Erforderlich ist der bestehende AP05ModelPresenting-Produktport. Status, Größen und Aktionen werden nicht simuliert."))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PageHeader: View { let title: String; init(_ title: String) { self.title = title }; var body: some View { Text(title).font(.system(.largeTitle, design: .rounded)).fontWeight(.semibold).accessibilityAddTraits(.isHeader) } }
