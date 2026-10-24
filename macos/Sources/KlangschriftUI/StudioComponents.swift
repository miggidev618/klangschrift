import KlangschriftPresentation
import SwiftUI
import KlangschriftDesignSystem

/// Small presentation-only Studio vocabulary. It deliberately owns no state
/// and accepts no product ports, so dashboard state machines stay unchanged.
struct StudioSectionHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String?
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: eyebrow).font(.caption.weight(.bold)).tracking(1.1).foregroundStyle(Color.semantic(.accent, scheme))
            Text(verbatim: title).font(.system(.title, design: .default).weight(.bold)).foregroundStyle(Color.semantic(.primary, scheme)).accessibilityAddTraits(.isHeader)
            if let subtitle { Text(verbatim: subtitle).font(.subheadline).foregroundStyle(Color.semantic(.secondary, scheme)) }
        }
    }
}

struct StudioSurface<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(20)
            .background(Color.semantic(.surface, scheme), in: RoundedRectangle(cornerRadius: KlangschriftToken.cardRadius))
            .overlay { RoundedRectangle(cornerRadius: KlangschriftToken.cardRadius).stroke(Color.semantic(.separator, scheme).opacity(scheme == .dark ? 0.6 : 1)) }
    }
}

struct StudioPrimaryButton: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        let label = KlangschriftPalette.onAccent(dark: scheme == .dark)
        configuration.label.font(.subheadline.weight(.semibold)).foregroundStyle(Color(red: label.red, green: label.green, blue: label.blue))
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(Color.semantic(.accent, scheme).opacity(configuration.isPressed && scheme == .dark ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 11))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

extension Color { static func semantic(_ role: KlangschriftPaletteRole, _ scheme: ColorScheme) -> Color { let c = KlangschriftPalette.color(role, dark: scheme == .dark); return Color(red: c.red, green: c.green, blue: c.blue) } }

// WP0 vocabulary: not wired into existing product views yet.
struct StudioCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        StudioSurface { content }
            .foregroundStyle(Color.semantic(.primary, scheme))
            .tint(Color.semantic(.accent, scheme))
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    let content: Content
    @Environment(\.colorScheme) private var scheme
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title).font(.headline).foregroundStyle(Color.semantic(.primary, scheme)).accessibilityAddTraits(.isHeader)
            StudioCard { VStack(alignment: .leading, spacing: 0) { content } }
        }
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    let value: String?
    let subtitle: String?
    let showsSeparator: Bool
    let control: Control
    @Environment(\.colorScheme) private var scheme
    init(_ title: String, value: String? = nil, subtitle: String? = nil, showsSeparator: Bool = true, @ViewBuilder trailing: () -> Control) {
        self.title = title; self.value = value; self.subtitle = subtitle
        self.showsSeparator = showsSeparator; control = trailing()
    }
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title).foregroundStyle(Color.semantic(.primary, scheme))
                if let value { Text(verbatim: value).font(.subheadline).foregroundStyle(Color.semantic(.secondary, scheme)) }
                if let subtitle { Text(verbatim: subtitle).font(.caption).foregroundStyle(Color.semantic(.secondary, scheme)) }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 12)
        .tint(Color.semantic(.accent, scheme))
        .overlay(alignment: .bottom) {
            if showsSeparator { Rectangle().fill(Color.semantic(.separator, scheme)).frame(height: 1) }
        }
    }
}
extension SettingsRow where Control == EmptyView {
    init(_ title: String, value: String? = nil, subtitle: String? = nil, showsSeparator: Bool = true) {
        self.init(title, value: value, subtitle: subtitle, showsSeparator: showsSeparator) { EmptyView() }
    }
}

struct KeyChip: View {
    let text: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Text(verbatim: text).font(.system(.caption, design: .monospaced).weight(.medium))
            .foregroundStyle(Color.semantic(.primary, scheme))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.semantic(.elevated, scheme), in: RoundedRectangle(cornerRadius: KlangschriftToken.controlRadius))
            .overlay { RoundedRectangle(cornerRadius: KlangschriftToken.controlRadius).stroke(Color.semantic(.separator, scheme)) }
            .accessibilityLabel(text)
    }
}

struct StatTile: View {
    let value: String
    let unit: String
    let label: String
    let wrapsInCard: Bool
    init(value: String, unit: String, label: String, wrapsInCard: Bool = true) {
        self.value = value; self.unit = unit; self.label = label; self.wrapsInCard = wrapsInCard
    }
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Group {
            if wrapsInCard { StudioCard { tileContent } }
            else { tileContent }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(value) \(unit)".trimmingCharacters(in: .whitespaces))
    }
    private var tileContent: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(verbatim: value).font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Color.semantic(.primary, scheme))
                    Text(verbatim: unit).font(.caption).foregroundStyle(Color.semantic(.secondary, scheme))
                }
                Text(verbatim: label).font(.caption).foregroundStyle(Color.semantic(.secondary, scheme))
            }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PillSearchField: View {
    let placeholder: String
    @Binding var text: String
    let focus: FocusState<Bool>.Binding?
    @Environment(\.colorScheme) private var scheme
    init(_ placeholder: String, text: Binding<String>, focus: FocusState<Bool>.Binding? = nil) { self.placeholder = placeholder; _text = text; self.focus = focus }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.semantic(.secondary, scheme)).accessibilityHidden(true)
            Group {
                if let focus { TextField(placeholder, text: $text).focused(focus) }
                else { TextField(placeholder, text: $text) }
            }
            .textFieldStyle(.plain).accessibilityLabel(placeholder)
            .foregroundStyle(Color.semantic(.primary, scheme))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.semantic(.surface, scheme), in: Capsule())
        .overlay { Capsule().stroke(Color.semantic(.separator, scheme)) }
        .tint(Color.semantic(.accent, scheme))
    }
}

struct DayGroup<Item>: Identifiable {
    let day: Date
    let items: [Item]
    var id: Date { day }
}

/// Calendar/time-zone aware grouping with newest days/items first. Equal
/// timestamps retain input order. This helper owns no fetching or UI state.
enum DayGroupedList {
    static func group<Item>(_ items: [Item], by date: (Item) -> Date, calendar: Calendar = .current) -> [DayGroup<Item>] {
        let groups = Dictionary(grouping: items.enumerated()) { calendar.startOfDay(for: date($0.element)) }
        return groups.map { day, values in
            DayGroup(day: day, items: values.sorted {
                let left = date($0.element), right = date($1.element)
                return left == right ? $0.offset < $1.offset : left > right
            }.map(\.element))
        }.sorted { $0.day > $1.day }
    }
}

#Preview("StudioCard") { StudioCard { Text(L("Karten-Vorschau")) }.padding() }
#Preview("SettingsGroup") {
    SettingsGroup(L("Allgemein")) {
        SettingsRow(L("App-Sprache"), value: L("System"), showsSeparator: false) { Text("›") }
    }.padding()
}
#Preview("SettingsRow") {
    SettingsRow(L("Verlauf"), value: L("Lokal"), subtitle: L("Vorschau"), showsSeparator: false) { Toggle(L("Aktiv"), isOn: .constant(true)).labelsHidden() }.padding()
}
#Preview("KeyChip") { KeyChip(text: L("⌥ rechts")).padding() }
#Preview("StatTile") { StatTile(value: "12", unit: "min", label: L("Vorschau")).padding() }
#Preview("PillSearchField") { PillSearchField(L("Suchen"), text: .constant("")).padding() }
#Preview("DayGroupedList") {
    VStack {
        ForEach(DayGroupedList.group([Date(timeIntervalSince1970: 1_700_000_000)], by: { $0 })) { group in
            Text(group.day.formatted(date: .abbreviated, time: .omitted))
        }
    }.padding()
}
