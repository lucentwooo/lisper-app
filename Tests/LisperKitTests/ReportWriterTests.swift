import Testing
@testable import LisperKit

@Suite struct ReportWriterTests {
    @Test func testWritesBundleWithJSONAndAudio() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("lisper-reports-\(UUID().uuidString)")
        let rec = DictationDebugRecord(
            timestamp: Date(timeIntervalSince1970: 0), sessionId: 7, durationSeconds: 2,
            rms: 0.2, engineUsed: "groq", cleanupUsed: "llm",
            rawTranscript: "VHL VAR GEMETSUI", cleanedText: "VHL VAR GEMETSUI",
            guardsFired: [], latencyMs: 100, error: nil)
        let settings = ["dictionaryTerms": "Groq, Lisper", "transcriptionLanguage": "en"]
        let folder = try ReportWriter.write(
            into: base, sessionId: 7, record: rec,
            settingsSnapshot: settings, note: "I said hello, it typed gibberish",
            audio: Data([0x52, 0x49, 0x46, 0x46])) // "RIFF"

        let json = try String(contentsOf: folder.appendingPathComponent("report.json"), encoding: .utf8)
        #expect(json.contains("\"note\":\"I said hello, it typed gibberish\""))
        #expect(json.contains("\"transcriptionLanguage\":\"en\""))
        #expect(!json.lowercased().contains("apikey"))
        #expect(!json.lowercased().contains("api_key"))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("audio.wav").path))
    }

    @Test func testWritesWithoutAudioWhenPurged() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("lisper-reports-\(UUID().uuidString)")
        let rec = DictationDebugRecord(
            timestamp: Date(timeIntervalSince1970: 0), sessionId: 8, durationSeconds: 1,
            rms: 0, engineUsed: "", cleanupUsed: "", rawTranscript: "", cleanedText: "",
            guardsFired: ["silence"], latencyMs: 1, error: "tooShort")
        let folder = try ReportWriter.write(into: base, sessionId: 8, record: rec,
            settingsSnapshot: [:], note: "nothing was said", audio: nil)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("report.json").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("audio.wav").path))
    }
}
