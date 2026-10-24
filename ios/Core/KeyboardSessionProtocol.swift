import Foundation

struct KeyboardSession: Codable, Equatable, Sendable {
    enum Command: String, Codable, Sendable { case start, stop, cancel, ended }
    let id: UUID
    let nonce: UUID
    let hostDocumentID: UUID
    var command: Command
    let expiresAt: Date
    var result: String?
    var consumed: Bool

    var isExpired: Bool { Date() >= expiresAt }
}

enum KeyboardSessionProtocol {
    static let maximumLifetime: TimeInterval = 180

    static func begin(hostDocumentID: UUID, command: KeyboardSession.Command = .start, now: Date = .now) -> KeyboardSession {
        KeyboardSession(id: UUID(), nonce: UUID(), hostDocumentID: hostDocumentID, command: command, expiresAt: now.addingTimeInterval(maximumLifetime), result: nil, consumed: false)
    }

    static func attachResult(_ text: String, to session: KeyboardSession, now: Date = .now) -> KeyboardSession? {
        guard !text.isEmpty, now < session.expiresAt, !session.consumed, session.command == .stop else { return nil }
        var updated = session; updated.result = text; updated.command = .ended; return updated
    }

    static func consume(session: KeyboardSession, hostDocumentID: UUID, nonce: UUID, now: Date = .now) -> KeyboardSession? {
        guard now < session.expiresAt, !session.consumed, session.command == .ended, session.hostDocumentID == hostDocumentID, session.nonce == nonce, let result = session.result, !result.isEmpty else { return nil }
        var updated = session; updated.consumed = true; return updated
    }
}
