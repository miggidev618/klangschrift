import Darwin
import Foundation
import KlangschriftDesktopNativeModels
import KlangschriftDesktopModels
import KlangschriftCore

private struct Arguments {
    let modelID: String
    let modelDirectory: URL
    let audioFile: URL?
    let jobID: String?
    let generation: UInt64?
    let serve: Bool
    let language: DesktopDictationLanguage
    let preferredLanguages: [String]

    init() throws {
        let values = Array(CommandLine.arguments.dropFirst())
        func value(_ name: String) -> String? {
            guard let index = values.firstIndex(of: name), values.indices.contains(index + 1) else { return nil }
            return values[index + 1]
        }
        guard let modelID = value("--model-id"), let modelDirectory = value("--model-directory"), !modelID.isEmpty else { throw Exit.invalidArguments }
        guard let language = DesktopDictationLanguage(rawValue: value("--language") ?? "auto") else { throw Exit.invalidArguments }
        self.language = language
        self.preferredLanguages = PreferredDictationLanguages.normalized(value("--preferred-languages")?.components(separatedBy: ",") ?? PreferredDictationLanguages.defaults)
        self.modelID = modelID
        self.modelDirectory = URL(fileURLWithPath: modelDirectory, isDirectory: true)
        self.serve = values.contains("--serve")
        let audio = value("--audio-file")
        let job = value("--job-id")
        let generation = value("--generation").flatMap(UInt64.init)
        guard self.serve || (audio != nil && job != nil && generation != nil) else { throw Exit.invalidArguments }
        self.audioFile = audio.map(URL.init(fileURLWithPath:))
        self.jobID = job
        self.generation = generation
    }
}

private enum Exit: Error { case invalidArguments, failed }

private struct ResultLine: Encodable {
    let jobID: String
    let generation: UInt64
    let modelID: String
    let text: String
    let status: String
    enum CodingKeys: String, CodingKey { case jobID = "job_id", generation, modelID = "model_id", text, status }
}

private struct RequestLine: Decodable {
    let jobID: String
    let generation: UInt64
    let audioFile: String
    let language: DesktopDictationLanguage?
    let preferredLanguages: [String]?
    let recognitionHintPrompt: String?
    enum CodingKeys: String, CodingKey { case jobID = "job_id", generation, audioFile = "audio_file", language, preferredLanguages, recognitionHintPrompt = "recognition_hint_prompt" }
}

private func emit(_ line: String) {
    print(line)
    fflush(stdout)
}

/// The parent retains only these fixed stage names.  Keep diagnostics free of
/// paths, audio data, SDK error strings and transcription text: this channel
/// exists solely to distinguish a bounded native failure stage in AP04 logs.
private func stage(_ name: String) {
    fputs("KLANGSCHRIFT_WORKER_STAGE=\(name)\n", stderr)
    fflush(stderr)
}

@main
struct KlangschriftDesktopNativeWorker {
    static func main() async {
        do {
            let arguments = try Arguments()
            stage("runner_init")
            let runner = try DesktopFileInferenceRunners.make(modelID: arguments.modelID, modelDirectory: arguments.modelDirectory)
            if arguments.serve {
                stage("prepare")
                try await runner.prepare()
                stage("ready")
                emit("KLANGSCHRIFT_READY")
                while let line = readLine() {
                    guard let data = Data(base64Encoded: line), let request = try? JSONDecoder().decode(RequestLine.self, from: data) else {
                        emit("KLANGSCHRIFT_ERROR")
                        continue
                    }
                    do {
                        stage("transcribe")
                        let text = try await runner.transcribe(audioFile: URL(fileURLWithPath: request.audioFile), language: request.language ?? .automatic, preferredLanguages: request.preferredLanguages ?? PreferredDictationLanguages.defaults, recognitionHintPrompt: request.recognitionHintPrompt)
                        let result = try JSONEncoder().encode(ResultLine(jobID: request.jobID, generation: request.generation, modelID: arguments.modelID, text: text, status: "text"))
                        emit("KLANGSCHRIFT_RESULT:" + result.base64EncodedString())
                    } catch DesktopRuntimeError.noSpeech {
                        let result = try JSONEncoder().encode(ResultLine(jobID: request.jobID, generation: request.generation, modelID: arguments.modelID, text: "", status: "noSpeech"))
                        emit("KLANGSCHRIFT_RESULT:" + result.base64EncodedString())
                    } catch {
                        stage("transcribe_failed")
                        emit("KLANGSCHRIFT_ERROR")
                    }
                }
                await runner.unload()
            } else if let audioFile = arguments.audioFile, let jobID = arguments.jobID, let generation = arguments.generation {
                stage("transcribe")
                let result: ResultLine
                do { let text = try await runner.transcribe(audioFile: audioFile, language: arguments.language, preferredLanguages: arguments.preferredLanguages); result = .init(jobID: jobID, generation: generation, modelID: arguments.modelID, text: text, status: "text") }
                catch DesktopRuntimeError.noSpeech { result = .init(jobID: jobID, generation: generation, modelID: arguments.modelID, text: "", status: "noSpeech") }
                let data = try JSONEncoder().encode(result)
                emit("KLANGSCHRIFT_RESULT:" + data.base64EncodedString())
            } else {
                throw Exit.invalidArguments
            }
        } catch {
            stage("startup_failed")
            fputs("KLANGSCHRIFT_WORKER_FAILED\n", stderr)
            fflush(stderr)
            exit(1)
        }
    }
}
