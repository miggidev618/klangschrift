import Foundation

/// Bounded history of distinct real PCM captures; render ticks never add samples.
struct MeasuredWaveformHistory {
    static let capacity = 21
    private(set) var samples = Array(repeating: 0.0, count: capacity)
    private var requestID: UUID?
    private var lastSequence: Int64?

    /// The capture meter already scales RMS by six. Recover its amplitude before
    /// applying a -72...-18 dBFS display range; no second linear amplification.
    static func displayLevel(_ meterLevel: Double) -> Double {
        guard meterLevel.isFinite, meterLevel > 0 else { return 0 }
        let amplitude = min(1, meterLevel) / 6
        return min(1, max(0, (20 * log10(amplitude) + 72) / 54))
    }

    @discardableResult
    mutating func record(meterLevel: Double, sequence: Int64?, requestID: UUID?, recording: Bool) -> Bool {
        guard recording, let requestID else { reset(); return false }
        if self.requestID != requestID {
            reset(); self.requestID = requestID
        }
        guard let sequence, sequence > 0, lastSequence.map({ sequence > $0 }) ?? true else { return false }
        lastSequence = sequence
        let measured = Self.displayLevel(meterLevel)
        let previous = samples.last ?? 0
        let smoothed = previous + (measured > previous ? 0.72 : 0.24) * (measured - previous)
        samples.removeFirst(); samples.append(smoothed)
        return true
    }

    mutating func reset() {
        samples = Array(repeating: 0, count: Self.capacity)
        requestID = nil; lastSequence = nil
    }
}
