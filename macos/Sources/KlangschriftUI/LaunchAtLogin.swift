import Foundation
import KlangschriftPresentation

public enum LaunchAtLoginStatus: Equatable, Sendable {
    case enabled, notRegistered, requiresApproval, notFound, unavailable
    public var title: String {
        switch self {
        case .enabled: L("Beim Anmelden aktiv")
        case .notRegistered: L("Beim Anmelden nicht aktiv")
        case .requiresApproval: L("Freigabe in den Systemeinstellungen erforderlich")
        case .notFound: L("Anmeldestart für diese App nicht verfügbar")
        case .unavailable: L("Anmeldestart nicht verfügbar")
        }
    }
}

@MainActor public protocol LaunchAtLoginService {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() async throws
    func openSystemSettings()
}

/// UI previews and callers without a production composition never alter login items.
@MainActor public struct UnavailableLaunchAtLoginService: LaunchAtLoginService {
    public init() {}
    public var status: LaunchAtLoginStatus { .unavailable }
    public func register() throws { throw DashboardIntentError.unavailable }
    public func unregister() async throws { throw DashboardIntentError.unavailable }
    public func openSystemSettings() {}
}
