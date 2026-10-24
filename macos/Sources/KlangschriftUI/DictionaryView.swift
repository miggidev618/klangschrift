import SwiftUI
import UniformTypeIdentifiers
import KlangschriftDesignSystem
import KlangschriftPresentation

public struct DictionaryView: View {
    @ObservedObject var model: DashboardViewModel
    @Environment(\.colorScheme) private var scheme
    @State private var filter: DictionaryFilter = .all
    @State private var importing = false
    @State private var exporting = false
    @State private var transferError: String?
    public init(model: DashboardViewModel) { self.model = model }
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                PageHeader(L("Wörterbuch"))
                Spacer()
                Menu { Button(L("Exportieren")) { exporting = true }; Button(L("Importieren")) { importing = true } } label: { Image(systemName: "ellipsis.circle").frame(width: 24, height: 24) }
                    .fixedSize()
                    .accessibilityLabel(L("Weitere Wörterbuchaktionen"))
                Button { model.dictionaryDraft = .init(source: "", replacement: "") } label: { Label(L("Eintrag"), systemImage: "plus") }.buttonStyle(StudioProminentButtonStyle()).accessibilityLabel(L("Eintrag hinzufügen"))
            }
            HStack(spacing: 10) {
                PillSearchField(L("Wörterbuch durchsuchen"), text: $model.dictionarySearch)
                Text("\(filteredItems.count)").font(.caption.weight(.semibold)).foregroundStyle(Color.semantic(.secondary, scheme))
            }
            Picker(L("Wörterbuch filtern"), selection: $filter) {
                ForEach(DictionaryFilter.allCases) { Text(L($0.title)).tag($0) }
            }.pickerStyle(.segmented)
            switch model.dictionaryState {
            case .loading: ProgressView(L("Wörterbuch wird geladen …"))
            case .failed(let message):
                ContentUnavailableView(L("Wörterbuch nicht verfügbar"), systemImage: "exclamationmark.triangle", description: Text(message))
            default:
                if model.dictionary.isEmpty {
                    StudioCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("Deine Begriffe, richtig geschrieben")).font(.headline)
                            Text(L("Lege fest, wie gesprochene Begriffe im Text erscheinen.")).foregroundStyle(Color.semantic(.secondary, scheme))
                            Text(L("Zum Beispiel: Beispielwort → gewünschte Schreibweise")).font(.subheadline)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if filteredItems.isEmpty {
                    Text(L("Keine passenden Einträge")).foregroundStyle(Color.semantic(.secondary, scheme))
                } else {
                    List(filteredItems) { item in
                        DictionaryRow(item: item, model: model)
                            .listRowBackground(Color.semantic(.surface, scheme))
                            .listRowSeparatorTint(Color.semantic(.separator, scheme))
                    }
                    .scrollContentBackground(.hidden)
                    .background(Color.semantic(.canvas, scheme))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(32)
        .tint(Color.semantic(.accent, scheme))
        .foregroundStyle(Color.semantic(.primary, scheme))
        .background(Color.semantic(.canvas, scheme))
        .sheet(item: $model.dictionaryDraft) { DictionaryEditor(item: $0, model: model) }
        .alert(L("Wörterbucheintrag löschen?"), isPresented: $model.showDictionaryDelete) {
            Button(L("Abbrechen"), role: .cancel) {}
            Button(L("Löschen"), role: .destructive) { Task { await model.deleteSelectedDictionary() } }
        }
        .fileExporter(isPresented: $exporting, document: DictionaryTransferDocument(items: model.dictionary), contentType: .json, defaultFilename: "Klangschrift-Woerterbuch") { result in
            if case .failure = result { transferError = L("Export konnte nicht erstellt werden.") }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            Task { @MainActor in
                do {
                    let url = try result.get()
                    guard url.startAccessingSecurityScopedResource() else { throw DictionaryTransferError.invalid }
                    defer { url.stopAccessingSecurityScopedResource() }
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    guard values.isRegularFile == true, (values.fileSize ?? 0) > 0, (values.fileSize ?? 0) <= 512 * 1_024 else { throw DictionaryTransferError.invalid }
                    let document = try DictionaryTransferDocument(data: Data(contentsOf: url))
                    guard document.items.count <= 500, document.items.allSatisfy(\.isValid) else { throw DictionaryTransferError.invalid }
                    for item in document.items { await model.saveDictionary(item.asDashboardItem()) }
                    if model.dictionaryEditError != nil { throw DictionaryTransferError.invalid }
                    await model.refreshDictionary()
                } catch { transferError = L("Import konnte nicht gelesen werden.") }
            }
        }
        .alert(L("Wörterbuch"), isPresented: Binding(get: { transferError != nil }, set: { if !$0 { transferError = nil } })) { Button(L("OK")) {} } message: { Text(transferError ?? "") }
    }
    private var filteredItems: [DashboardDictionaryItem] {
        model.filteredDictionary.filter { filter == .all || (filter == .replacements && $0.kind == .replacement) || (filter == .hints && $0.kind == .recognitionHint) }
    }
}

private enum DictionaryTransferError: Error { case invalid }
private struct DictionaryTransferItem: Codable {
    let kind: DashboardDictionaryKind; let source: String; let replacement: String; let recognitionHint: String?; let enabled: Bool; let matchMode: DashboardDictionaryMatchMode; let caseSensitive: Bool
    init(_ item: DashboardDictionaryItem) { kind = item.kind; source = item.source; replacement = item.replacement; recognitionHint = item.recognitionHint; enabled = item.enabled; matchMode = item.matchMode; caseSensitive = item.caseSensitive }
    var isValid: Bool {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch kind { case .replacement: return !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && recognitionHint == nil; case .recognitionHint: return replacement.isEmpty && !(recognitionHint ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    func asDashboardItem() -> DashboardDictionaryItem { .init(kind: kind, source: source, replacement: replacement, recognitionHint: recognitionHint, enabled: enabled, matchMode: matchMode, caseSensitive: caseSensitive) }
}
private struct DictionaryTransferDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let items: [DictionaryTransferItem]
    init(items: [DashboardDictionaryItem]) { self.items = items.map(DictionaryTransferItem.init) }
    init(configuration: ReadConfiguration) throws { try self.init(data: configuration.file.regularFileContents ?? Data()) }
    init(data: Data) throws { items = try JSONDecoder().decode([DictionaryTransferItem].self, from: data) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { .init(regularFileWithContents: try JSONEncoder().encode(items)) }
}

private enum DictionaryFilter: String, CaseIterable, Identifiable { case all, replacements, hints
    var id: String { rawValue }
    var title: String { switch self { case .all: "Alle"; case .replacements: "Ersetzungen"; case .hints: "Hinweise" } }
}

private struct DictionaryRow: View {
    @Environment(\.colorScheme) private var scheme
    let item: DashboardDictionaryItem
    @ObservedObject var model: DashboardViewModel
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(item.enabled ? Color.semantic(.success, scheme) : Color.semantic(.secondary, scheme)).frame(width: 8, height: 8).accessibilityLabel(item.enabled ? L("Aktiv") : L("Inaktiv"))
            Toggle(L("Eintrag aktiv"), isOn: Binding(get: { item.enabled }, set: { _ in Task { await model.toggleDictionary(item) } }))
                .labelsHidden().toggleStyle(.checkbox).accessibilityLabel(L("Eintrag aktiv: %@", String(describing: item.source)))
            Text(verbatim: item.source)
            Image(systemName: "arrow.right").foregroundStyle(Color.semantic(.secondary, scheme)).accessibilityHidden(true)
            Text(verbatim: item.kind == .replacement ? item.replacement : (item.recognitionHint ?? L("Hinweis ohne Erkennungswirkung")))
                .foregroundStyle(item.kind == .recognitionHint ? Color.semantic(.accent, scheme) : Color.semantic(.primary, scheme))
            Spacer()
            Button(L("Bearbeiten"), systemImage: "pencil") { model.dictionaryDraft = item }.labelStyle(.iconOnly).buttonStyle(.borderless)
            Button(L("Löschen"), systemImage: "trash", role: .destructive) { delete() }.labelStyle(.iconOnly).buttonStyle(.borderless)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button(L("Bearbeiten")) { model.dictionaryDraft = item }
            Button(L("Nach oben")) { Task { await model.moveDictionary(item, up: true) } }
            Button(L("Nach unten")) { Task { await model.moveDictionary(item, up: false) } }
            Button(L("Löschen"), role: .destructive) { delete() }
        }
        .accessibilityAction(named: Text(L("Bearbeiten"))) { model.dictionaryDraft = item }
        .accessibilityAction(named: Text(L("Löschen"))) { delete() }
    }
    private func delete() { model.selectedDictionaryForDeletion = item; model.showDictionaryDelete = true }
}

private struct DictionaryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    let item: DashboardDictionaryItem
    @ObservedObject var model: DashboardViewModel
    @State private var source = ""
    @State private var replacement = ""
    @State private var kind: DashboardDictionaryKind = .replacement
    @State private var wholeWord = false
    @State private var caseSensitive = false
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L("Wörterbucheintrag")).font(.title2.weight(.semibold))
            Picker(L("Typ"), selection: $kind) { Text(L("Ersetzung")).tag(DashboardDictionaryKind.replacement); Text(L("Hinweis")).tag(DashboardDictionaryKind.recognitionHint) }.pickerStyle(.segmented)
            Text(kind == .replacement ? L("So sprichst du es → So steht es im Text") : L("Hinweise haben noch keine Erkennungswirkung.")).foregroundStyle(kind == .replacement ? Color.semantic(.secondary, scheme) : Color.semantic(.accent, scheme))
            field(L("Begriff"), text: $source)
            field(kind == .replacement ? L("Ersetzung") : L("Kontext"), text: $replacement)
            Toggle(L("Ganzes Wort"), isOn: $wholeWord)
            Toggle(L("Gross-/Kleinschreibung beachten"), isOn: $caseSensitive)
            StudioCard { VStack(alignment: .leading, spacing: 4) { Text(L("Vorschau")).font(.caption.weight(.semibold)); Text(kind == .replacement ? "\(source) → \(replacement)" : "\(source): \(replacement)").foregroundStyle(kind == .replacement ? Color.semantic(.primary, scheme) : Color.semantic(.accent, scheme)) } }
            if let message = model.dictionaryEditError { Text(verbatim: message).foregroundStyle(Color.semantic(.error, scheme)) }
            HStack {
                Button(L("Abbrechen")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("Speichern")) {
                    saving = true
                    Task {
                        var updated = item
                        updated.source = source
                        updated.replacement = kind == .replacement ? replacement : ""
                        updated.kind = kind
                        updated.recognitionHint = kind == .recognitionHint ? replacement : nil
                        updated.matchMode = wholeWord ? .wholeWord : .literal
                        updated.caseSensitive = caseSensitive
                        await model.saveDictionary(updated)
                        saving = false
                        if model.dictionaryEditError != nil { return }
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            }.disabled(saving)
        }
        .padding(24).frame(width: 420).klangschriftTheme()
        .onAppear { model.dictionaryEditError = nil; source = item.source; replacement = item.replacement; kind = item.kind; wholeWord = item.matchMode == .wholeWord; caseSensitive = item.caseSensitive }
    }
    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text).textFieldStyle(.plain).padding(12)
            .background(Color.semantic(.surface, scheme), in: RoundedRectangle(cornerRadius: KlangschriftToken.controlRadius))
            .overlay { RoundedRectangle(cornerRadius: KlangschriftToken.controlRadius).stroke(Color.semantic(.separator, scheme)) }
    }
}
