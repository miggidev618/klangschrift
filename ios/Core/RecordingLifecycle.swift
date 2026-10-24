import Foundation

enum RecordingLifecycle: Equatable {
    case idle
    case starting
    case recording

    mutating func begin() throws {
        guard self == .idle else { throw AudioRecorderError.alreadyRecording }
        self = .starting
    }

    mutating func started() { self = .recording }
    mutating func reset() { self = .idle }
}
