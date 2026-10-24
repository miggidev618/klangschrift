import KlangschriftPresentation
import Combine
import SwiftUI
import KlangschriftDesignSystem

/// UI state for the existing permission port. Refreshing is deliberately
/// passive; requesting an OS prompt or opening Settings requires a button tap.
@MainActor public final class PermissionRecoveryViewModel: ObservableObject {
    @Published public private(set) var snapshot = PermissionSnapshot(statuses: [:], generation: 0)
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var isRequestingAuthorization = false
    @Published public var isPresented = false
    @Published public private(set) var shortcutCaptureIssue: ShortcutCaptureRecoveryIssue?

    private let permissions: any PermissionStatusIntent
    private var refreshGeneration: UInt64 = 0
    private var dismissedAutomaticPresentation = false
    private var explicitStatusPresentation = false
    private var lastEffectiveStatusWasReady: Bool?

    public init(permissions: any PermissionStatusIntent) { self.permissions = permissions }

    public var hasUnavailablePermissions: Bool {
        PermissionKind.allCases.contains { snapshot[$0].authorization != .granted }
    }

    /// Called by the production root exactly once for each constructed surface.
    public func startupRefresh() async { await refresh(presentIfUnavailable: true) }

    /// Called from the real SwiftUI active-scene transition. A dismissed sheet
    /// does not reopen merely because macOS still reports the same status.
    public func applicationDidBecomeActive() async { await refresh(presentIfUnavailable: false) }

    public func refresh(presentIfUnavailable: Bool = false) async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isRefreshing = true
        defer { if generation == refreshGeneration { isRefreshing = false } }
        do {
            let next = try await permissions.refresh()
            guard generation == refreshGeneration else { return }
            let wasReady = lastEffectiveStatusWasReady
            snapshot = next
            let isReady = !hasUnavailablePermissions
            lastEffectiveStatusWasReady = isReady
            if isReady, shortcutCaptureIssue != .eventTapUnavailable, !explicitStatusPresentation {
                isPresented = false
                shortcutCaptureIssue = nil
            } else if (presentIfUnavailable && !dismissedAutomaticPresentation) || (wasReady == true && !isReady) {
                // A new effective loss after a known-ready state deserves one
                // fresh recovery surface; an unchanged dismissed loss does not.
                dismissedAutomaticPresentation = false
                isPresented = true
            }
        } catch {
            // Keep the last known effective snapshot. The recovery actions are
            // still available; a transient refresh must not manufacture a grant.
        }
    }

    public func requestAuthorization(for kind: PermissionKind) async {
        guard !isRequestingAuthorization else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isRefreshing = true
        isRequestingAuthorization = true
        defer {
            isRequestingAuthorization = false
            if generation == refreshGeneration { isRefreshing = false }
        }
        do {
            let next = try await permissions.requestAuthorization(for: kind)
            guard generation == refreshGeneration else { return }
            let wasReady = lastEffectiveStatusWasReady
            snapshot = next
            let isReady = !hasUnavailablePermissions
            lastEffectiveStatusWasReady = isReady
            if isReady, shortcutCaptureIssue != .eventTapUnavailable, !explicitStatusPresentation {
                isPresented = false
                shortcutCaptureIssue = nil
            } else if wasReady == true && !isReady {
                dismissedAutomaticPresentation = false
                isPresented = true
            }
        } catch { }
    }

    public func openSettings(for kind: PermissionKind) {
        permissions.openSettings(for: kind)
    }

    public func dismiss() {
        dismissedAutomaticPresentation = true
        explicitStatusPresentation = false
        isPresented = false
        // A user may explicitly acknowledge an event-tap diagnosis. A grant
        // alone is not evidence that the event tap can be created.
        shortcutCaptureIssue = nil
    }

    public func presentForShortcutCaptureFailure(_ issue: ShortcutCaptureRecoveryIssue) async {
        shortcutCaptureIssue = issue
        dismissedAutomaticPresentation = false
        isPresented = true
        await refresh()
    }

    /// Explicit Settings action: it may show recovery, but never triggers an
    /// OS permission prompt by itself.
    public func presentFromUserAction() async {
        dismissedAutomaticPresentation = false
        explicitStatusPresentation = true
        isPresented = true
        await refresh()
    }
}

public enum ShortcutCaptureRecoveryIssue: Equatable, Sendable {
    case inputMonitoring
    case eventTapUnavailable

    public var message: String {
        switch self {
        case .inputMonitoring:
            L("Die globale Shortcut-Aufnahme benötigt eine wirksame Eingabeüberwachung.")
        case .eventTapUnavailable:
            L("Die macOS-Tastenerfassung ist trotz Prüfung derzeit nicht bereit.")
        }
    }
}

/// Presentation only: unknown/unavailable are never described as an OS denial.
enum PermissionDisplay {
    static func status(_ authorization: Authorization) -> String {
        switch authorization {
        case .granted: L("Erlaubt")
        case .denied, .restricted: L("Nicht erlaubt")
        case .unknown: L("Noch nicht geprüft")
        case .unavailable: L("Nicht verfügbar")
        }
    }
    static func statusRole(_ authorization: Authorization) -> KlangschriftPaletteRole {
        authorization == .granted ? .success : .secondary
    }
    static func purpose(_ kind: PermissionKind) -> String {
        switch kind {
        case .microphone: L("Für Aufnahmen erforderlich.")
        case .inputMonitoring: L("Für globale Kurzbefehle.")
        case .accessibility: L("Für Einfügen in andere Apps.")
        }
    }
}

public struct PermissionRecoveryDialog: View {
    @ObservedObject private var model: PermissionRecoveryViewModel
    @Environment(\.colorScheme) private var scheme

    public init(model: PermissionRecoveryViewModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Zugriff prüfen")).font(.title2.bold())
            Text(L("Klangschrift prüft, ob macOS den Zugriff erlaubt."))
                .foregroundStyle(Color.semantic(.secondary, scheme))
            if let issue = model.shortcutCaptureIssue {
                Text(issue.message).foregroundStyle(Color.semantic(.busy, scheme))
            }
            ForEach(PermissionKind.allCases) { kind in
                permissionRow(kind)
            }
            HStack {
                Button(L("Erneut prüfen")) { Task { await model.refresh() } }
                    .buttonStyle(StudioProminentButtonStyle())
                Spacer()
                Button(model.hasUnavailablePermissions ? L("Später") : L("Fertig")) { model.dismiss() }
                    .buttonStyle(StudioProminentButtonStyle())
            }
        }
        .padding(24)
        .frame(minWidth: 820)
        .klangschriftTheme()
        .accessibilityIdentifier("permission-recovery-dialog")
    }

    private func permissionRow(_ kind: PermissionKind) -> some View {
        let status = model.snapshot[kind]
        return HStack(spacing: 16) {
            Text(title(for: kind)).font(.subheadline.weight(.semibold))
                .frame(width: 150, alignment: .leading)
            Text(PermissionDisplay.purpose(kind)).font(.caption)
                .foregroundStyle(Color.semantic(.secondary, scheme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Label(PermissionDisplay.status(status.authorization), systemImage: status.authorization == .granted ? "checkmark.circle.fill" : "minus.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.semantic(PermissionDisplay.statusRole(status.authorization), scheme))
                .frame(width: 132, alignment: .leading)
                .help(status.authorization == .restricted ? L("Durch macOS eingeschränkt") : PermissionDisplay.status(status.authorization))
            VStack(alignment: .trailing, spacing: 8) {
                Button(L("Öffnen")) { model.openSettings(for: kind) }
                    .buttonStyle(StudioProminentButtonStyle())
                    .disabled(!status.settingsAvailable)
                    .accessibilityLabel(L("Systemeinstellungen öffnen") + ": " + title(for: kind))
                if status.canRequest {
                    Button(L("Zugriff anfragen")) { Task { await model.requestAuthorization(for: kind) } }
                        .buttonStyle(.plain).foregroundStyle(Color.semantic(.accent, scheme))
                        .disabled(model.isRequestingAuthorization)
                }
            }.frame(width: 140, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .padding(12)
        .background(Color.semantic(.surface, scheme), in: RoundedRectangle(cornerRadius: KlangschriftToken.controlRadius))
        .overlay { RoundedRectangle(cornerRadius: KlangschriftToken.controlRadius).stroke(Color.semantic(.separator, scheme).opacity(scheme == .dark ? 0.6 : 1)) }
    }

    private func title(for kind: PermissionKind) -> String {
        switch kind { case .microphone: L("Mikrofon"); case .inputMonitoring: L("Eingabeüberwachung"); case .accessibility: L("Bedienungshilfen") }
    }
}
