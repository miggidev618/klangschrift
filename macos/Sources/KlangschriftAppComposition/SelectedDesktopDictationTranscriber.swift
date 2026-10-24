import Foundation
import KlangschriftAppCore
import KlangschriftCore
import KlangschriftTranscription
import KlangschriftDesktopModels
import KlangschriftDesktopModelProduct

/// One session route shared by normal and onboarding dictation. A desktop
/// failure is never a request to retry through the legacy helper.
public actor SelectedDesktopDictationTranscriber: LocalTranscribing {
    private enum Route { case selecting(UUID), legacy, desktop, readerEnded, cancelled }
    private let desktop: any DesktopModelTranscribing
    private let legacy: any LocalTranscribing
    private let preferredLanguages: @Sendable () -> [String]
    private let recognitionHints: @Sendable () async -> [String]
    private var routes: [DictationSessionID: Route] = [:]
    public init(desktop: any DesktopModelTranscribing, legacy: any LocalTranscribing, preferredLanguages: @escaping @Sendable () -> [String] = { PreferredDictationLanguages.load() }, recognitionHints: @escaping @Sendable () async -> [String] = { [] }) {
        self.desktop = desktop; self.legacy = legacy; self.preferredLanguages = preferredLanguages; self.recognitionHints = recognitionHints
    }
    public func transcribe(audio: URL, session: DictationSessionID, language: String?) async throws -> String {
        guard routes[session] == nil else { throw CancellationError() }
        let languagePreferences = PreferredDictationLanguages.normalized(preferredLanguages())
        let token = UUID(); routes[session] = .selecting(token)
        let selection: String?
        do { selection = try await desktop.selectedModelID() }
        catch {
            if case .selecting(let current)? = routes[session], current == token { routes[session] = .readerEnded }
            throw error
        }
        guard case .selecting(let current)? = routes[session], current == token else { throw CancellationError() }
        try Task.checkCancellation()
        PerfLog.current?.selectModel(catalogID: selection)
        if selection == nil {
            routes[session] = .legacy
            let text = try await legacy.transcribe(audio: audio, session: session, language: language)
            guard case .legacy? = routes[session] else { throw CancellationError() }
            routes[session] = .readerEnded
            return text
        }
        guard let requestedLanguage = DesktopDictationLanguage(rawValue: language ?? "auto") else {
            routes[session] = .readerEnded
            throw DesktopRuntimeError.nativeFailure
        }
        let hints = await recognitionHints()
        guard case .selecting(let current)? = routes[session], current == token else { throw CancellationError() }
        try Task.checkCancellation()
        let prompt = RecognitionHintPrompt.make(hints)
        routes[session] = .desktop
        let text: String
        do {
            text = try await desktop.transcribeSelected(audioFile: audio, language: requestedLanguage, preferredLanguages: languagePreferences, recognitionHintPrompt: prompt)
        } catch DesktopRuntimeError.noSpeech {
            // Only the identity-validated terminal for this live request proves
            // its WAV reader ended. A resident worker may remain warm.
            guard case .desktop? = routes[session] else { throw CancellationError() }
            try Task.checkCancellation()
            routes[session] = .readerEnded
            throw RuntimeTranscriptionFailure.silence
        }
        guard case .desktop? = routes[session] else { throw CancellationError() }
        try Task.checkCancellation()
        routes[session] = .readerEnded
        return text
    }
    public func cancelAndReap() async {
        for session in Array(routes.keys) { _ = await cancelAndReapOutcome(session: session) }
    }
    public func cancelAndReap(session: DictationSessionID) async { _ = await cancelAndReapOutcome(session: session) }
    public func cancelAndReapOutcome(session: DictationSessionID) async -> HelperTerminationOutcome {
        let route = routes[session]; routes[session] = .cancelled
        switch route {
        case .legacy: return await legacy.cancelAndReapOutcome(session: session)
        case .desktop:
            switch await desktop.cancelDemand() {
            case .prepareReaderEnded, .transcriptionReaderEnded: return .reaped
            case .idle, .admissionPending, .readerEndUnknown: return .outcomeUnknown
            }
        case .selecting, .readerEnded, .none: return .reaped
        case .cancelled: return .outcomeUnknown
        }
    }
}
