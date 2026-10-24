import AppIntents
import Foundation

extension Notification.Name {
    static let keyboardActivationRequested = Notification.Name("klangschrift.keyboardActivationRequested")
}

struct ActivateKeyboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Klangschrift-Tastatur aktivieren"
    static let description = IntentDescription("Öffnet Klangschrift und startet eine begrenzte lokale Diktatsitzung für andere Apps.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "klangschrift.keyboardActivationTime")
        await MainActor.run {
            NotificationCenter.default.post(name: .keyboardActivationRequested, object: nil)
        }
        return .result()
    }
}

struct KlangschriftShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ActivateKeyboardIntent(), phrases: ["Diktieren mit \(.applicationName)"], shortTitle: "Tastatur aktivieren", systemImageName: "mic")
    }
}
