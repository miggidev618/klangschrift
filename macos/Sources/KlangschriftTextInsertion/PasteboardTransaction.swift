import Foundation

/// Binds fully materialized data to the version observed before reading it.
/// The closures also provide a detached test port without touching NSPasteboard.
enum VersionedPasteboardSnapshot {
    static func capture(changeCount: () -> Int, failureDetails: () -> (reason: InsertionLog.SnapshotReason, items: Int, types: Int)? = { nil }, materialize: () -> [PasteboardItemSnapshot]?) -> PasteboardSnapshot? {
        let initialCount = changeCount()
        let materialized = materialize()
        let finalCount = changeCount()
        let stable = finalCount == initialCount
        InsertionLog.record(.flag(.snapshotStable, stable))
        let failure = failureDetails()
        let itemCount = materialized?.count ?? failure?.items ?? 0
        let typeCount = materialized?.reduce(0) { $0 + $1.types.count } ?? failure?.types ?? 0
        if let failure {
            InsertionLog.record(.snapshot(failure.reason, items: itemCount, types: typeCount, countDelta: finalCount &- initialCount))
        }
        InsertionLog.record(.snapshot(stable ? (materialized == nil ? .unavailable : .captured) : .versionChanged, items: itemCount, types: typeCount, countDelta: finalCount &- initialCount))
        guard stable, let items = materialized else { return nil }
        return .init(items: items, changeCount: initialCount)
    }
}

public enum PasteboardTransactionStart: Sendable {
    /// Snapshot/support/change-count validation failed before this request attempted a clipboard write.
    case failedBeforeWrite
    case cancelledBeforeWrite
    /// `writeCurrentHostOnlyTranscript` was called; an adapter may have changed the clipboard even when it returns false.
    case failedAfterPossibleWrite(PasteboardTransaction)
    case ready(PasteboardTransaction)
}

public struct PasteboardTransaction: Sendable {
    public let snapshot: PasteboardSnapshot
    public let transcriptChangeCount: Int

    public static func start(gateway: any PasteboardGateway, transcript: String, maximumItems: Int = 32, maximumBytes: Int = 4_000_000, maximumItemBytes: Int = 1_000_000) -> PasteboardTransactionStart {
        guard !Task.isCancelled else { return .cancelledBeforeWrite }
        guard gateway.supportsAlwaysAllowSnapshot() else {
            InsertionLog.record(.snapshot(.accessDenied, items: 0, types: 0, countDelta: 0))
            return Task.isCancelled ? .cancelledBeforeWrite : .failedBeforeWrite
        }
        // At most one fresh snapshot, and only for an observed version change.
        // Both attempts precede every write; the final CAS check remains intact.
        for attempt in 0..<2 {
            guard !Task.isCancelled else { return .cancelledBeforeWrite }
            let beforeRead = gateway.changeCount()
            let snapshot = gateway.snapshot(maximumItems: maximumItems, maximumBytes: maximumBytes, maximumItemBytes: maximumItemBytes)
            guard !Task.isCancelled else { return .cancelledBeforeWrite }
            let current = gateway.changeCount()
            guard let snapshot else {
                InsertionLog.record(.snapshot(.unavailable, items: 0, types: 0, countDelta: current &- beforeRead))
                if current != beforeRead, attempt == 0 {
                    InsertionLog.record(.step(.snapshotRetry))
                    continue
                }
                return .failedBeforeWrite
            }
            guard snapshot.changeCount == current else {
                InsertionLog.record(.snapshot(.prewriteVersionChanged, items: snapshot.items.count, types: snapshot.items.reduce(0) { $0 + $1.types.count }, countDelta: current &- snapshot.changeCount))
                if attempt == 0 {
                    InsertionLog.record(.step(.snapshotRetry))
                    continue
                }
                return .failedBeforeWrite
            }
            guard !Task.isCancelled else { return .cancelledBeforeWrite }
            let wrote = gateway.writeCurrentHostOnlyTranscript(transcript)
            let transaction = PasteboardTransaction(snapshot: snapshot, transcriptChangeCount: gateway.changeCount())
            guard wrote else { return .failedAfterPossibleWrite(transaction) }
            return .ready(transaction)
        }
        return .failedBeforeWrite
    }

    /// Compatibility entry point for callers that only need a ready transaction.
    public init?(gateway: any PasteboardGateway, transcript: String, maximumItems: Int = 32, maximumBytes: Int = 4_000_000, maximumItemBytes: Int = 1_000_000) {
        guard case let .ready(transaction) = Self.start(gateway: gateway, transcript: transcript, maximumItems: maximumItems, maximumBytes: maximumBytes, maximumItemBytes: maximumItemBytes) else { return nil }
        self = transaction
    }

    private init(snapshot: PasteboardSnapshot, transcriptChangeCount: Int) {
        self.snapshot = snapshot
        self.transcriptChangeCount = transcriptChangeCount
    }

    public func restoreIfUnchanged(gateway: any PasteboardGateway) -> Bool {
        guard gateway.changeCount() == transcriptChangeCount else { return false }
        return gateway.restore(snapshot)
    }
}
