import Foundation
import Testing
import GRDB
@testable import LisperKit

private struct FixedSTT: TranscriptionEngine {
    let name = "groq"
    func transcribe(audio: CapturedAudio, dictionaryTerms: [String]) async throws -> String {
        "um hello there friends how are you doing today"
    }
}

private struct FailingCleanup: CleanupEngine {
    let name = "llm"
    let error: EngineError
    func clean(raw: String, context: CleanupContext) async throws -> String { throw error }
}

/// LLM cleanup failed on every take for two months (a retired model) and nothing said so —
/// the pipeline swallowed the error. The failure must be recorded, and anything the user can
/// fix (model, key, rate limit) must come back as a notice the app can show.
@Suite struct CleanupFailureTests {
    private func run(_ error: EngineError, logURL: URL? = nil) async throws -> DictationOutcome {
        let p = DictationPipeline(
            primarySTT: FixedSTT(), fallbackSTT: nil,
            llmCleanup: FailingCleanup(error: error), ruleCleanup: RuleCleanupEngine(),
            database: try LisperDatabase(queue: DatabaseQueue()),
            debugLog: logURL.map { DebugLog(fileURL: $0) }, guardLog: GuardLog())
        return try await p.process(
            audio: CapturedAudio(samples: Array(repeating: 0.1, count: 16_000)),
            context: CleanupContext(appName: "Notes", bundleID: "com.apple.Notes", dictionaryTerms: []),
            customFillers: [])
    }

    @Test func retiredModelProducesSettingsNotice() async throws {
        let out = try await run(.badResponse(404, #"{"error":{"code":"model_decommissioned"}}"#))
        #expect(out.cleanupUsed == "rules")   // still degrades, never errors out
        #expect(out.cleanupNotice?.contains("Settings") == true)
    }

    @Test func rejectedKeyProducesNotice() async throws {
        let out = try await run(.badResponse(401, "invalid_api_key"))
        #expect(out.cleanupNotice?.lowercased().contains("key") == true)
    }

    @Test func rateLimitProducesNotice() async throws {
        let out = try await run(.badResponse(429, "rate_limit_exceeded"))
        #expect(out.cleanupNotice?.lowercased().contains("rate limit") == true)
    }

    /// Offline is the designed graceful degrade — basic cleanup, no nagging.
    @Test func offlineIsSilent() async throws {
        let out = try await run(.network("The Internet connection appears to be offline."))
        #expect(out.cleanupUsed == "rules")
        #expect(out.cleanupNotice == nil)
    }

    @Test func errorTextIsWrittenToTheDebugLog() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanup-failure-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await run(.badResponse(404, "model_decommissioned"), logURL: url)
        let line = try String(contentsOf: url, encoding: .utf8)
        #expect(line.contains("cleanupError"))
        #expect(line.contains("model_decommissioned"))
    }
}
