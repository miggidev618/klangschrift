import AppKit
import Carbon.HIToolbox
import SwiftUI
import KlangschriftDesignSystem
import KlangschriftPresentation

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "Allgemein", dictation = "Diktat & Modelle", permissions = "Berechtigungen"
    case privacy = "Daten & Datenschutz", about = "Über"
    var id: String { rawValue }
}

struct SettingsPage: View {
    @ObservedObject var model: DashboardViewModel
    let permissionRecovery: PermissionRecoveryViewModel?
    var modelPresenter: (any AP05ModelPresenting)? = nil
    @Environment(\.colorScheme) private var scheme
    @State private var section = SettingsSection.general
    @State private var savedFeedbackDate = Date.now
    @AppStorage("klangschrift.rail-sound.v1") private var railSound = RailSoundPreference.gentle.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(L("Einstellungen"))
            HStack(alignment: .top, spacing: 24) {
                navigation
                Rectangle().fill(Color.semantic(.separator, scheme)).frame(width: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text(L(section.rawValue)).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        sectionContent
                        saveFeedback
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 24)
                }.scrollContentBackground(.hidden)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(24)
        .foregroundStyle(Color.semantic(.primary, scheme))
        .tint(Color.semantic(.accent, scheme))
        .onChange(of: section) { _, next in if next != .dictation { model.cancelShortcutCapture() } }
        .onDisappear { model.cancelShortcutCapture() }
        .onAppear { model.refreshLaunchAtLoginStatus() }
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsSection.allCases) { item in
                Button { section = item } label: {
                    Text(L(item.rawValue)).font(.subheadline.weight(section == item ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
                        .foregroundStyle(Color.semantic(section == item ? .accent : .secondary, scheme))
                        .background(Color.semantic(.accent, scheme).opacity(section == item ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(section == item ? .isSelected : [])
                .accessibilityIdentifier("settings-section-\(item.id)")
            }
            Spacer(minLength: 24)
            Text(AppVersionDisplay.current).font(.caption).foregroundStyle(Color.semantic(.secondary, scheme))
                .textSelection(.enabled).padding(.horizontal, 12)
        }
        .frame(width: 166).frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Einstellungsbereiche"))
    }

    @ViewBuilder private var sectionContent: some View {
        switch section {
        case .general: generalSettings
        case .dictation: dictationSettings
        case .permissions:
            if let permissionRecovery { SettingsPermissionGroup(model: permissionRecovery) }
            else {
                SettingsGroup(L("macOS-Zugriff")) {
                    SettingsRow(L("Berechtigungen"), value: L("Status noch nicht verfügbar"), showsSeparator: false)
                }
            }
        case .privacy: privacySettings
        case .about:
            SettingsGroup(L("Klangschrift")) {
                SettingsRow(L("Version"), value: AppVersionDisplay.value)
                SettingsRow(L("Lokal auf deinem Mac"), value: L("Deine Diktate werden auf diesem Mac verarbeitet."), showsSeparator: false)
            }
        }
    }

    private var generalSettings: some View {
        SettingsGroup(L("App")) {
            SettingsRow(L("App-Sprache"), value: model.appLanguage.title, subtitle: AppLocalization.requiresRestart(for: model.appLanguage.rawValue) ? L("Wird nach Neustart aktiv") : nil) {
                Picker(L("App-Sprache"), selection: Binding(get: { model.appLanguage }, set: { model.setAppLanguage($0) })) {
                    ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
                }.labelsHidden().frame(width: 132)
            }
            SettingsRow(L("Darstellung"), value: L(model.preferences.appearance.title)) {
                Picker(L("Darstellung"), selection: Binding(get: { model.preferences.appearance }, set: { model.setAppearance($0) })) {
                    ForEach(DashboardAppearance.allCases, id: \.self) { Text(L($0.title)).tag($0) }
                }.labelsHidden().frame(width: 132)
            }
            SettingsRow(L("Pille immer anzeigen"), value: L(model.preferences.floatingControlEnabled ? L("Sichtbar") : L("Ausgeblendet"))) {
                Toggle(L("Pille immer anzeigen"), isOn: Binding(get: { model.preferences.floatingControlEnabled }, set: { model.setFloatingControlPreference($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            SettingsRow(L("Start- und Endton"), value: RailSoundPreference(rawValue: railSound)?.title ?? RailSoundPreference.gentle.title) {
                Picker(L("Start- und Endton"), selection: $railSound) {
                    ForEach(RailSoundPreference.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }.labelsHidden().frame(width: 132)
            }
            SettingsRow(L("Beim Anmelden starten"), value: model.launchAtLoginStatus.title, showsSeparator: false) {
                Toggle(L("Beim Anmelden starten"), isOn: Binding(get: { model.preferences.launchAtLoginDesired }, set: { desired in
                    Task { await model.setLaunchAtLoginDesired(desired) }
                }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .disabled(model.isUpdatingLaunchAtLogin || model.preferencesState != .content)
                .accessibilityValue(model.launchAtLoginStatus.title)
            }
            if model.launchAtLoginStatus == .requiresApproval {
                Button(L("Systemeinstellungen öffnen")) { model.openLoginItemSettings() }
            }
            if let error = model.launchAtLoginError {
                Text(verbatim: error).font(.caption).foregroundStyle(Color.semantic(.secondary, scheme))
                    .accessibilityAddTraits(.isStaticText)
            }
            if model.launchAtLoginNeedsRetry {
                Button(L("Anmeldestart erneut versuchen")) { Task { await model.retryLaunchAtLogin() } }
                    .disabled(model.isUpdatingLaunchAtLogin || model.preferencesState != .content)
            }
        }.font(.body.weight(.medium))
    }

    private var dictationSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup(L("Diktieren")) {
                shortcutRow
                if model.preferences.shortcut != nil {
                    SettingsRow(L("Sprechmodus"), value: shortcutModeTitle) {
                        if model.shortcutModeIsFixedToPushToTalk {
                            KeyChip(text: L("Halten"))
                        } else {
                            Picker(L("Sprechmodus"), selection: Binding(get: { model.preferences.shortcut?.typedMode ?? .pushToTalk }, set: { model.setShortcutMode($0) })) {
                                Text(L("Halten zum Sprechen")).tag(ShortcutDraftMode.pushToTalk)
                                Text(L("Doppelt drücken zum Umschalten")).tag(ShortcutDraftMode.toggle)
                                if model.preferences.shortcut?.typedMode == .reinsert {
                                    Text(L("Erneut einfügen")).tag(ShortcutDraftMode.reinsert)
                                }
                            }.labelsHidden().frame(width: 132)
                        }
                    }
                }
                SettingsRow(L("Diktiersprache"), value: L(model.preferences.language.title)) {
                    Picker(L("Diktiersprache"), selection: Binding(get: { model.preferences.language }, set: { model.setLanguage($0) })) {
                        ForEach(DashboardLanguage.allCases, id: \.self) { Text(L($0.title)).tag($0) }
                    }.labelsHidden().frame(width: 132)
                }
                Text(L("Tipp: Feste Sprache wählen – „Automatisch“ kann kurze Sätze falsch erkennen."))
                    .font(.caption).foregroundStyle(Color.semantic(.secondary, scheme))
                    .padding(8)
                    .background(Color.semantic(.accent, scheme).opacity(model.preferences.language == .automatic ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8))
                if model.preferences.language == .automatic {
                    SettingsRow(L("Bevorzugte Sprachen"), value: model.preferredDictationLanguages.compactMap { DashboardLanguage(rawValue: $0)?.title }.joined(separator: ", "), subtitle: L("Für „Automatisch“ mit Whisper: erkennt nur diese Sprachen.")) {
                        Menu(L("Ändern")) {
                            ForEach(DashboardLanguage.allCases.filter { $0 != .automatic }, id: \.self) { language in
                                Toggle(language.title, isOn: Binding(get: { model.preferredDictationLanguages.contains(language.rawValue) }, set: { model.setPreferredDictationLanguage(language.rawValue, enabled: $0) }))
                                    .disabled(model.preferredDictationLanguages.count == 1 && model.preferredDictationLanguages.contains(language.rawValue))
                            }
                        }.frame(width: 132)
                    }
                }
                SettingsRow(L("Mikrofon"), value: L("Systemmikrofon"), showsSeparator: false) {
                    Button(L("In macOS öffnen")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.sound?input")!)
                    }.buttonStyle(.plain).foregroundStyle(Color.semantic(.accent, scheme))
                }
            }.font(.body.weight(.medium))
            SettingsGroup(L("Modell")) {
                if let modelPresenter { SettingsActiveModelRow(presenter: modelPresenter) { model.route = .models } }
                else {
                    SettingsRow(L("Aktives Modell"), value: L("Modell auswählen"), showsSeparator: false) {
                        modelLink
                    }
                }
            }
        }
    }

    private var modelLink: some View {
        Button { model.route = .models } label: { Image(systemName: "chevron.right") }
            .buttonStyle(.plain).foregroundStyle(Color.semantic(.accent, scheme))
            .accessibilityLabel(L("Modelle öffnen"))
    }

    private var shortcutRow: some View {
        SettingsRow(L("Sprechtaste"), value: SettingsShortcutDisplay.name(model.preferences.shortcut), subtitle: shortcutHint) {
            Menu {
                Button(L("Rechte Option (⌥)")) {
                    Task { await model.chooseShortcut(.init(display: "Rechte Option", mode: "Halten", usesFn: false, keyCode: 61, modifiers: 2, typedMode: .pushToTalk, fnProfile: .disabled)) }
                }
                Button(L("Fn")) {
                    Task { await model.chooseShortcut(.init(display: "Fn", mode: "Halten", usesFn: true, keyCode: 63, modifiers: 16, typedMode: .pushToTalk, fnProfile: .functionModifier)) }
                }
                Divider()
                if model.shortcutCaptureGeneration == nil {
                    Button(L("Eigene Taste …")) { Task { await model.beginShortcutCapture() } }
                } else {
                    Button(L("Aufnahme abbrechen")) { model.cancelShortcutCapture() }
                }
            } label: { Text(L(model.shortcutCaptureGeneration == nil ? L("Ändern") : L("Taste drücken …"))) }
            .frame(width: 132)
            .accessibilityLabel(L("Sprechtaste ändern"))
        }
    }

    private var shortcutModeTitle: String {
        switch model.preferences.shortcut?.typedMode ?? .pushToTalk {
        case .pushToTalk: L("Halten zum Sprechen")
        case .toggle: L("Doppelt drücken zum Umschalten")
        case .reinsert: L("Erneut einfügen")
        }
    }

    private var shortcutHint: String? {
        if let failure = model.shortcutCaptureFailure { return failure }
        if model.shortcutCaptureGeneration != nil { return L("Drücke jetzt deine Tastenkombination.") }
        if model.shortcutValidation == .warningUnverifiable { return L("Prüfe, ob diese Taste in anderen Apps frei ist.") }
        return nil
    }

    private var privacySettings: some View {
        SettingsGroup(L("Verlauf")) {
            SettingsRow(L("Diktate speichern"), value: L(model.preferences.historyEnabled ? L("Auf diesem Mac") : L("Aus"))) {
                Toggle(L("Diktate speichern"), isOn: Binding(get: { model.preferences.historyEnabled }, set: { model.setHistoryEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            SettingsRow(L("Aufbewahrung"), value: L(model.preferences.retention.title), showsSeparator: false) {
                Picker(L("Aufbewahrung"), selection: Binding(get: { model.preferences.retention }, set: { model.setRetention($0) })) {
                    ForEach(DashboardRetention.allCases, id: \.self) { Text(L($0.title)).tag($0) }
                }.labelsHidden().frame(width: 132)
            }
        }.font(.body.weight(.medium))
    }

    @ViewBuilder private var saveFeedback: some View {
        HStack(spacing: 8) {
            switch model.preferencesFeedback {
            case .idle: Text(L("Änderungen werden automatisch gespeichert.")).foregroundStyle(Color.semantic(.secondary, scheme))
            case .saving: ProgressView().controlSize(.small); Text(L("Speichern …"))
            case .saved:
                if model.showsSavedFeedback(at: savedFeedbackDate) { Label(L("Gespeichert"), systemImage: "checkmark.circle.fill").foregroundStyle(Color.semantic(.success, scheme)) }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.semantic(.error, scheme))
                Button(L("Erneut versuchen")) { model.retryPreferencesSave() }.buttonStyle(.plain)
            }
        }.font(.caption)
        .task(id: model.preferencesSavedAt) {
            savedFeedbackDate = .now
            guard let savedAt = model.preferencesSavedAt,
                  model.showsSavedFeedback(at: savedFeedbackDate) else { return }
            let remaining = max(0, savedAt.addingTimeInterval(2).timeIntervalSinceNow)
            do {
                try await Task.sleep(for: .seconds(remaining))
            } catch { return }
            guard !Task.isCancelled else { return }
            savedFeedbackDate = .now
        }
    }
}

private struct SettingsActiveModelRow: View {
    @StateObject private var summary: AP05SelectedModelSummaryState
    let openModels: () -> Void
    @Environment(\.colorScheme) private var scheme
    init(presenter: any AP05ModelPresenting, openModels: @escaping () -> Void) {
        _summary = StateObject(wrappedValue: AP05SelectedModelSummaryState(presenter: presenter))
        self.openModels = openModels
    }
    var body: some View {
        SettingsRow(L("Aktives Modell"), value: summary.label, showsSeparator: false) {
            Button(action: openModels) { Image(systemName: "chevron.right") }
                .buttonStyle(.plain).foregroundStyle(Color.semantic(.accent, scheme))
                .accessibilityLabel(L("Modelle öffnen"))
        }.task { await summary.refresh() }
    }
}

private struct SettingsPermissionGroup: View {
    @ObservedObject var model: PermissionRecoveryViewModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        SettingsGroup(L("macOS-Zugriff")) {
            ForEach(PermissionKind.allCases) { kind in
                let granted = model.snapshot[kind].authorization == .granted
                SettingsRow(L(title(kind)), value: L(status(model.snapshot[kind].authorization))) {
                    Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(Color.semantic(granted ? .success : .secondary, scheme))
                        .accessibilityLabel(L(granted ? L("Erlaubt") : L("Prüfung nötig")))
                }
            }
            SettingsRow(L("Zugriff prüfen"), value: L(model.isRefreshing ? L("Wird geprüft …") : L("Berechtigungen in macOS")), showsSeparator: false) {
                Button(L("Prüfen")) { Task { await model.presentFromUserAction() } }
                    .buttonStyle(StudioProminentButtonStyle())
                    .disabled(model.isRefreshing)
            }
        }.font(.body.weight(.medium)).task { await model.refresh() }
    }
    private func title(_ kind: PermissionKind) -> String {
        switch kind { case .microphone: L("Mikrofon"); case .accessibility: L("Bedienungshilfen"); case .inputMonitoring: L("Eingabeüberwachung") }
    }
    private func status(_ authorization: Authorization) -> String {
        switch authorization {
        case .granted: L("Erlaubt")
        case .unknown: L("Noch nicht geprüft")
        case .denied: L("Nicht erlaubt")
        case .restricted: L("Von macOS eingeschränkt")
        case .unavailable: L("Zurzeit nicht verfügbar")
        }
    }
}

/// Display only: the captured keycode/modifiers and validation remain untouched.
enum SettingsShortcutDisplay {
    static func name(_ shortcut: ShortcutDraft?) -> String {
        guard let shortcut else { return L("Nicht festgelegt") }
        guard let code = shortcut.keyCode else { return L("Eigene Taste") }
        let special: [UInt16: String] = [61: L("Rechte Option (⌥)"), 58: L("Linke Option (⌥)"), 63: "Fn", 54: L("Rechte Befehlstaste (⌘)"), 55: L("Befehlstaste (⌘)"), 56: L("Umschalt (⇧)"), 60: L("Rechte Umschalttaste (⇧)"), 59: "Control (⌃)", 62: L("Rechte Control-Taste (⌃)"), 36: "↩", 48: "⇥", 49: L("Leertaste"), 51: "⌫", 53: "Esc", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        let key = special[code] ?? layoutKey(code) ?? L("Eigene Taste")
        let ownModifier: [UInt16: UInt64] = [54: 1, 55: 1, 56: 8, 58: 2, 59: 4, 60: 8, 61: 2, 62: 4, 63: 16]
        let modifiers = shortcut.modifiers & ~(ownModifier[code] ?? 0)
        let prefix = [(UInt64(4), "⌃"), (2, "⌥"), (8, "⇧"), (1, "⌘"), (16, "Fn ")]
            .filter { modifiers & $0.0 != 0 }.map(\.1).joined()
        return prefix + key
    }
    private static func layoutKey(_ code: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKey: UInt32 = 0
        var count = 0
        var characters = [UniChar](repeating: 0, count: 8)
        guard UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKey, characters.count, &count, &characters) == noErr, count > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: Int(count)).uppercased()
    }
}
