import AppKit
import SwiftUI
import KlangschriftDesignSystem
import KlangschriftPresentation

/// Formatting is independent of app names, so an absent target never leaves a
/// leading separator. Dictated content is always rendered verbatim.
enum HistoryRowPresentation {
    static func time(_ date: Date, locale: Locale = AppLocalization.locale, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter(); formatter.locale = locale; formatter.timeZone = timeZone
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    static func duration(_ item: DashboardTranscript) -> String {
        "\(max(0, item.durationSeconds)) s"
    }
    static func metadata(_ item: DashboardTranscript, locale: Locale = AppLocalization.locale, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter(); formatter.locale = locale; formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("dMMMHm")
        return "\(formatter.string(from: item.createdAt)) · \(max(0, item.durationSeconds)) s"
    }
    static func dayTitle(_ day: Date, calendar: Calendar = .current, now: Date = .now, language: AppLanguage = .system) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return L("Heute", language: language) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) { return L("Gestern", language: language) }
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = language.locale; formatter.dateStyle = .medium
        return formatter.string(from: day)
    }
}

struct HistoryDaySections: View {
    let entries: [DashboardTranscript]
    var selection: Binding<Set<UUID>>? = nil
    var language: AppLanguage = .system
    let copy: (DashboardTranscript) -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            ForEach(DayGroupedList.group(entries, by: \.createdAt)) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: HistoryRowPresentation.dayTitle(group.day, language: language))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.semantic(.secondary, scheme))
                        .accessibilityAddTraits(.isHeader)
                    VStack(spacing: 12) {
                        ForEach(group.items) { item in
                            TranscriptHistoryRow(item: item, selection: selection.map { selected in
                                Binding(get: { selected.wrappedValue.contains(item.id) }, set: { value in
                                    if value { selected.wrappedValue.insert(item.id) } else { selected.wrappedValue.remove(item.id) }
                                })
                            }, language: language, copy: { copy(item) })
                        }
                    }
                }.id(group.day)
            }
        }
    }
}

private struct TranscriptHistoryRow: View {
    let item: DashboardTranscript
    let selection: Binding<Bool>?
    let language: AppLanguage
    let copy: () -> Void
    @State private var hovered = false
    @State private var expanded = false
    private enum Focus: Hashable { case text, copy }
    @FocusState private var focus: Focus?
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let selection { Toggle(L("Transkript auswählen", language: language), isOn: selection).labelsHidden().toggleStyle(.checkbox) }
            Text(verbatim: HistoryRowPresentation.time(item.createdAt, locale: language.locale))
                .font(.caption).monospacedDigit().foregroundStyle(Color.semantic(.secondary, scheme))
                .frame(width: 44, alignment: .leading).padding(.top, 3)
            VStack(alignment: .leading, spacing: 7) {
                Button { expanded.toggle() } label: {
                    Text(verbatim: item.text).lineLimit(expanded ? nil : 3)
                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(Color.semantic(.primary, scheme))
                }
                .buttonStyle(.plain).focused($focus, equals: .text)
                .accessibilityHint(Text(expanded ? L("Vorschau einklappen") : L("Vollständiges Transkript anzeigen")))
                Text(verbatim: HistoryRowPresentation.duration(item))
                    .font(.caption2).foregroundStyle(Color.semantic(.secondary, scheme))
            }
            Button(action: copy) { Image(systemName: "doc.on.doc").frame(width: 24, height: 24) }
                .buttonStyle(.plain).foregroundStyle(Color.semantic(.accent, scheme))
                .opacity(hovered || focus != nil ? 1 : 0)
                .focused($focus, equals: .copy)
                .accessibilityLabel(Text(L("Transkript kopieren")))
                .help(L("Kopieren", language: language))
        }
        .padding(14)
        .background(Color.semantic(.surface, scheme), in: RoundedRectangle(cornerRadius: KlangschriftToken.controlRadius))
        .overlay { RoundedRectangle(cornerRadius: KlangschriftToken.controlRadius).stroke(Color.semantic(.separator, scheme).opacity(0.5)) }
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text(L("Kopieren")), copy)
        .contextMenu { Button(action: copy) { Text(L("Kopieren")) } }
    }
}

struct HistoryView: View {
    @ObservedObject var model: DashboardViewModel
    @Binding var focusSearch: Bool
    @FocusState private var focused: Bool
    @State private var selecting = false
    @State private var selectedDay = Date()
    @State private var showingCalendar = false
    @State private var calendarMonth = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: .now)) ?? .now
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                PageHeader(L("Verlauf"))
                Spacer()
                Button { selecting.toggle(); if !selecting { model.selectedHistory = [] } } label: { Text(selecting ? L("Fertig") : L("Auswählen")) }
                    .disabled(model.isHistoryMutationInFlight || (model.history.isEmpty && !selecting))
                Button { showingCalendar.toggle() } label: { Label(L("Springe zu …"), systemImage: "calendar") }
                    .disabled(model.history.isEmpty)
                    .popover(isPresented: $showingCalendar) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L("Tag wählen")).font(.headline)
                            DictationDayCalendar(month: $calendarMonth, selection: $selectedDay, dictationDates: model.history.map(\.createdAt), language: model.appLanguage)
                        }.padding().frame(width: 320)
                    }
                cleanupMenu
            }
            PillSearchField(L("Verlauf durchsuchen"), text: $model.searchText, focus: $focused)
            if selecting {
                HStack {
                    Button { model.selectedHistory = model.selectedHistory == Set(model.history.map(\.id)) ? [] : Set(model.history.map(\.id)) } label: {
                        Text(model.selectedHistory == Set(model.history.map(\.id)) ? L("Auswahl aufheben") : L("Alle auswählen"))
                    }
                    Spacer()
                    Button(role: .destructive) { model.requestDelete() } label: { Text(L("Auswahl löschen")) }
                        .disabled(model.selectedHistory.isEmpty).keyboardShortcut(.delete, modifiers: [])
                }.disabled(model.isHistoryMutationInFlight)
            }
            historyContent.disabled(model.isHistoryMutationInFlight)
            if let notice = model.historyUndoNotice, notice.expiresAt > .now {
                HStack {
                    Text(L("Transkripte gelöscht")).font(.caption)
                    Spacer()
                    Button { Task { await model.undoDelete() } } label: { Text(L("Rückgängig")) }
                        .disabled(model.isHistoryMutationInFlight)
                }
                .padding(12)
                .background(Color.semantic(.accentSurface, scheme), in: RoundedRectangle(cornerRadius: KlangschriftToken.controlRadius))
            }
        }
        .padding(32)
        .task(id: model.searchText) { await model.refreshHistory() }
        .task(id: model.historyUndoNotice?.id) {
            guard let notice = model.historyUndoNotice else { return }
            let remaining = max(0, notice.expiresAt.timeIntervalSinceNow)
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            model.dismissHistoryUndoNotice(id: notice.id)
        }
        .onChange(of: focusSearch, initial: true) { _, value in if value { focused = true; focusSearch = false } }
        .onChange(of: model.searchText) { _, _ in model.selectedHistory = [] }
        .onChange(of: model.history.map(\.id)) { _, ids in model.selectedHistory.formIntersection(ids) }
        .onDisappear { model.selectedHistory = [] }
        .onExitCommand { if selecting { selecting = false; model.selectedHistory = [] } }
    }
    @ViewBuilder private var historyContent: some View {
        switch model.historyState {
        case .idle, .loading: ProgressView { Text(L("Verlauf wird geladen …")) }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView { Text(model.searchText.isEmpty ? L("Noch keine Transkripte") : L("Keine Treffer")) } description: {
                Text(model.searchText.isEmpty ? L("Deine nächsten Diktate erscheinen hier.") : L("Versuche einen anderen Suchbegriff."))
            }
        case .failed(let message):
            VStack(spacing: 12) { Text(verbatim: message); Button { Task { await model.refreshHistory() } } label: { Text(L("Erneut laden")) } }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .content:
            ScrollViewReader { proxy in
                ScrollView {
                    HistoryDaySections(entries: model.history, selection: selecting ? $model.selectedHistory : nil, language: model.appLanguage, copy: model.copyHistory)
                        .padding(.vertical, 4)
                }
                .onChange(of: selectedDay) { _, day in
                    let target = Calendar.current.startOfDay(for: day)
                    guard DayGroupedList.group(model.history, by: \.createdAt).contains(where: { Calendar.current.isDate($0.day, inSameDayAs: target) }) else { return }
                    withAnimation { proxy.scrollTo(target, anchor: .top) }
                    showingCalendar = false
                }
            }
            .scrollContentBackground(.hidden).background(Color.semantic(.canvas, scheme))
        }
    }
    private var cleanupMenu: some View {
        Menu {
            Section {
                Button { model.requestDeleteRange(days: 7) } label: { Text(L("Älter als 7 Tage löschen …")) }
                Button { model.requestDeleteRange(days: 30) } label: { Text(L("Älter als 30 Tage löschen …")) }
                Divider()
                Button(role: .destructive) { model.requestClearAll() } label: { Text(L("Alles löschen …")) }
            } header: { Text(L("Verlauf bereinigen")) }
        } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
        .accessibilityLabel(Text(L("Weitere Verlaufsaktionen")))
        .disabled(model.isHistoryMutationInFlight || model.historyState != .content || model.history.isEmpty)
    }
}

private struct DictationDayCalendar: View {
    @Binding var month: Date; @Binding var selection: Date
    let dictationDates: [Date]; let language: AppLanguage
    private let calendar = Calendar.current
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing: 8) {
            HStack { Button { month = calendar.date(byAdding: .month, value: -1, to: month) ?? month } label: { Image(systemName: "chevron.left") }; Spacer(); Text(month.formatted(.dateTime.year().month(.wide).locale(language.locale))).font(.subheadline.weight(.semibold)); Spacer(); Button { month = calendar.date(byAdding: .month, value: 1, to: month) ?? month } label: { Image(systemName: "chevron.right") } }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
                ForEach(Array(calendar.shortWeekdaySymbols.enumerated()), id: \.offset) { _, day in Text(day.prefix(1)).font(.caption2).foregroundStyle(Color.semantic(.secondary, scheme)) }
                ForEach(days, id: \.self) { day in
                    if let day {
                        let contains = dictationDates.contains { calendar.isDate($0, inSameDayAs: day) }
                        Button { selection = day } label: { VStack(spacing: 1) { Text("\(calendar.component(.day, from: day))"); Circle().fill(contains ? Color.semantic(.accent, scheme) : .clear).frame(width: 4, height: 4) }.frame(width: 30, height: 30) }
                            .buttonStyle(.plain).background(calendar.isDate(day, inSameDayAs: selection) ? Color.semantic(.accentSurface, scheme) : .clear, in: Circle()).accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                    } else { Color.clear.frame(height: 30) }
                }
            }
        }.tint(Color.semantic(.accent, scheme))
    }
    private var days: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: month), let start = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) else { return [] }
        let leading = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading) + range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: start) }
    }
}
