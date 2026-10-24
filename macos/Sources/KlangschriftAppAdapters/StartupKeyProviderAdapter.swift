import Foundation
import Darwin
import LocalAuthentication
import Security

/// Describes the only two keychain reads allowed while reopening an existing
/// encrypted database. Creation is intentionally not part of this boundary.
public enum StartupKeychainAccess: Sendable, Equatable {
    /// Never opens a keychain UI. This makes a locked keychain a bounded,
    /// typed startup result instead of an unbounded UI wait.
    case noninteractiveProbe
    /// May be used only after an explicit user action in the startup UI.
    case explicitUserAccess
}

/// A small fakeable seam around the status-bearing part of SecItemCopyMatching.
/// It intentionally exposes neither a create operation nor a generic query.
public enum StartupKeychainCopyResult: Sendable, Equatable {
    case key(Data)
    case notFound
    case interactionNotAllowed
    case authenticationDenied
    case userCancelled
    case invalidPayload
    case unexpectedStatus(Int32)
}

public protocol StartupKeychainCopying: Sendable {
    func copyExistingDatabaseKey(
        service: String,
        account: String,
        access: StartupKeychainAccess
    ) -> StartupKeychainCopyResult
}

/// Typed, actionable failures for an existing encrypted database. None of
/// these results authorizes a replacement key or a new database.
public enum StartupDatabaseKeyAccessFailure: Error, Sendable, Equatable {
    case locked
    case denied
    case cancelled
    case notFound
    case invalidKey
    case keychainStatus(Int32)
    case legacyInteractionReadStatus(Int32)
    case legacyInteractionDisableStatus(Int32)
    case legacyInteractionRestoreStatus(Int32)
}

public enum StartupLegacyKeychainInteractionRead: Sendable, Equatable { case allowed(Bool), status(Int32) }
public enum StartupLegacyKeychainInteractionWrite: Sendable, Equatable { case success, status(Int32) }
public protocol StartupLegacyKeychainInteractionControlling: Sendable {
    func currentUserInteractionAllowed() -> StartupLegacyKeychainInteractionRead
    func setUserInteractionAllowed(_ allowed: Bool) -> StartupLegacyKeychainInteractionWrite
}

public struct SystemStartupLegacyKeychainInteractionController: StartupLegacyKeychainInteractionControlling {
    public init() {}
    public func currentUserInteractionAllowed() -> StartupLegacyKeychainInteractionRead {
        var allowed: DarwinBoolean = false
        let status = SecKeychainGetUserInteractionAllowed(&allowed)
        return status == errSecSuccess ? .allowed(allowed.boolValue) : .status(Int32(status))
    }
    public func setUserInteractionAllowed(_ allowed: Bool) -> StartupLegacyKeychainInteractionWrite {
        let status = SecKeychainSetUserInteractionAllowed(allowed)
        return status == errSecSuccess ? .success : .status(Int32(status))
    }
}

/// A deliberately read-only startup contract. Composition can first probe
/// without UI and offer `requestExistingRootKeyFromUser()` only from an
/// explicit user action. There is no retry loop and no key creation path.
public protocol StartupExistingDatabaseKeyProviding: Sendable {
    func probeExistingRootKey() throws -> Data
    func requestExistingRootKeyFromUser() throws -> Data
}

public struct StartupKeyProviderAdapter: StartupExistingDatabaseKeyProviding {
    public static let service = "io.github.miggidev618.klangschrift.database-key"
    public static let account = "root-key-v1"

    private let keychain: any StartupKeychainCopying
    private let legacyInteraction: any StartupLegacyKeychainInteractionControlling
    private static let legacyInteractionLock = NSLock()

    public init(keychain: any StartupKeychainCopying = SystemStartupKeychainCopying(), legacyInteraction: any StartupLegacyKeychainInteractionControlling = SystemStartupLegacyKeychainInteractionController()) {
        self.keychain = keychain
        self.legacyInteraction = legacyInteraction
    }

    public func probeExistingRootKey() throws -> Data {
        try readExistingRootKey(access: .noninteractiveProbe)
    }

    public func requestExistingRootKeyFromUser() throws -> Data {
        try readExistingRootKey(access: .explicitUserAccess)
    }

    private func readExistingRootKey(access: StartupKeychainAccess) throws -> Data {
        let result: StartupKeychainCopyResult
        if access == .noninteractiveProbe {
            result = try noninteractiveCopy()
        } else {
            result = keychain.copyExistingDatabaseKey(service: Self.service, account: Self.account, access: access)
        }
        switch result {
        case let .key(key):
            guard key.count == 32 else { throw StartupDatabaseKeyAccessFailure.invalidKey }
            return key
        case .notFound:
            throw StartupDatabaseKeyAccessFailure.notFound
        case .interactionNotAllowed:
            throw StartupDatabaseKeyAccessFailure.locked
        case .authenticationDenied:
            throw StartupDatabaseKeyAccessFailure.denied
        case .userCancelled:
            throw StartupDatabaseKeyAccessFailure.cancelled
        case .invalidPayload:
            throw StartupDatabaseKeyAccessFailure.invalidKey
        case let .unexpectedStatus(status):
            throw StartupDatabaseKeyAccessFailure.keychainStatus(status)
        }
    }
    private func noninteractiveCopy() throws -> StartupKeychainCopyResult {
        Self.legacyInteractionLock.lock()
        defer { Self.legacyInteractionLock.unlock() }
        let previous: Bool
        switch legacyInteraction.currentUserInteractionAllowed() {
        case let .allowed(value): previous = value
        case let .status(status): throw StartupDatabaseKeyAccessFailure.legacyInteractionReadStatus(status)
        }
        switch legacyInteraction.setUserInteractionAllowed(false) {
        case .success: break
        case let .status(status): throw StartupDatabaseKeyAccessFailure.legacyInteractionDisableStatus(status)
        }
        let result = keychain.copyExistingDatabaseKey(service: Self.service, account: Self.account, access: .noninteractiveProbe)
        switch legacyInteraction.setUserInteractionAllowed(previous) {
        case .success: return result
        case let .status(status): throw StartupDatabaseKeyAccessFailure.legacyInteractionRestoreStatus(status)
        }
    }
}

/// The production implementation does one bounded SecItemCopyMatching call.
/// It is never invoked by refresh/probe tests because callers inject the seam.
public struct SystemStartupKeychainCopying: StartupKeychainCopying {
    public init() {}

    public func copyExistingDatabaseKey(
        service: String,
        account: String,
        access: StartupKeychainAccess
    ) -> StartupKeychainCopyResult {
        let authenticationContext = LAContext()
        if access == .noninteractiveProbe {
            authenticationContext.interactionNotAllowed = true
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authenticationContext
        ]
        var rawResult: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &rawResult)
        switch status {
        case errSecSuccess:
            guard let key = rawResult as? Data else { return .invalidPayload }
            return .key(key)
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed:
            return .interactionNotAllowed
        case errSecAuthFailed:
            return .authenticationDenied
        case errSecUserCanceled:
            return .userCancelled
        default:
            return .unexpectedStatus(Int32(status))
        }
    }
}
