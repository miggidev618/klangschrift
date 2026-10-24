import AVFoundation
import Foundation
import UIKit

/// A user-activated microphone session. Idle buffers are discarded immediately.
@MainActor
final class SessionAudioRecorder {
    private let engine = AVAudioEngine()
    private let capture = SessionCapture()
    private var format: AVAudioFormat?
    private var observers: [NSObjectProtocol] = []
    private(set) var active = false
    private var activationEpoch: UUID?
    var ready: Bool { active && engine.isRunning && !AVAudioSession.sharedInstance().currentRoute.inputs.isEmpty }
    var onInterruption: (() -> Void)?
    var progress: RecordingProgress { capture.progress }
    var receivedBufferCount: Int { capture.receivedBufferCount }
    var captureWriteFailed: Bool { capture.writeFailed }

    func activate() throws {
        guard !active else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .allowBluetoothHFP])
            try session.setActive(true)
            let inputFormat = engine.inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0,
                  inputFormat.channelCount > 0 else { throw AudioRecorderError.invalidInputFormat }
            format = inputFormat
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable [capture] buffer, _ in
                capture.write(buffer)
            }
            engine.prepare()
            try engine.start()
            active = true
            let epoch = UUID(); activationEpoch = epoch
            let interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] notification in
                guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      type == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor [weak self] in self?.invalidateIfCurrent(epoch) }
            }
            observers.append(interruption)
            let route = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] notification in
                guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else { return }
                let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
                guard reason == .oldDeviceUnavailable || session.currentRoute.inputs.isEmpty else { return }
                Task { @MainActor [weak self] in self?.invalidateIfCurrent(epoch) }
            }
            observers.append(route)
            for name in [AVAudioSession.mediaServicesWereResetNotification, UIApplication.protectedDataWillBecomeUnavailableNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.invalidateIfCurrent(epoch) }
                })
            }
        } catch {
            end()
            throw error
        }
    }

    private func invalidateIfCurrent(_ epoch: UUID) {
        guard active, activationEpoch == epoch else { return }
        onInterruption?()
    }

    func startClip() throws {
        guard ready, let format else { throw AudioRecorderError.noRecording }
        try capture.start(format: format)
    }

    func finishClip() throws -> URL { try capture.finish() }
    func cancelClip() { capture.cancel() }

    func end() {
        capture.cancel()
        if format != nil { engine.inputNode.removeTap(onBus: 0) }
        engine.stop()
        format = nil
        active = false; activationEpoch = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

