import Testing
import GRDB
@testable import LisperKit

private struct GuardMockSTT: TranscriptionEngine {
    let name: String
    let result: Result<String, EngineError>
    let log: GuardLog
    let signal: String?
    func transcribe(audio: CapturedAudio, dictionaryTerms: [String]) async throws -> String {
        if let signal { log.record(signal) }
        return try result.get()
    }
}

private struct OKCleanup: CleanupEngine {
    let name = "llm"
    func clean(raw: String, context: CleanupContext) async throws -> String { "Clean." }
}

@Suite struct PipelineDebugTests {
    private func ctx() -> CleanupContext {
        CleanupContext(appName: "TextEdit", bundleID: "com.apple.TextEdit", dictionaryTerms: [])
    }
    private func speech() -> CapturedAudio { CapturedAudio(samples: Array(repeating: 0.1, count: 16_000)) }
    private func silent() -> CapturedAudio { CapturedAudio(samples: Array(repeating: 0, count: 16_000)) }

    @Test func testSuccessWritesRecordWithRmsAndGuards() async throws {
        let db = try LisperDatabase(queue: DatabaseQueue())
        let gl = GuardLog()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lisper-pdbg-\(UUID().uuidString)/d.jsonl")
        let dl = DebugLog(fileURL: url)
        let p = DictationPipeline(
            primarySTT: GuardMockSTT(name: "groq", result: .success("raw words here"), log: gl, signal: "retry"),
            fallbackSTT: nil, llmCleanup: OKCleanup(), ruleCleanup: RuleCleanupEngine(),
            database: db, debugLog: dl, guardLog: gl)
        let outcome = try await p.process(audio: speech(), context: ctx(), customFillers: [])
        #expect(outcome.rms > 0.05)
        #expect(outcome.guardsFired.contains("retry"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"rawTranscript\":\"raw words here\""))
        #expect(text.contains("\"retry\""))
    }

    @Test func testSilenceRecordsGuardAndStillThrows() async throws {
        let db = try LisperDatabase(queue: DatabaseQueue())
        let gl = GuardLog()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lisper-pdbg-\(UUID().uuidString)/d.jsonl")
        let dl = DebugLog(fileURL: url)
        let p = DictationPipeline(
            primarySTT: GuardMockSTT(name: "groq", result: .success("x"), log: gl, signal: nil),
            fallbackSTT: nil, llmCleanup: nil, ruleCleanup: RuleCleanupEngine(),
            database: db, debugLog: dl, guardLog: gl)
        await #expect(throws: PipelineError.tooShort) {
            _ = try await p.process(audio: silent(), context: ctx(), customFillers: [])
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"silence\""))
        #expect(text.contains("\"error\":\"tooShort\""))
    }
}
