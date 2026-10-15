import Testing
@testable import LisperKit

@Suite struct LiveReplayTests {
    @Test func testReplaySavedWavsThroughGroq() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LISPER_LIVE"] == "1",
              let key = env["GROQ_API_KEY"], !key.isEmpty,
              let dirPath = env["LISPER_REPLAY_DIR"] else {
            return // offline / not requested — skip silently
        }
        let dir = URL(fileURLWithPath: dirPath)
        let wavs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "wav" } ?? []
        #expect(!wavs.isEmpty, "no .wav files in LISPER_REPLAY_DIR")

        let client = GroqClient(baseURL: "https://api.groq.com/openai/v1", apiKey: key)
        // The app's defaults, so a replay reproduces what a take actually went through.
        let settings = AppSettings()
        for wav in wavs {
            let data = try Data(contentsOf: wav)
            let guardLog = GuardLog()
            let engine = GroqWhisperEngine(client: client, model: settings.groqWhisperModel,
                                           language: "en", guardLog: guardLog,
                                           endingCheckModel: settings.distinctEndingCheckModel)
            let samples = WavEncoder.decodeToSamples(data)
            let audio = CapturedAudio(samples: samples)
            let text = (try? await engine.transcribe(audio: audio, dictionaryTerms: [])) ?? "<rejected>"
            print("REPLAY \(wav.lastPathComponent): guards=\(guardLog.all()) -> \(text)")
        }
    }
}
