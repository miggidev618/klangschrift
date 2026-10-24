import Foundation
import os

/// Explicit post-save handoff between preferences and history. It never saves
/// preferences, schedules a timer, or performs a system action. A failed sweep
/// remains retryable in memory and can be retried without another settings write.
public enum RetentionCoordinationOutcome: Sendable, Equatable {
    case notRequired
    case applied
    case retryRequired
}

public protocol HistoryRetentionSweeping: Sendable {
    func runRetentionSweep(_ retention: HistoryRetention) async throws -> Int
}

public actor SettingsRetentionCoordinator {
    private var pending: HistoryRetention?
    public init() {}

    public func applyCommitted(_ result: PreferencesSaveResult, historyStore: any HistoryRetentionSweeping) async -> RetentionCoordinationOutcome {
        switch result.newRetention {
        case .days7, .days14, .days30, .days90: pending = result.newRetention.value
        case .forever, .none: return .notRequired
        }
        return await retry(historyStore: historyStore)
    }

    public func retry(historyStore: any HistoryRetentionSweeping) async -> RetentionCoordinationOutcome {
        guard let pending else { return .notRequired }
        do { _ = try await historyStore.runRetentionSweep(pending); self.pending = nil; return .applied }
        catch { return .retryRequired }
    }
}

extension EncryptedSQLiteStore: HistoryRetentionSweeping {
    public func runRetentionSweep(_ retention: HistoryRetention) async throws -> Int { try sweepRetention(retention) }
}

/// Launch/resume-only scheduler. It owns no timer, daemon or system action;
/// callers invoke `runIfDue` from the app lifecycle. Missed intervals coalesce
/// to one sweep and failures leave the due state intact for a later retry.
/// A failed `purgeDue` after a due run is swallowed: the schedule state is
/// still persisted and the run remains successful.
public actor PersistedRetentionScheduler {
    private let intervalMs: Int64
    private let clock: any HistoryClock
    public init(intervalMs: Int64 = 24 * 60 * 60 * 1_000, clock: any HistoryClock = SystemHistoryClock()) {
        self.intervalMs = intervalMs; self.clock = clock
    }
    public func runIfDue(retention: HistoryRetention, store: EncryptedSQLiteStore) async throws -> Bool {
        guard intervalMs > 0 else { throw DatabaseFailure.invalidHistoryInput }
        let now = clock.nowMilliseconds(); guard now >= 0 else { throw DatabaseFailure.invalidHistoryInput }
        let prior = try await store.retentionScheduleState()
        guard prior.nextDueMs.map({ $0 <= now }) ?? true else { return false }
        guard retention == .days7 || retention == .days14 || retention == .days30 || retention == .days90 else {
            let next = now.addingReportingOverflow(intervalMs); guard !next.overflow else { throw DatabaseFailure.invalidHistoryInput }
            do { _ = try await store.purgeDue() } catch { os_log("purgeDue failed: %@", error.localizedDescription) }
            try await store.saveRetentionScheduleState(.init(lastSuccessMs: now, nextDueMs: next.partialValue)); return false
        }
        _ = try await store.sweepRetention(retention)
        do { _ = try await store.purgeDue() } catch { os_log("purgeDue failed: %@", error.localizedDescription) }
        let next = now.addingReportingOverflow(intervalMs); guard !next.overflow else { throw DatabaseFailure.invalidHistoryInput }
        try await store.saveRetentionScheduleState(.init(lastSuccessMs: now, nextDueMs: next.partialValue))
        return true
    }
}
