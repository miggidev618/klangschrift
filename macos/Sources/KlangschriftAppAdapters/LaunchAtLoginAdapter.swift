import ServiceManagement
import KlangschriftUI

@MainActor public struct MainAppLaunchAtLoginService: LaunchAtLoginService {
    public init() {}
    public var status: LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unavailable
        }
    }
    public func register() throws { try SMAppService.mainApp.register() }
    public func unregister() async throws { try await SMAppService.mainApp.unregister() }
    public func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
