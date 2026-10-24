import Foundation

public enum ServiceAvailability: Sendable, Equatable { case ready, unavailable(code: String) }
public protocol ServicePreflightChecking: Sendable { func availability() -> ServiceAvailability }
public protocol LifecycleService: Sendable { func start() async throws; func stop() async }
public enum ServiceContractError: Error, Sendable, Equatable { case unavailable(String), invalidConfiguration(String) }
