import Foundation

/// Content-free boundary between persistence recovery and the separately owned
/// temporary-artifact cleanup service. It intentionally carries no URL, file
/// name, bytes, hash, transcript, audio metadata or diagnostic payload.
public struct OwnedArtifactRecoveryHandoff: Sendable, Equatable {
    public enum Reason: String, Sendable { case cleanupPendingAfterInterruption, userRequestedLocalDataReset }
    public let operationID: UUID
    public let reason: Reason
    public init(operationID: UUID, reason: Reason) { self.operationID = operationID; self.reason = reason }
}

/// Persistence may request handoff but must never enumerate, read, hash, copy,
/// log or delete audio artifacts itself. The future artifact owner validates its
/// own opaque operation identifier and owns every filesystem operation.
public protocol OwnedArtifactRecoveryHandingOff: Sendable {
    func handoffOwnedArtifactRecovery(_ request: OwnedArtifactRecoveryHandoff) async
}
