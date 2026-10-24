import AppKit
import SwiftUI
import KlangschriftDesignSystem
import KlangschriftPresentation

/// The UI only receives product-safe, measured model facts. SDK, worker and
/// manifest diagnostics intentionally do not cross this boundary.
public struct AP05ModelCard: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let language: String
    public let description: String
    public let downloadBytes: Int
    public let installed: Bool
    public let selected: Bool
    public let favorite: Bool
    public let coldPrepareMilliseconds: UInt64?
    public let warmInferenceMilliseconds: UInt64?
    public let actionMessage: String?
    public let supportsNoAudioFirstPrepare: Bool
    public let supportsFavorites: Bool

    public init(id: String, title: String, language: String, description: String, downloadBytes: Int, installed: Bool, selected: Bool, favorite: Bool, coldPrepareMilliseconds: UInt64?, warmInferenceMilliseconds: UInt64?, actionMessage: String?, supportsNoAudioFirstPrepare: Bool, supportsFavorites: Bool = true) {
        self.id = id; self.title = title; self.language = language; self.description = description
        self.downloadBytes = downloadBytes; self.installed = installed; self.selected = selected
        self.favorite = favorite; self.coldPrepareMilliseconds = coldPrepareMilliseconds
        self.warmInferenceMilliseconds = warmInferenceMilliseconds; self.actionMessage = actionMessage
        self.supportsNoAudioFirstPrepare = supportsNoAudioFirstPrepare
        self.supportsFavorites = supportsFavorites
    }
}

/// UI-owned projection of the desktop installer. It deliberately omits source
/// URLs, staging paths and runtime diagnostics, preserving the dependency
/// direction from product code into this UI module.
public enum AP05ModelInstallationPhase: String, Sendable, Equatable {
    case downloading
    case verifying
    case activating
}

public struct AP05ModelInstallationProgress: Sendable, Equatable {
    public let modelID: String
    public let phase: AP05ModelInstallationPhase
    public let completedBytes: Int
    public let totalBytes: Int
    public let completedFiles: Int
    public let totalFiles: Int

    public init(modelID: String, phase: AP05ModelInstallationPhase, completedBytes: Int, totalBytes: Int, completedFiles: Int, totalFiles: Int) {
        self.modelID = modelID
        self.phase = phase
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
    }
}

public enum AP05ModelInstallationStatus: Sendable, Equatable {
    case idle
    case running(AP05ModelInstallationProgress)
    case cancelling(modelID: String)
    case cancelled(modelID: String)
    case failed(modelID: String, message: String)
}

public struct AP05LatestDraft: Equatable, Sendable {
    public let sessionID: UUID?
    public let revision: UInt64
    public let text: String
    public init(sessionID: UUID?, revision: UInt64, text: String) { self.sessionID = sessionID; self.revision = revision; self.text = text }
}

/// This port is app-local. It deliberately has no history or automatic
/// pasteboard operation; copy is a separate explicit user action.
@MainActor public protocol AP05LatestDraftPresenting: AnyObject {
    func latestDraft() async -> AP05LatestDraft?
    /// Returns the exact identity committed by this request, never a later
    /// snapshot. A nil result is fail-closed for stale/foreign ownership.
    func replaceLatestDraft(_ text: String, sessionID: UUID?, revision: UInt64) async -> AP05LatestDraft?
    func copyLatestDraft(sessionID: UUID?, revision: UInt64, text: String) async -> PresentationActionOutcome
}

/// All mutating methods are activated by an explicit user control. Listing,
/// filtering and refresh must never download, record, or create an audio job.
/// Localized errors from a mutating method contain product-safe text; other
/// errors are deliberately collapsed by the UI.
public protocol AP05ModelPresenting: Sendable {
    func cards(language: String?, installedOnly: Bool) async -> [AP05ModelCard]
    func select(modelID: String) async throws
    func setFavorite(modelID: String, enabled: Bool) async throws
    func install(modelID: String) async throws
    func installationStatus() async throws -> AP05ModelInstallationStatus
    /// True only admits cancellation; callers keep observing until a
    /// terminal status confirms staging cleanup.
    func cancelInstall(modelID: String) async throws -> Bool
    func prepareNoAudioFirstUse(modelID: String) async throws
}

public enum AP05ByteFormatter {
    public static func string(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file).locale(AppLocalization.locale))
    }
}

/// Selection changes are committed by the model service before this generation
/// advances. Panel and summary therefore observe one confirmed product fact.
@MainActor public final class AP05ModelSelectionNotice: ObservableObject {
    @Published public private(set) var generation: UInt64 = 0
    private var observers: [UUID: @MainActor () -> Void] = [:]
    public init() {}
    @discardableResult public func observeConfirmedSelection(_ observer: @escaping @MainActor () -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }
    public func removeObserver(_ token: UUID) { observers.removeValue(forKey: token) }
    public func publishConfirmedSelection() {
        generation &+= 1
        for observer in observers.values { observer() }
    }
}

@MainActor public final class AP05ModelPanelState: ObservableObject {
    @Published public private(set) var cards: [AP05ModelCard] = []
    @Published public var language = "Alle Sprachen"
    @Published public var installedOnly = false
    @Published public private(set) var isWorking = false
    @Published public private(set) var actionFeedback: String?
    @Published public private(set) var installationStatus: AP05ModelInstallationStatus = .idle
    @Published public private(set) var cancelRequestInFlight = false
    @Published public private(set) var preparingModelID: String?
    private let presenter: any AP05ModelPresenting
    private let selectionNotice: AP05ModelSelectionNotice
    private var refreshGeneration: UInt64 = 0
    private var mutationGeneration: UInt64 = 0

    public init(presenter: any AP05ModelPresenting, selectionNotice: AP05ModelSelectionNotice = .init()) {
        self.presenter = presenter
        self.selectionNotice = selectionNotice
    }

    public func refresh() async {
        refreshGeneration &+= 1
        let request = refreshGeneration
        let requestedLanguage = language == "Alle Sprachen" ? nil : language
        let requestedInstalledOnly = installedOnly
        let result = await presenter.cards(language: requestedLanguage, installedOnly: requestedInstalledOnly)
        guard request == refreshGeneration else { return }
        cards = result
    }

    public var installingModelID: String? {
        switch installationStatus {
        case .running(let progress): progress.modelID
        case .cancelling(let modelID): modelID
        default: nil
        }
    }

    public var blocksInstallActions: Bool { isWorking || installingModelID != nil }

    public func refreshInstallationStatus() async {
        do {
            installationStatus = try await presenter.installationStatus()
            if case .running = installationStatus {
                // Keep a requested cancellation latched until the product
                // service observes a different state.
            } else {
                cancelRequestInFlight = false
            }
        } catch {
            actionFeedback = L("Installationsstatus konnte nicht aktualisiert werden.")
        }
    }

    public func select(_ card: AP05ModelCard) async {
        guard !isWorking else { return }
        mutationGeneration &+= 1
        let mutation = mutationGeneration
        let requiresFirstPreparation = card.installed && card.supportsNoAudioFirstPrepare
        isWorking = true
        actionFeedback = nil
        if requiresFirstPreparation { preparingModelID = card.id }
        do {
            if requiresFirstPreparation {
                try await presenter.prepareNoAudioFirstUse(modelID: card.id)
                guard mutation == mutationGeneration else { return }
                preparingModelID = nil
            }
            try await presenter.select(modelID: card.id)
            guard mutation == mutationGeneration else { return }
            selectionNotice.publishConfirmedSelection()
            await refresh()
        } catch {
            guard mutation == mutationGeneration else { return }
            let fallback = preparingModelID == card.id
                ? L("Erstvorbereitung konnte nicht abgeschlossen werden.")
                : L("Modell konnte nicht ausgewählt werden.")
            actionFeedback = productSafeMessage(for: error, fallback: fallback)
        }
        if mutation == mutationGeneration {
            preparingModelID = nil
            isWorking = false
        }
    }
    public func toggleFavorite(_ card: AP05ModelCard) async { await perform(L("Favorit konnte nicht geändert werden.")) { try await self.presenter.setFavorite(modelID: card.id, enabled: !card.favorite) } }
    public func install(_ card: AP05ModelCard) async {
        guard !blocksInstallActions else { return }
        isWorking = true
        actionFeedback = nil
        let operation = Task { try await presenter.install(modelID: card.id) }
        let statusObserver = Task { [weak self] in
            await self?.observeInstallation(modelID: card.id)
        }
        do {
            try await operation.value
            statusObserver.cancel()
            await statusObserver.value
            await refreshInstallationStatus()
            selectionNotice.publishConfirmedSelection()
        } catch {
            statusObserver.cancel()
            await statusObserver.value
            await refreshInstallationStatus()
            if case .failed(_, let message) = installationStatus {
                actionFeedback = AppLocalization.productText(message)
            } else if case .cancelled = installationStatus {
                actionFeedback = L("Download abgebrochen.")
            } else {
                actionFeedback = L("Download konnte nicht gestartet werden.")
            }
        }
        await refresh()
        isWorking = false
    }

    public func cancelInstallation(for card: AP05ModelCard) async {
        guard installingModelID == card.id, !cancelRequestInFlight else { return }
        cancelRequestInFlight = true
        do {
            let admitted = try await presenter.cancelInstall(modelID: card.id)
            if !admitted {
                cancelRequestInFlight = false
                await refreshInstallationStatus()
            }
        } catch {
            cancelRequestInFlight = false
            actionFeedback = L("Download konnte nicht abgebrochen werden.")
            await refreshInstallationStatus()
        }
    }
    public func prepareNoAudioFirstUse(_ card: AP05ModelCard) async { await perform(L("Erstvorbereitung konnte nicht gestartet werden.")) { try await self.presenter.prepareNoAudioFirstUse(modelID: card.id) } }

    private func perform(_ failure: String, action: @escaping @Sendable () async throws -> Void) async {
        guard !isWorking else { return }
        mutationGeneration &+= 1
        let mutation = mutationGeneration
        isWorking = true; actionFeedback = nil
        do {
            try await action()
            selectionNotice.publishConfirmedSelection()
            await refresh()
        } catch {
            guard mutation == mutationGeneration else { return }
            actionFeedback = productSafeMessage(for: error, fallback: failure)
        }
        if mutation == mutationGeneration { isWorking = false }
    }

    private func productSafeMessage(for error: Error, fallback: String) -> String {
        guard let localized = error as? any LocalizedError,
              let message = localized.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty
        else { return fallback }
        return AppLocalization.productText(message)
    }

    private func observeInstallation(modelID: String) async {
        while !Task.isCancelled {
            await refreshInstallationStatus()
            switch installationStatus {
            case .cancelled(let statusModelID), .failed(let statusModelID, _):
                guard statusModelID == modelID else { return }
                return
            case .idle:
                break
            case .running(let progress):
                guard progress.modelID == modelID else { return }
            case .cancelling(let statusModelID):
                guard statusModelID == modelID else { return }
            }
            try? await Task.sleep(for: .milliseconds(180))
        }
    }
}

/// A deterministic desktop-owned note form. It deliberately has no animation
/// and never represents microphone input as a decorative/fake waveform.
private enum AP05NoteMarkResource {
    static let image: NSImage? = {
        guard let url = Bundle.module.url(forResource: "AP05-Klangschrift-NoteMark", withExtension: "svg"),
              url.lastPathComponent == "AP05-Klangschrift-NoteMark.svg",
              !url.isFileURL || url.resolvingSymlinksInPath() == url
        else { return nil }
        return NSImage(contentsOf: url)
    }()
}

public struct AP05NoteMark: View {
    @Environment(\.colorScheme) private var scheme
    public init() {}
    public var body: some View {
        KlangschriftNotePair().fill(Color.semantic(.accent, scheme))
        .frame(width: 52, height: 52)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Klangschrift Notenmarke"))
    }
}

enum ModelComparisonColumn: String, CaseIterable, Identifiable {
    case model = "Modell", language = "Sprache", size = "Größe"
    case quality = "Qualität", speed = "Schnelligkeit", resources = "Ressourcenschonung"
    case duration = "s pro Sprachsekunde", ram = "RAM", status = "Status", favorite = "Favorit"
    var id: String { rawValue }
    static let visibleColumns: [Self] = [.model, .size, .quality, .speed, .resources, .status, .favorite]
    static let spacing: CGFloat = 6
    static let horizontalInset: CGFloat = 8
    static let rowHeight: CGFloat = 32
    /// Minimum content width including the flexible model cell, not sidebar.
    static var minimumTableWidth: CGFloat {
        visibleColumns.reduce(0) { $0 + $1.width } + CGFloat(visibleColumns.count - 1) * spacing + 2 * horizontalInset
    }
    var width: CGFloat {
        switch self {
        case .model: 140
        case .language: 0 // Language is shown with the model name.
        case .size: 50
        case .quality: 82
        case .speed: 62
        case .resources: 68
        case .duration: 46
        case .ram: 48
        case .status: 92
        case .favorite: 24
        }
    }
    var compactTitle: String {
        switch self {
        case .model: L("Modell · Sprache")
        case .speed: L("Tempo")
        case .resources: L("Schonung")
        case .duration: "s/s"
        case .ram: "RAM GB"
        default: L(rawValue)
        }
    }
    var alignment: Alignment {
        switch self {
        case .model, .language: .leading
        case .quality, .speed, .resources, .status, .favorite: .center
        default: .trailing
        }
    }
    func compactText(_ card: AP05ModelCard, catalog: ModelPerformanceCatalog = .bundled) -> String {
        switch self {
        case .model: return ModelComparisonFormatting.modelTitle(card.title, language: card.language)
        case .size: return ModelComparisonFormatting.size(card.downloadBytes)
        default:
            guard let value = number(card, catalog: catalog) else { return "–" }
            return value.formatted(.number.locale(AppLocalization.locale).precision(.fractionLength(0...(self == .duration ? 3 : 2))))
        }
    }
    func number(_ card: AP05ModelCard, catalog: ModelPerformanceCatalog = .bundled) -> Double? {
        let facts = catalog.comparison(for: card.id)
        switch self {
        case .size: return card.downloadBytes > 0 ? Double(card.downloadBytes) : nil
        case .quality: return facts.quality.map(Double.init)
        case .speed: return facts.speed.map(Double.init)
        case .resources: return facts.resources.map(Double.init)
        case .duration: return facts.secondsPerAudioSecond
        case .ram: return facts.ramGB
        case .favorite: return card.supportsFavorites ? (card.favorite ? 1 : 0) : nil
        default: return nil
        }
    }
    func text(_ card: AP05ModelCard, status: String, catalog: ModelPerformanceCatalog = .bundled) -> String {
        switch self {
        case .model: return card.title
        case .language: return L(card.language)
        case .size: return card.downloadBytes > 0 ? AP05ByteFormatter.string(card.downloadBytes) : "–"
        case .status: return status
        case .favorite: return card.supportsFavorites ? (card.favorite ? "★" : "☆") : "–"
        case .quality, .speed, .resources:
            return number(card, catalog: catalog).map { ModelStarRating(score: Int($0)).description() } ?? "–"
        default:
            guard let value = number(card, catalog: catalog) else { return "–" }
            let formatted = value.formatted(.number.locale(AppLocalization.locale).precision(.fractionLength(0...2)))
            return self == .ram ? formatted + " GB" : formatted
        }
    }
    static func accessibilitySummary(_ card: AP05ModelCard, status: String, catalog: ModelPerformanceCatalog = .bundled) -> String {
        (visibleColumns + [.language]).map { "\(L($0.rawValue)): \($0.text(card, status: status, catalog: catalog))" }.joined(separator: ", ")
    }
    static func measuredFirst(_ cards: [AP05ModelCard], catalog: ModelPerformanceCatalog = .bundled) -> [AP05ModelCard] {
        cards.filter { catalog.comparison(for: $0.id).hasReferenceMeasurement } +
        cards.filter { !catalog.comparison(for: $0.id).hasReferenceMeasurement }
    }
    static func sorted(_ cards: [AP05ModelCard], by column: Self, ascending: Bool,
                       catalog: ModelPerformanceCatalog = .bundled, status: (AP05ModelCard) -> String) -> [AP05ModelCard] {
        cards.sorted { left, right in
            let leftMeasured = catalog.comparison(for: left.id).hasReferenceMeasurement
            let rightMeasured = catalog.comparison(for: right.id).hasReferenceMeasurement
            if leftMeasured != rightMeasured { return leftMeasured }
            let order: ComparisonResult
            switch column {
            case .model, .language, .status:
                order = column.text(left, status: status(left), catalog: catalog)
                    .localizedStandardCompare(column.text(right, status: status(right), catalog: catalog))
            default:
                let l = column.number(left, catalog: catalog), r = column.number(right, catalog: catalog)
                // Missing measurements always come last, in either direction.
                if l == nil, r != nil { return false }
                if l != nil, r == nil { return true }
                order = l == r ? .orderedSame : (l ?? 0) < (r ?? 0) ? .orderedAscending : .orderedDescending
            }
            if order == .orderedSame { return left.id < right.id }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }
}

/// Shares one explicit, leading-aligned width between header and rows.
/// Hide optional columns before falling back to a horizontal scroll surface.
struct ModelComparisonLayout {
    let availableWidth: CGFloat
    var scale: CGFloat = 1
    var columns: [ModelComparisonColumn] {
        var result = ModelComparisonColumn.visibleColumns
        for optional in [ModelComparisonColumn.size, .resources, .speed] {
            if minimumWidth(result) > availableWidth { result.removeAll { $0 == optional } }
        }
        return result
    }
    private func minimumWidth(_ columns: [ModelComparisonColumn]) -> CGFloat {
        (columns.reduce(0) { $0 + $1.width } + CGFloat(columns.count - 1) * ModelComparisonColumn.spacing + 2 * ModelComparisonColumn.horizontalInset) * scale
    }
    var hidesMeasurementColumns: Bool { !columns.contains(.speed) || !columns.contains(.resources) }
    var contentWidth: CGFloat { max(availableWidth, minimumWidth(columns)) }
    func width(_ column: ModelComparisonColumn) -> CGFloat {
        guard column == .model else { return column.width * scale }
        let fixed = columns.filter { $0 != .model }.reduce(0) { $0 + $1.width }
        return contentWidth - (fixed + CGFloat(columns.count - 1) * ModelComparisonColumn.spacing + 2 * ModelComparisonColumn.horizontalInset) * scale
    }
}

private struct ModelRatingStars: View {
    let rating: ModelStarRating
    let label: String
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .caption) private var scale: CGFloat = 1
    private var spoken: String { label + ": " + rating.description() }
    var body: some View {
        Group {
            if rating.value != nil {
                HStack(spacing: scale) {
                    ForEach(Array(rating.symbols.enumerated()), id: \.offset) { _, symbol in
                        Image(systemName: symbol).frame(width: 10 * scale)
                    }
                }.font(.caption2).foregroundStyle(Color.semantic(.accent, scheme))
            } else { Text(verbatim: "–").foregroundStyle(Color.semantic(.secondary, scheme)) }
        }
        .help(spoken)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
    }
}

public struct AP05ModelSettingsPanel: View {
    @StateObject private var state: AP05ModelPanelState
    @AppStorage("modelPanelView") private var viewMode = "cards"
    @State private var sortColumn = ModelComparisonColumn.model
    @State private var ascending = true
    @State private var showsMeasurementNotes = false
    @State private var detailID: String?
    @ScaledMetric(relativeTo: .caption) private var comparisonScale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    public init(presenter: any AP05ModelPresenting, selectionNotice: AP05ModelSelectionNotice = .init()) { _state = StateObject(wrappedValue: AP05ModelPanelState(presenter: presenter, selectionNotice: selectionNotice)) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                PageHeader(L("Modelle"))
                Text(L("Wähle dein Diktiermodell oder lade ein neues.")).font(.subheadline).foregroundStyle(Color.semantic(.secondary, scheme))
            }
            Picker(L("Ansicht"), selection: $viewMode) {
                Text(L("Karten")).tag("cards")
                Text(L("Vergleich")).tag("comparison")
            }.pickerStyle(.segmented).frame(maxWidth: 260)
            HStack {
                Picker(L("Sprache"), selection: $state.language) {
                    Text(L("Alle Sprachen")).tag("Alle Sprachen")
                    // Stable catalog/filter keys; only the label is localized.
                    ForEach(["Deutsch", "English", "Mehrsprachig", "Tagalog", "Spanisch", "Japanisch", "Arabisch", "Vietnamesisch", "Mandarin"], id: \.self) { Text(verbatim: L($0)).tag($0) }
                }
                .accessibilityLabel(L("Modellsprache filtern"))
                Toggle(L("Nur installiert"), isOn: $state.installedOnly).toggleStyle(.checkbox)
                Spacer()
                if state.isWorking { ProgressView().controlSize(.small).accessibilityLabel(L("Modellaktion läuft")) }
            }
            .onChange(of: state.language) { _, _ in Task { await state.refresh() } }
            .onChange(of: state.installedOnly) { _, _ in Task { await state.refresh() } }
            if let feedback = state.actionFeedback {
                Label(feedback, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.semantic(.error, scheme))
                    .accessibilityLabel(feedback)
            }
            if viewMode == "comparison" {
                comparisonTable
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(ModelComparisonColumn.measuredFirst(state.cards)) { card in modelRow(card) }
                    }
                }.frame(minHeight: 260, idealHeight: 360)
            }
        }
        .padding(24)
        .frame(minWidth: 0, idealWidth: 720, maxWidth: .infinity)
        .klangschriftTheme()
        .sheet(isPresented: Binding(get: { detailID != nil }, set: { if !$0 { detailID = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text(L("Modelldetails")).font(.title2); Spacer(); Button(L("Schließen")) { detailID = nil } }
                if let card = state.cards.first(where: { $0.id == detailID }) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            modelRow(card, isDetail: true)
                            DisclosureGroup(L("Messwerte")) { measuredStats(card).padding(.top, 8) }
                        }
                    }.frame(maxHeight: 600)
                }
                else { Text(L("Dieses Modell ist im aktuellen Filter nicht sichtbar.")) }
            }.padding(24).frame(width: 600).klangschriftTheme()
        }
        .task {
            await state.refresh()
            await state.refreshInstallationStatus()
        }
        .animation(reduceMotion ? nil : .easeOut(duration: KlangschriftToken.standardMotionSeconds), value: state.cards)
    }

    private var comparisonTable: some View {
        GeometryReader { geometry in
            let layout = ModelComparisonLayout(availableWidth: max(0, geometry.size.width - 15), scale: comparisonScale)
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: ModelComparisonColumn.spacing * comparisonScale) {
                        ForEach(layout.columns) { column in
                            comparisonHeader(column).frame(width: layout.width(column), alignment: column.alignment)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, ModelComparisonColumn.horizontalInset * comparisonScale)
                    .frame(height: ModelComparisonColumn.rowHeight * comparisonScale)
                    Divider()
                    ForEach(ModelComparisonColumn.sorted(state.cards, by: sortColumn, ascending: ascending, status: comparisonStatus)) { card in
                        comparisonRow(card, layout: layout)
                        Divider()
                    }
                    if state.cards.isEmpty { Text(L("Keine passenden Modelle")).padding(16) }
                }
                .frame(width: layout.contentWidth, alignment: .leading)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if layout.hidesMeasurementColumns {
                    Text(L("Fenster breiter ziehen für weitere Messwerte"))
                        .font(.caption)
                        .foregroundStyle(Color.semantic(.secondary, scheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 6)
                }
            }
            .defaultScrollAnchor(.topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: layout.columns) { _, columns in
                if !columns.contains(sortColumn) { sortColumn = .model; ascending = true }
            }
        }.frame(minHeight: 260, idealHeight: 360)
    }

    private func comparisonHeader(_ column: ModelComparisonColumn) -> some View {
        HStack(spacing: 3) {
            Button {
                if sortColumn == column { ascending.toggle() }
                else { sortColumn = column; ascending = true }
            } label: {
                HStack(spacing: 2) {
                    if column == .favorite { Image(systemName: "star") }
                    else { Text(verbatim: column.compactTitle) }
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.caption2).opacity(sortColumn == column ? 1 : 0)
                }.lineLimit(1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L(column.rawValue))
            .accessibilityValue(sortColumn == column ? (ascending ? L("Aufsteigend") : L("Absteigend")) : L("Nicht sortiert"))
            .help(L(column.rawValue))
            if column == .quality {
                Button { showsMeasurementNotes.toggle() } label: {
                    Image(systemName: "info.circle").font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Hinweise zu den Messwerten"))
                .help(L("Hinweise zu den Messwerten"))
                .popover(isPresented: $showsMeasurementNotes) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("Referenzmessungen")).font(.headline)
                        Text(L("Bis zu 5 Sterne, halbe Sterne sind möglich."))
                        Text(L("Qualität: Stichprobe aus 1 Satz je Modell. Sprachen sind nicht direkt vergleichbar."))
                        Text(L("Gemessen unter mittlerer Hintergrundlast; Werte eher konservativ."))
                        Text(L("–: Nicht gemessen oder nicht verfügbar."))
                    }.font(.callout).padding(16).frame(width: 320).klangschriftTheme()
                }
            }
        }
    }

    private func comparisonRow(_ card: AP05ModelCard, layout: ModelComparisonLayout) -> some View {
        return HStack(spacing: ModelComparisonColumn.spacing * comparisonScale) {
            Button { detailID = card.id } label: {
                HStack(spacing: ModelComparisonColumn.spacing * comparisonScale) {
                    ForEach(layout.columns.filter { $0 != .favorite }) { column in
                        Group {
                            if [.quality, .speed, .resources].contains(column) {
                                ModelRatingStars(rating: ModelStarRating(score: column.number(card).map(Int.init)), label: column.compactTitle)
                            } else if column == .status {
                                Text(verbatim: comparisonStatus(card)).help(comparisonStatusDetails(card))
                            } else {
                                Text(verbatim: column.compactText(card)).monospacedDigit()
                                    .help(column == .model ? card.title + " · " + L(card.language) : column.compactText(card))
                            }
                        }
                        .lineLimit(1).truncationMode(.tail)
                        .frame(width: layout.width(column), alignment: column.alignment)
                    }
                }.frame(height: ModelComparisonColumn.rowHeight * comparisonScale).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if card.supportsFavorites {
                Button { Task { await state.toggleFavorite(card) } } label: {
                    Image(systemName: card.favorite ? "star.fill" : "star")
                        .frame(width: layout.width(.favorite), height: ModelComparisonColumn.rowHeight * comparisonScale)
                }.buttonStyle(.borderless).disabled(state.blocksInstallActions)
            } else {
                Text(verbatim: "–").frame(width: layout.width(.favorite))
            }
        }
        .font(.caption)
        .foregroundStyle(Color.semantic(.primary, scheme))
        .padding(.horizontal, ModelComparisonColumn.horizontalInset * comparisonScale)
        .frame(width: layout.contentWidth, height: ModelComparisonColumn.rowHeight * comparisonScale, alignment: .leading)
        .background(card.selected ? Color.semantic(.elevated, scheme) : Color.semantic(.surface, scheme))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: ModelComparisonColumn.accessibilitySummary(card, status: comparisonStatus(card))))
        .accessibilityAction { detailID = card.id }
        .accessibilityActions {
            Button(L("Details")) { detailID = card.id }
            if card.supportsFavorites && !state.blocksInstallActions {
                Button(card.favorite ? L("Favorit entfernen") : L("Als Favorit markieren")) {
                    Task { await state.toggleFavorite(card) }
                }
            }
        }
    }

    private func comparisonStatus(_ card: AP05ModelCard) -> String {
        switch state.installationStatus {
        case .running(let progress) where progress.modelID == card.id:
            return L("Wird geladen")
        case .cancelling(let id) where id == card.id: return L("Abbruch läuft")
        default: return card.selected ? L("Aktiv") : card.installed ? L("Installiert") : L("Nicht geladen")
        }
    }

    private func comparisonStatusDetails(_ card: AP05ModelCard) -> String {
        if case .running(let progress) = state.installationStatus, progress.modelID == card.id {
            return progressLabel(progress)
        }
        return comparisonStatus(card)
    }

    @ViewBuilder private func modelRow(_ card: AP05ModelCard, isDetail: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: card.title).font(.headline)
                        .foregroundStyle(Color.semantic(ModelPerformanceCatalog.bundled.comparison(for: card.id).hasReferenceMeasurement ? .primary : .secondary, scheme))
                    Text(verbatim: card.downloadBytes > 0 ? "\(L(card.language)) · \(AP05ByteFormatter.string(card.downloadBytes))" : L(card.language))
                        .font(.caption).foregroundStyle(Color.semantic(.secondary, scheme))
                }
                Spacer()
                if card.installed { Text(card.selected ? String(L("Aktiv")) : String(L("Installiert"))).font(.caption).foregroundStyle(Color.semantic(.accent, scheme)).padding(5).background(Color.semantic(.elevated, scheme), in: Capsule()) }
                if card.supportsFavorites {
                    Button { Task { await state.toggleFavorite(card) } } label: { Image(systemName: card.favorite ? "star.fill" : "star") }
                        .disabled(state.blocksInstallActions)
                        .buttonStyle(.borderless).accessibilityLabel(card.favorite ? L("Favorit entfernen") : L("Als Favorit markieren"))
                }
            }
            Text(verbatim: AppLocalization.productText(card.description)).font(.caption).foregroundStyle(Color.semantic(.secondary, scheme)).fixedSize(horizontal: false, vertical: true)
            cardRatings(card)
            HStack(spacing: 10) {
                if !isDetail { Button(L("Details")) { detailID = card.id } }
                if card.installed {
                    if !card.selected { Button(L("Als Standard verwenden")) { Task { await state.select(card) } }.disabled(state.blocksInstallActions) }
                    if state.preparingModelID == card.id {
                        Label(L("Ohne Audio wird vorbereitet"), systemImage: "hourglass")
                            .font(.caption)
                            .accessibilityLabel(L("Erstvorbereitung ohne Audio läuft"))
                    }
                    if card.supportsNoAudioFirstPrepare {
                        Button(L("Ohne Audio vorbereiten")) { Task { await state.prepareNoAudioFirstUse(card) } }
                            .disabled(state.blocksInstallActions)
                            .accessibilityHint(L("Bereitet nur dieses installierte Phonon-Modell vor. Es startet keine Aufnahme."))
                    }
                } else {
                    installationActions(for: card)
                }
                Spacer()
            }
            if let message = card.actionMessage, AppLocalization.productText(message) != L("Dieses Modell ist noch nicht installiert.") { Text(verbatim: AppLocalization.productText(message)).font(.caption2).foregroundStyle(Color.semantic(.secondary, scheme)) }
        }
        .padding(18)
        .background(card.selected ? Color.semantic(.elevated, scheme) : Color.semantic(.surface, scheme), in: RoundedRectangle(cornerRadius: KlangschriftToken.cardRadius))
        .overlay { RoundedRectangle(cornerRadius: KlangschriftToken.cardRadius).stroke(card.selected ? Color.semantic(.accent, scheme).opacity(0.8) : Color.semantic(.separator, scheme).opacity(0.6), lineWidth: card.selected ? 1.5 : 1) }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func cardRatings(_ card: AP05ModelCard) -> some View {
        let facts = ModelPerformanceCatalog.bundled.comparison(for: card.id)
        if facts.quality == nil && facts.speed == nil && facts.resources == nil {
            Text(L("Noch nicht bewertet")).font(.caption).foregroundStyle(Color.semantic(.secondary, scheme))
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { cardRatingLabels(facts) }
                VStack(alignment: .leading, spacing: 8) { cardRatingLabels(facts) }
            }
        }
    }

    @ViewBuilder private func cardRatingLabels(_ facts: ModelComparisonMetrics) -> some View {
        ForEach([ModelComparisonColumn.quality, .speed, .resources]) { column in
            HStack(spacing: 6) {
                Text(verbatim: column.compactTitle).font(.caption).foregroundStyle(Color.semantic(.secondary, scheme))
                ModelRatingStars(rating: ModelStarRating(score: column == .quality ? facts.quality : column == .speed ? facts.speed : facts.resources), label: column.compactTitle)
            }
        }
    }

    @ViewBuilder private func measuredStats(_ card: AP05ModelCard) -> some View {
        let facts = ModelPerformanceCatalog.bundled.presentation(for: card.id, coldPrepareMilliseconds: card.coldPrepareMilliseconds, warmInferenceMilliseconds: card.warmInferenceMilliseconds)
        VStack(alignment: .leading, spacing: 5) {
            if let empty = facts.emptyMessage { Text(String(empty)).font(.caption).foregroundStyle(Color.semantic(.secondary, scheme)) }
            if let local = facts.localMeasurement { Text(verbatim: local).font(.caption).foregroundStyle(Color.semantic(.secondary, scheme)) }
            ForEach(facts.metrics, id: \.self) { line in
                Text(verbatim: line).font(.caption).foregroundStyle(Color.semantic(.secondary, scheme))
            }
            if let basis = facts.qualityBasis, !basis.isEmpty {
                Text(L("Qualitätsbasis: %@", String(describing: basis))).font(.caption2).foregroundStyle(Color.semantic(.secondary, scheme))
            }
            if let context = facts.context { Text(verbatim: context).font(.caption2).foregroundStyle(Color.semantic(.secondary, scheme)) }
            if let notes = facts.notes, !notes.isEmpty { Text(verbatim: notes).font(.caption2).foregroundStyle(Color.semantic(.secondary, scheme)) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("Messwerte für %@", String(describing: card.title)))
        .accessibilityValue(facts.measurementAccessibilityValue)
    }

    @ViewBuilder private func installationActions(for card: AP05ModelCard) -> some View {
        switch state.installationStatus {
        case .running(let progress) where progress.modelID == card.id:
            VStack(alignment: .leading, spacing: 5) {
                ProgressView(value: progressFraction(progress))
                Text(progressLabel(progress))
                    .font(.caption)
                    .foregroundStyle(Color.semantic(.secondary, scheme))
            }
            .frame(minWidth: 190, alignment: .leading)
            Button(L("Abbrechen"), role: .cancel) { Task { await state.cancelInstallation(for: card) } }
                .disabled(state.cancelRequestInFlight)
                .accessibilityHint(L("Fordert den Abbruch dieser laufenden Modellinstallation an."))
        case .cancelling(let modelID) where modelID == card.id:
            ProgressView(L("Abbruch wird abgeschlossen …"))
                .controlSize(.small)
                .accessibilityLabel(L("Abbruch wird abgeschlossen"))
        default:
            Button(L("Laden (%@)", String(describing: AP05ByteFormatter.string(card.downloadBytes)))) { Task { await state.install(card) } }
                .disabled(state.blocksInstallActions)
                .accessibilityHint(L("Startet erst nach dieser bewussten Aktion den geprüften Modelldownload."))
        }
    }

    private func progressFraction(_ progress: AP05ModelInstallationProgress) -> Double {
        guard progress.totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(progress.completedBytes) / Double(progress.totalBytes)))
    }

    private func progressLabel(_ progress: AP05ModelInstallationProgress) -> String {
        let phase = switch progress.phase {
        case .downloading: L("Wird geladen")
        case .verifying: L("Wird geprüft")
        case .activating: L("Wird aktiviert")
        }
        let files = progress.totalFiles > 0 ? L(" · Datei %@ von %@", String(describing: progress.completedFiles), String(describing: progress.totalFiles)) : ""
        guard progress.totalBytes > 0 else { return "\(phase)\(files)" }
        let bytes = L("%@ von %@", String(describing: AP05ByteFormatter.string(progress.completedBytes)), String(describing: AP05ByteFormatter.string(progress.totalBytes)))
        let percent = Int((progressFraction(progress) * 100).rounded())
        return "\(phase) · \(bytes) (\(percent) %)\(files)"
    }
}

/// A small dashboard strip uses the real presentation controller. It has an
/// action only when the product controller has been supplied; no preview timer
/// or synthetic waveform is used.
public enum AP05DictationActionFeedback {
    /// This is the finite, actionable product message carried through the
    /// controller's terminal reset. A next visible start action clears it.
    public static func message(for failure: DictationPresentationFailure?) -> String? { failure?.message }
}

@MainActor public final class AP05MicrophoneRecoveryState: ObservableObject {
    @Published public private(set) var status: PermissionStatus?
    private let intent: (any PermissionStatusIntent)?

    public init(intent: (any PermissionStatusIntent)? = nil) { self.intent = intent }
    public var isAvailable: Bool { intent != nil }

    public func refresh() async {
        guard let intent, let snapshot = try? await intent.refresh() else { return }
        status = snapshot[.microphone]
    }

    public func requestAccess() async {
        guard let intent, let snapshot = try? await intent.requestAuthorization(for: .microphone) else { return }
        status = snapshot[.microphone]
    }

    public func openSettings() { intent?.openSettings(for: .microphone) }
}

public struct AP05RecordingStrip: View {
    @ObservedObject private var presentation: DictationPresentationController
    @StateObject private var microphoneRecovery: AP05MicrophoneRecoveryState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    public init(presentation: DictationPresentationController, permissionIntent: (any PermissionStatusIntent)? = nil) {
        self.presentation = presentation
        _microphoneRecovery = StateObject(wrappedValue: AP05MicrophoneRecoveryState(intent: permissionIntent))
    }
    public var body: some View {
        StudioSurface {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: title).font(.headline)
                        Text(verbatim: detail).font(.caption).foregroundStyle(Color.semantic(.secondary, scheme))
                    }
                    Spacer()
                    if presentation.state.phase == .processing { ProgressView().controlSize(.small).accessibilityLabel(L("Verarbeitung läuft")) }
                }
                if presentation.state.phase == .listening {
                    Button { Task { await presentation.stopAndProcess() } } label: { studioMic(symbol: "stop.fill", title: L("Aufnahme beenden")) }
                        .buttonStyle(.plain)
                } else if presentation.state.phase == .processing {
                    Button(L("Verarbeitung abbrechen"), role: .cancel) { Task { await presentation.cancel() } }.buttonStyle(.bordered)
                } else {
                    Button { Task { await presentation.requestStartOrStop() } } label: { studioMic(symbol: "mic.fill", title: L("Diktat starten")) }
                        .buttonStyle(.plain).disabled(presentation.state.phase == .busy)
                }
                if presentation.state.phase == .listening {
                    Button(L("Aufnahme abbrechen"), role: .cancel) { Task { await presentation.cancel() } }.buttonStyle(.borderless)
                }
            }
            if presentation.state.failure == .microphone, microphoneRecovery.isAvailable {
                HStack(spacing: 8) {
                    if microphoneRecovery.status?.canRequest != false {
                        Button(L("Zugriff erlauben")) { Task { await microphoneRecovery.requestAccess() } }
                    }
                    Button(L("Erneut prüfen")) { Task { await microphoneRecovery.refresh() } }
                    if microphoneRecovery.status?.settingsAvailable != false {
                        Button(L("Systemeinstellungen öffnen")) { microphoneRecovery.openSettings() }
                    }
                }
                .font(.caption)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Aufnahmeleiste: %@", String(describing: title)))
        .animation(reduceMotion ? nil : .easeOut(duration: KlangschriftToken.standardMotionSeconds), value: presentation.state.phase)
        .task(id: presentation.state.failure) {
            guard presentation.state.failure == .microphone else { return }
            await microphoneRecovery.refresh()
        }
    }
    private func studioMic(symbol: String, title: String) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(Color.semantic(.separator, scheme), lineWidth: 1).frame(width: 130, height: 130)
                Circle().fill(Color.semantic(.accent, scheme)).frame(width: 106, height: 106)
                Image(systemName: symbol).font(.system(size: 32, weight: .medium)).foregroundStyle(Color.semantic(.canvas, scheme))
            }
            Text(verbatim: title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.semantic(.primary, scheme))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 4).contentShape(Rectangle())
    }
    private var title: String { switch presentation.state.phase { case .listening: L("Aufnahme läuft"); case .processing: L("Wird transkribiert"); case .busy: L("Aktion wird vorbereitet"); case .error: L("Aktion erforderlich"); default: L("Bereit zum Sprechen") } }
    private var detail: String {
        if let feedback = AP05DictationActionFeedback.message(for: presentation.state.failure) {
            return feedback
        }
        return switch presentation.state.phase {
        case .listening: L("Zum Beenden stoppen oder abbrechen.")
        case .processing: L("Der letzte Entwurf bleibt editierbar.")
        case .error: L("Diktat konnte nicht gestartet werden.")
        default: L("Mit der Sprechtaste oder hier beginnen.")
        }
    }
}

@MainActor public final class AP05LatestDraftState: ObservableObject {
    @Published public private(set) var text = ""
    @Published public private(set) var isAvailable = false
    @Published public private(set) var copyFeedback: String?
    private let port: any AP05LatestDraftPresenting
    private var sessionID: UUID?
    private var revision: UInt64?
    private var confirmedDraft: AP05LatestDraft?
    private var refreshGeneration: UInt64 = 0
    private var pendingEdit: String?
    private var editRunning = false
    private var editWaiters: [CheckedContinuation<Void, Never>] = []
    public init(port: any AP05LatestDraftPresenting) { self.port = port }
    public func refresh() async {
        refreshGeneration &+= 1
        let request = refreshGeneration
        let incoming = await port.latestDraft()
        guard request == refreshGeneration else { return }
        guard let incoming else {
            isAvailable = false; text = ""; sessionID = nil; revision = nil; confirmedDraft = nil
            return
        }
        sessionID = incoming.sessionID; revision = incoming.revision; confirmedDraft = incoming; text = incoming.text
        isAvailable = true
    }
    public func edit(_ value: String) async {
        guard isAvailable, revision != nil else { copyFeedback = L("Entwurf ist nicht mehr verfügbar."); await refresh(); return }
        text = value; copyFeedback = nil
        pendingEdit = value
        guard !editRunning else { return }
        editRunning = true
        await drainOwnEdits()
    }
    public func copy() async {
        guard !editRunning, pendingEdit == nil else { copyFeedback = L("Entwurf wird noch aktualisiert."); return }
        guard let revision else { copyFeedback = L("Kein Entwurf zum Kopieren verfügbar."); return }
        switch await port.copyLatestDraft(sessionID: sessionID, revision: revision, text: text) {
        case .success: copyFeedback = L("Entwurf kopiert.")
        case .unavailable: copyFeedback = L("Kein Entwurf zum Kopieren verfügbar.")
        case .failed: copyFeedback = L("Entwurf konnte nicht kopiert werden.")
        }
    }
    /// Test synchronization for the editor's own ordered edit sequence.
    /// It never retries a rejected or foreign revision.
    public func waitForPendingEdits() async {
        guard editRunning || pendingEdit != nil else { return }
        await withCheckedContinuation { editWaiters.append($0) }
    }
    private func drainOwnEdits() async {
        defer {
            editRunning = false
            let waiters = editWaiters; editWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        while let value = pendingEdit {
            pendingEdit = nil
            guard let sessionID, let revision else { copyFeedback = L("Entwurf ist nicht mehr verfügbar."); return }
            let committed = await port.replaceLatestDraft(value, sessionID: sessionID, revision: revision)
            guard let committed,
                  committed.sessionID == sessionID,
                  committed.revision > revision,
                  committed.text == value,
                  ownsRequest(sessionID: sessionID, revision: revision) || ownsExactCommittedDraft(committed) else {
                copyFeedback = L("Entwurf wurde inzwischen ersetzt.")
                pendingEdit = nil
                await refresh()
                return
            }
            let current = await port.latestDraft()
            guard current == committed,
                  ownsRequest(sessionID: sessionID, revision: revision) || ownsExactCommittedDraft(committed) else {
                copyFeedback = L("Entwurf wurde inzwischen ersetzt.")
                pendingEdit = nil
                await refresh()
                return
            }
            self.sessionID = committed.sessionID
            self.revision = committed.revision
            confirmedDraft = committed
            text = committed.text
            isAvailable = true
        }
    }
    private func ownsRequest(sessionID: UUID?, revision: UInt64) -> Bool {
        self.sessionID == sessionID && self.revision == revision
    }
    /// A public refresh may already have adopted this exact own commit while
    /// its reply or confirmation snapshot is still awaited. The confirmed
    /// snapshot is deliberately separate from the optimistic editor text.
    private func ownsExactCommittedDraft(_ draft: AP05LatestDraft) -> Bool {
        isAvailable && confirmedDraft == draft && sessionID == draft.sessionID && revision == draft.revision
    }
}

/// A durable overview editor backed by the current-session recovery/result
/// source. It remains independent of history and the floating rail.
public struct AP05LatestDraftEditor: View {
    @Environment(\.colorScheme) private var scheme
    @StateObject private var state: AP05LatestDraftState
    private let presentationRevision: UInt64
    public init(port: any AP05LatestDraftPresenting, presentationRevision: UInt64) {
        _state = StateObject(wrappedValue: AP05LatestDraftState(port: port))
        self.presentationRevision = presentationRevision
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.isAvailable {
                StudioSurface {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L("Letzter Entwurf")).font(.headline)
                            Spacer()
                            Button { Task { await state.copy() } } label: { Label(L("Kopieren"), systemImage: "doc.on.doc") }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityHint(L("Kopiert den bearbeiteten Entwurf einmalig in die Zwischenablage."))
                        }
                        TextEditor(text: Binding(get: { state.text }, set: { value in Task { await state.edit(value) } }))
                            .scrollContentBackground(.hidden)
                            .background(Color.semantic(.surface, scheme))
                            .frame(minHeight: 110, idealHeight: 145)
                            .accessibilityLabel(L("Letzten Entwurf bearbeiten"))
                        if let feedback = state.copyFeedback { Text(verbatim: feedback).font(.caption).foregroundStyle(Color.semantic(.secondary, scheme)).accessibilityLabel(feedback) }
                    }
                }
            }
        }
        .task(id: presentationRevision) { await state.refresh() }
    }
}

/// Production keeps the established onboarding and four dashboard routes. AP05
/// adds only the focus-neutral action strip above the existing content; it does
/// not create a second recording owner or replace history/dictionary/settings.
public struct AP05DashboardShell: View {
    @ObservedObject private var router: OnboardingRouter
    @ObservedObject private var presentation: DictationPresentationController
    private let modelPresenter: (any AP05ModelPresenting)?
    private let draftPort: (any AP05LatestDraftPresenting)?
    private let permissionIntent: (any PermissionStatusIntent)?
    private let permissionRecovery: PermissionRecoveryViewModel?

    public init(router: OnboardingRouter, presentation: DictationPresentationController, modelPresenter: (any AP05ModelPresenting)? = nil, draftPort: (any AP05LatestDraftPresenting)? = nil, permissionIntent: (any PermissionStatusIntent)? = nil, permissionRecovery: PermissionRecoveryViewModel? = nil) {
        self.router = router; self.presentation = presentation; self.modelPresenter = modelPresenter; self.draftPort = draftPort; self.permissionIntent = permissionIntent; self.permissionRecovery = permissionRecovery
    }

    public var body: some View {
        Group {
            if router.showsDashboard, let dashboard = router.dashboard {
                DashboardRootView(
                    model: dashboard,
                    presentation: presentation,
                    modelPresenter: modelPresenter,
                    draftPort: draftPort,
                    permissionIntent: permissionIntent,
                    permissionRecovery: permissionRecovery
                )
            } else {
                OnboardingRouterView(router: router)
            }
        }
    }

}

/// Keeps the currently selected AP04 model visible without reading or changing
/// legacy MLX preferences. The button is the explicit route to model actions.
public struct AP05SelectedModelSummary: View {
    @Environment(\.colorScheme) private var scheme
    @StateObject private var state: AP05SelectedModelSummaryState
    @ObservedObject private var selectionNotice: AP05ModelSelectionNotice
    private let openModels: () -> Void

    public init(presenter: any AP05ModelPresenting, selectionNotice: AP05ModelSelectionNotice = .init(), openModels: @escaping () -> Void) {
        _state = StateObject(wrappedValue: AP05SelectedModelSummaryState(presenter: presenter, selectionNotice: selectionNotice))
        self.selectionNotice = selectionNotice
        self.openModels = openModels
    }

    public var body: some View {
        Button(action: openModels) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Sprache & Modell")).font(.caption.weight(.semibold))
                Text(verbatim: state.label).font(.caption2).foregroundStyle(Color.semantic(.secondary, scheme)).lineLimit(1)
            }
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(state.accessibilityLabel)
        .accessibilityHint(L("Öffnet die bewusste Modellverwaltung."))
        .task(id: selectionNotice.generation) { await state.refresh() }
    }
}

@MainActor public final class AP05SelectedModelSummaryState: ObservableObject {
    @Published public private(set) var label = L("Modell auswählen")
    private let presenter: any AP05ModelPresenting
    private let selectionNotice: AP05ModelSelectionNotice
    private var refreshGeneration: UInt64 = 0
    public init(presenter: any AP05ModelPresenting, selectionNotice: AP05ModelSelectionNotice = .init()) {
        self.presenter = presenter
        self.selectionNotice = selectionNotice
        _ = selectionNotice.observeConfirmedSelection { [weak self] in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }
    public var accessibilityLabel: String { L("Sprache und Modell: %@", String(describing: label)) }
    public func refresh() async {
        refreshGeneration &+= 1
        let request = refreshGeneration
        let selected = await presenter.cards(language: nil, installedOnly: false).first(where: \.selected)
        guard request == refreshGeneration else { return }
        label = selected.map { "\(L($0.language)) · \($0.title)" } ?? L("Modell auswählen")
    }
}
