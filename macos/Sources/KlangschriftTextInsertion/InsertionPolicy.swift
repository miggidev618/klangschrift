import Foundation
import KlangschriftCore

public enum EditableTargetClassification: String, Sendable { case editable, secure, unknown, notEditable }
/// Opaque identity supplied by an Accessibility adapter from the current AXUIElement; not a user-controlled string.
public struct AXElementIdentity: Hashable, Sendable { public let opaqueToken: UInt64; public init(opaqueToken: UInt64) { self.opaqueToken = opaqueToken } }
public struct FocusLease: Equatable, Sendable {
    public let processID: Int32; public let bundleIdentifier: String?; public let element: AXElementIdentity; public let issuedAtNanoseconds: UInt64
    public init(processID: Int32, bundleIdentifier: String?, element: AXElementIdentity, issuedAtNanoseconds: UInt64) { self.processID = processID; self.bundleIdentifier = bundleIdentifier; self.element = element; self.issuedAtNanoseconds = issuedAtNanoseconds }
}
public struct CurrentFocus: Equatable, Sendable {
    public let processID: Int32; public let bundleIdentifier: String?; public let element: AXElementIdentity; public let classification: EditableTargetClassification
    public init(processID: Int32, bundleIdentifier: String?, element: AXElementIdentity, classification: EditableTargetClassification) { self.processID = processID; self.bundleIdentifier = bundleIdentifier; self.element = element; self.classification = classification }
}
/// Production code must implement this with AXUIElement identity; tests may supply stable opaque tokens.
public protocol AccessibilityFocusAdapter: Sendable { func readCurrentFocus() -> CurrentFocus? }
public enum InsertionDecision: Equatable, Sendable { case accessibility; case clipboardFallback; case recovery(reason: RecoveryReason) }
public enum RecoveryReason: String, Sendable { case protectedField, unknownTarget, focusDrift, expiredLease, targetNotEditable, accessibilityUnavailable, clipboardUnsafe, cancelled }
public struct InsertionPolicy: Sendable {
    public let maximumLeaseAgeNanoseconds: UInt64
    public init(maximumLeaseAgeNanoseconds: UInt64 = 5_000_000_000) {
        self.maximumLeaseAgeNanoseconds = maximumLeaseAgeNanoseconds
    }
    private func validBundleIdentifier(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value == value.trimmingCharacters(in: .whitespacesAndNewlines), value.contains("."), value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return value
    }
    /// Validates the long-lived recording anchor. Its timestamp is intentionally not used here.
    public func matchesAnchor(_ anchor: FocusLease, current: CurrentFocus) -> Bool {
        guard let anchoredBundle = validBundleIdentifier(anchor.bundleIdentifier), let currentBundle = validBundleIdentifier(current.bundleIdentifier) else { return false }
        return anchor.processID == current.processID && anchoredBundle == currentBundle && anchor.element == current.element
    }
    public func decide(lease: FocusLease, current: CurrentFocus, nowNanoseconds: UInt64, accessibilityAvailable: Bool, clipboardMaterializable: Bool) -> InsertionDecision {
        guard nowNanoseconds >= lease.issuedAtNanoseconds, nowNanoseconds - lease.issuedAtNanoseconds <= maximumLeaseAgeNanoseconds else { return .recovery(reason: .expiredLease) }
        guard matchesAnchor(lease, current: current) else { return .recovery(reason: .focusDrift) }
        switch current.classification {
        case .secure: return .recovery(reason: .protectedField)
        case .unknown: return .recovery(reason: .unknownTarget)
        case .notEditable: return .recovery(reason: .targetNotEditable)
        case .editable: return accessibilityAvailable ? .accessibility : clipboardMaterializable ? .clipboardFallback : .recovery(reason: .clipboardUnsafe)
        }
    }
}
