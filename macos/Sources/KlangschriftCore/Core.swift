import Foundation
import Darwin

public struct DictationSessionID: Hashable, Sendable, Codable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public enum DictationBusyReason: String, Sendable, Codable { case recording, processing }

public enum DictationError: Error, Equatable, Sendable { case busy(DictationBusyReason), cancelled, unavailable(String) }

public protocol Clock: Sendable { func nowNanoseconds() -> UInt64 }

public struct MonotonicClock: Clock {
    public init() {}
    public func nowNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}

public enum PrivateTemporaryStorage {
    public static func createDirectory(named name: String, in parent: URL) throws -> URL {
        let resolvedParent = parent.standardizedFileURL
        var attributes = stat()
        guard lstat(resolvedParent.path, &attributes) == 0, (attributes.st_mode & S_IFMT) == S_IFDIR, (attributes.st_mode & S_IFMT) != S_IFLNK else { throw DictationError.unavailable("private temp parent unavailable") }
        for _ in 0..<16 {
            let directory = resolvedParent.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
            if mkdir(directory.path, 0o700) == 0 {
                var created = stat()
                guard lstat(directory.path, &created) == 0, (created.st_mode & S_IFMT) == S_IFDIR, created.st_uid == getuid(), (created.st_mode & 0o077) == 0 else { throw DictationError.unavailable("private temp directory insecure") }
                return directory
            }
            if errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        throw DictationError.unavailable("private temp directory collision")
    }
    public static func writeNew(_ data: Data, named name: String, in directory: URL) throws -> URL {
        guard !name.contains("/"), !name.isEmpty else { throw DictationError.unavailable("invalid private temp name") }
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else { throw DictationError.unavailable("private temp directory unavailable") }
        let path = directory.appendingPathComponent(name).path
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
        return URL(fileURLWithPath: path)
    }
}
