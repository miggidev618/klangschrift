import AppKit
import SwiftUI
import KlangschriftDesignSystem
import KlangschriftPresentation

/// The estimate compares 40 words/min typing with measured speaking time.
/// It never treats an unknown statistics snapshot as a measured zero.
enum WorkspaceMetrics {
    static func estimatedSavedMinutes(words: Int64, recordedMilliseconds: Int64) -> Double {
        max(0, Double(max(0, words)) / 40 - Double(max(0, recordedMilliseconds)) / 60_000)
    }
    static func shortcutLabel(_ shortcut: ShortcutDraft) -> String {
        SettingsShortcutDisplay.name(shortcut)
    }
    static func averageTempo(words: Int64, recordedMilliseconds: Int64, locale: Locale = AppLocalization.locale) -> String {
        guard recordedMilliseconds > 0 else { return "–" }
        let value = Double(max(0, words)) * 60_000 / Double(recordedMilliseconds)
        return value.formatted(.number.locale(locale).precision(.fractionLength(0)))
    }
    static func hasDictationShortcut(_ shortcut: ShortcutDraft?) -> Bool {
        guard let shortcut, shortcut.keyCode != nil else { return false }
        return shortcut.typedMode == .pushToTalk || shortcut.typedMode == .toggle
    }
}

enum CompactDictationAction: Equatable {
    case start, stop, cancel, disabled
    init(phase: DictationPresentationPhase) {
        switch phase { case .listening: self = .stop; case .processing: self = .cancel; case .busy: self = .disabled; default: self = .start }
    }
    @MainActor func perform(on presentation: DictationPresentationController) async {
        switch self {
        case .start: await presentation.requestStartOrStop()
        case .stop: await presentation.stopAndProcess()
        case .cancel: await presentation.cancel()
        case .disabled: break
        }
    }
}

struct DictationWorkspaceView: View {
    @ObservedObject var model: DashboardViewModel
    let presentation: DictationPresentationController?
    let draftPort: (any AP05LatestDraftPresenting)?
    let permissionIntent: (any PermissionStatusIntent)?
    @State private var recent: [DashboardTranscript] = []
    @State private var recentRequestID = UUID()
    @State private var recentState: DashboardLoadState = .loading
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let presentation {
                    CompactDictationControls(presentation: presentation, permissionIntent: permissionIntent)
                    if let draftPort { WorkspaceDraftEditor(presentation: presentation, port: draftPort) }
                } else {
                    Text(L("Diktieren ist gerade nicht verfügbar.")).foregroundStyle(Color.semantic(.secondary, scheme))
                }
                statistics
                recentHistory
            }
            .padding(32)
        }
        .background(Color.semantic(.canvas, scheme))
        .task(id: model.historyContentRevision) { await loadRecent() }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if WorkspaceMetrics.hasDictationShortcut(model.preferences.shortcut), let shortcut = model.preferences.shortcut {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { prompt(shortcut) }
                    VStack(alignment: .leading, spacing: 8) { prompt(shortcut) }
                }
                .font(.title2.weight(.semibold)).accessibilityElement(children: .combine)
            } else {
                HStack {
                    Text(L("Diktieren")).font(.title2.weight(.semibold))
                    Spacer()
                    Button { model.route = .settings } label: { Text(L("Sprechtaste festlegen")) }
                }
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
    @ViewBuilder private func prompt(_ shortcut: ShortcutDraft) -> some View {
        Text(shortcut.typedMode == .toggle ? L("Drücke") : L("Halte"))
        KeyChip(text: WorkspaceMetrics.shortcutLabel(shortcut))
        Text(shortcut.typedMode == .toggle ? L("zweimal zum Diktieren") : L("zum Diktieren"))
    }
    @ViewBuilder private var statistics: some View {
        if let stats = model.statistics {
            StudioCard {
                VStack(alignment: .leading, spacing: 14) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 24) { metricTiles(stats, fixed: true) }
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 20) { metricTiles(stats, fixed: false) }
                    }
                    Text(L("≈ Schätzung bei 40 Wörtern/min Tippen, abzüglich Sprechzeit."))
                        .font(.caption2).foregroundStyle(Color.semantic(.secondary, scheme))
                    if case .failed = model.statisticsState {
                        Text(L("Kennzahlen konnten nicht aktualisiert werden.")).font(.caption).foregroundStyle(Color.semantic(.secondary, scheme))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if case .failed = model.statisticsState {
            HStack {
                Text(L("Kennzahlen gerade nicht verfügbar."))
                Button { Task { await model.refreshStatistics() } } label: { Text(L("Erneut laden")) }
            }.font(.caption).foregroundStyle(Color.semantic(.secondary, scheme))
        } else { ProgressView { Text(L("Kennzahlen werden geladen …")) } }
    }
    @ViewBuilder private func metricTiles(_ stats: DashboardStatistics, fixed: Bool) -> some View {
        let locale = AppLocalization.locale
        StatTile(value: max(0, stats.totalWords).formatted(.number.locale(locale)), unit: "", label: L("Diktierte Wörter"), wrapsInCard: false)
            .fixedSize(horizontal: fixed, vertical: true)
        StatTile(value: "≈ " + WorkspaceMetrics.estimatedSavedMinutes(words: stats.totalWords, recordedMilliseconds: stats.totalRecordedMilliseconds).formatted(.number.locale(locale).precision(.fractionLength(0))), unit: L("min"), label: L("Zeit gespart · Schätzung"), wrapsInCard: false)
            .fixedSize(horizontal: fixed, vertical: true)
        StatTile(value: max(0, stats.currentStreakDays).formatted(.number.locale(locale)), unit: "", label: L("Tage in Folge"), wrapsInCard: false)
            .fixedSize(horizontal: fixed, vertical: true)
        StatTile(value: WorkspaceMetrics.averageTempo(words: stats.totalWords, recordedMilliseconds: stats.totalRecordedMilliseconds, locale: AppLocalization.locale), unit: L("Wörter/min"), label: L("Ø Tempo"), wrapsInCard: false)
            .fixedSize(horizontal: fixed, vertical: true)
    }
    private var recentHistory: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L("Letzte Diktate")).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { model.searchText = ""; model.route = .history } label: { Text(L("Alle anzeigen")) }
            }
            switch recentState {
            case .content: HistoryDaySections(entries: recent, language: .system, copy: model.copyHistory)
            case .empty: Text(L("Deine nächsten Diktate erscheinen hier.")).font(.subheadline).foregroundStyle(Color.semantic(.secondary, scheme))
            case .failed:
                HStack {
                    Text(L("Die letzten Diktate konnten nicht geladen werden."))
                    Button { Task { await loadRecent() } } label: { Text(L("Erneut laden")) }
                }.font(.caption)
            case .idle, .loading: ProgressView { Text(L("Letzte Diktate werden geladen …")) }
            }
        }
    }
    @MainActor private func loadRecent() async {
        let request = UUID(); recentRequestID = request
        recentState = .loading
        do {
            let values = try await model.recentHistory()
            guard recentRequestID == request, !Task.isCancelled else { return }
            recent = values; recentState = values.isEmpty ? .empty : .content
        } catch { if recentRequestID == request, !Task.isCancelled { recentState = .failed("") } }
    }
}

private struct WorkspaceDraftEditor: View {
    @ObservedObject var presentation: DictationPresentationController
    let port: any AP05LatestDraftPresenting
    var body: some View { AP05LatestDraftEditor(port: port, presentationRevision: presentation.stateRevision) }
}

private struct CompactDictationControls: View {
    @ObservedObject var presentation: DictationPresentationController
    @StateObject private var microphoneRecovery: AP05MicrophoneRecoveryState
    @Environment(\.colorScheme) private var scheme
    init(presentation: DictationPresentationController, permissionIntent: (any PermissionStatusIntent)?) {
        self.presentation = presentation
        _microphoneRecovery = StateObject(wrappedValue: AP05MicrophoneRecoveryState(intent: permissionIntent))
    }
    var body: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    if presentation.state.phase == .processing { ProgressView().controlSize(.small) }
                    Text(status).font(.subheadline).foregroundStyle(Color.semantic(.secondary, scheme))
                    Spacer()
                    Button { Task { await CompactDictationAction(phase: presentation.state.phase).perform(on: presentation) } } label: {
                        Label { Text(actionTitle) } icon: { Image(systemName: actionSymbol) }
                    }
                    .buttonStyle(StudioProminentButtonStyle()).disabled(presentation.state.phase == .busy)
                    .help(L("Der Button erstellt einen Entwurf ohne automatisches Einfügen."))
                    if presentation.state.phase == .listening {
                        Button(role: .cancel) { Task { await presentation.cancel() } } label: { Text(L("Abbrechen")) }
                    }
                }
                if let feedback = AP05DictationActionFeedback.message(for: presentation.state.failure) {
                    Text(verbatim: feedback).font(.caption).foregroundStyle(Color.semantic(.error, scheme))
                }
                if presentation.state.failure == .microphone, microphoneRecovery.isAvailable {
                    HStack(spacing: 10) {
                        if microphoneRecovery.status?.canRequest != false {
                            Button { Task { await microphoneRecovery.requestAccess() } } label: { Text(L("Zugriff erlauben")) }
                        }
                        Button { Task { await microphoneRecovery.refresh() } } label: { Text(L("Erneut prüfen")) }
                        if microphoneRecovery.status?.settingsAvailable != false {
                            Button { microphoneRecovery.openSettings() } label: { Text(L("Systemeinstellungen öffnen")) }
                        }
                    }.font(.caption)
                }
            }
        }
        .task(id: presentation.state.failure) {
            guard presentation.state.failure == .microphone else { return }
            await microphoneRecovery.refresh()
        }
    }
    private var status: String {
        switch presentation.state.phase {
        case .listening: L("Aufnahme läuft"); case .processing: L("Wird transkribiert"); case .busy: L("Bitte warten")
        case .error: L("Aktion erforderlich"); case .success: L("Transkript fertig"); case .recoveryCopied: L("Text liegt bereit"); case .idle: L("Bereit")
        }
    }
    private var actionTitle: String {
        switch CompactDictationAction(phase: presentation.state.phase) {
        case .stop: L("Aufnahme beenden"); case .cancel: L("Verarbeitung abbrechen"); default: L("Entwurf aufnehmen")
        }
    }
    private var actionSymbol: String {
        switch CompactDictationAction(phase: presentation.state.phase) { case .stop: "stop.fill"; case .cancel: "xmark"; default: "mic" }
    }
}

// Retained public scale for existing callers; the home page no longer uses a circular gauge.
public enum DashboardWPMGaugeScale {
    public static let maximum = 200.0
    public static let label = L("Skala bis 200+ Wörter pro Minute")
    public static func displayValue(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return min(value, maximum)
    }
}
