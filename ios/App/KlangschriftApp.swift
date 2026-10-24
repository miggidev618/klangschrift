import AVFoundation
import Foundation
import SwiftUI

@main
struct KlangschriftApp: App {
    @AppStorage(AppLanguage.defaultsKey, store: UserDefaults(suiteName: "group.io.github.miggidev618.klangschrift")) private var appLanguage = AppLanguage.english.rawValue

    @AppStorage(DictationLanguage.defaultsKey) private var dictationLanguage = DictationLanguage.german.rawValue

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.locale, AppLanguage.current.locale)
                .tint(Color(uiColor: KlangPalette.accent))
                // Keep recording/session objects alive when switching UI language.
                .environment(\.appLanguageCode, appLanguage)
                .onChange(of: dictationLanguage, initial: true) { _, _ in
                    UserDefaults(suiteName: "group.io.github.miggidev618.klangschrift")?.set(
                        DictationLanguage.selected().rawValue, forKey: DictationLanguage.defaultsKey)
                }
                .task { DebugSelfTest.runIfRequested() }
        }
    }
}

#if DEBUG
import MLX

/// Hidden DEBUG-only harness. It accepts only a file name from Documents and writes
/// an inspectable result there; it never changes the product UI or uses networking.
enum DebugSelfTest {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var started = false

    static func runIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        let cpuIndex = arguments.firstIndex(of: "--self-test-cpu")
        let gpuIndex = arguments.firstIndex(of: "--self-test")
        let selected = cpuIndex.map { (index: $0, backend: "cpu") } ?? gpuIndex.map { (index: $0, backend: "cpu") }
        guard let selected, arguments.indices.contains(selected.index + 1) else { return }
        let filename = arguments[selected.index + 1]
        guard filename == URL(fileURLWithPath: filename).lastPathComponent else { return }
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()

        if selected.backend == "cpu" {
            // The legacy MLX default is initialized only after an explicit
            // DEBUG harness request, never during normal product startup.
            Device.setDefault(device: .init(.cpu))
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let startedAt = Date()
            var result: [String: Any] = [
                "mode": "debug-self-test",
                "backend": selected.backend,
                "input_filename": filename,
                "started_at": ISO8601DateFormatter().string(from: startedAt),
            ]
            do {
                let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let input = documents.appendingPathComponent(filename, isDirectory: false)
                let metrics = try audioMetrics(at: input)
                let modelDirectory = Bundle.main.resourceURL!.appendingPathComponent("ParakeetV3Q4")
                let clock = ContinuousClock.now
                let text = try LocalTranscriber(modelDirectory: modelDirectory).transcribe(recording: input)
                let elapsed = clock.duration(to: .now)
                result["status"] = "success"
                result["text"] = text
                result["duration_seconds"] = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                result["input_frames"] = metrics.frames
                result["input_sample_rate"] = metrics.sampleRate
                result["input_rms"] = metrics.rms
                result["mlx_peak_bytes"] = Memory.peakMemory
                result["mlx_active_bytes"] = Memory.activeMemory
                try write(result, to: documents)
            } catch {
                result["status"] = "failure"
                result["error"] = error.localizedDescription
                result["mlx_peak_bytes"] = Memory.peakMemory
                result["mlx_active_bytes"] = Memory.activeMemory
                if let documents = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
                    try? write(result, to: documents)
                }
            }
        }
    }

    private static func audioMetrics(at url: URL) throws -> (frames: AVAudioFramePosition, sampleRate: Double, rms: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else { throw AudioRecorderError.invalidInputFormat }
        let limit = AVAudioFramePosition(RecordingPolicy.maximumSeconds * format.sampleRate)
        guard file.length > 0, file.length <= limit else { throw AudioRecorderError.recordingTooLong }
        let capacity = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw AudioRecorderError.invalidInputFormat }
        try file.read(into: buffer)
        let frames = Int(buffer.frameLength)
        let rms = AudioMeter.rms(samples: buffer.floatChannelData?.pointee, count: frames)
        return (file.length, format.sampleRate, rms)
    }

    private static func write(_ result: [String: Any], to documents: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: documents.appendingPathComponent("klangschrift-self-test.json"), options: .atomic)
    }
}
#else
enum DebugSelfTest { static func runIfRequested() {} }
#endif

private struct AppLanguageCodeKey: EnvironmentKey {
    static let defaultValue = "en"
}
extension EnvironmentValues {
    var appLanguageCode: String {
        get { self[AppLanguageCodeKey.self] }
        set { self[AppLanguageCodeKey.self] = newValue }
    }
}
