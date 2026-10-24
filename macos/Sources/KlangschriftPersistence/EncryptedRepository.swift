import Foundation
import CryptoKit
import KlangschriftCore

public struct EncryptedBlob: Sendable, Equatable { public let bytes: Data; public init(bytes: Data) { self.bytes = bytes } }
public enum CryptoFailure: Error, Equatable { case invalidKey, malformed, authenticationFailed }
public struct PersistenceAAD: Sendable, Equatable {
    /// Immutable per-row cryptographic format. It is intentionally independent from SQLite `user_version`.
    public let cryptoVersion: UInt32; public let table: String; public let rowID: UUID; public let column: String
    public init(cryptoVersion: UInt32, table: String, rowID: UUID, column: String) { self.cryptoVersion = cryptoVersion; self.table = table; self.rowID = rowID; self.column = column }
    /// Compatibility initializer for the pre-SQLite in-memory prototype. New storage code must use `cryptoVersion:`.
    public init(schemaVersion: UInt32, table: String, rowID: UUID, column: String) { self.init(cryptoVersion: schemaVersion, table: table, rowID: rowID, column: column) }
    public func encoded() -> Data {
        var result = Data(); var version = cryptoVersion.bigEndian
        withUnsafeBytes(of: &version) { result.append(contentsOf: $0) }
        func append(_ value: Data) {
            var length = UInt32(value.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(value)
        }
        append(Data(table.utf8)); var uuid = rowID.uuid
        withUnsafeBytes(of: &uuid) { result.append(contentsOf: $0) }
        append(Data(column.utf8)); return result
    }
}
public struct FieldCipher: Sendable {
    private let key: SymmetricKey
    public init(keyData: Data) throws {
        guard keyData.count == 32 else { throw CryptoFailure.invalidKey }
        self.key = SymmetricKey(data: keyData)
    }
    public static func freshKey() -> Data { Data(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }) }
    public func seal(_ plaintext: Data, aad: Data) throws -> EncryptedBlob {
        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        guard let combined = box.combined else { throw CryptoFailure.malformed }
        return EncryptedBlob(bytes: combined)
    }
    public func open(_ blob: EncryptedBlob, aad: Data) throws -> Data {
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: blob.bytes), using: key, authenticating: aad) }
        catch { throw CryptoFailure.authenticationFailed }
    }
}
public protocol TranscriptRepository: Sendable { func save(id: DictationSessionID, encryptedText: EncryptedBlob) async; func load(id: DictationSessionID) async -> EncryptedBlob?; func delete(id: DictationSessionID) async }
public actor LocalTranscriptRepository: TranscriptRepository {
    private var rows: [DictationSessionID: EncryptedBlob] = [:]
    public init() {}
    public func save(id: DictationSessionID, encryptedText: EncryptedBlob) { rows[id] = encryptedText }
    public func load(id: DictationSessionID) -> EncryptedBlob? { rows[id] }
    public func delete(id: DictationSessionID) { rows[id] = nil }
}
