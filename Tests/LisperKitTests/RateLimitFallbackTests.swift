import Testing
@testable import LisperKit

private final class ScriptedCleanup: CleanupEngine, @unchecked Sendable {
    let name: String
    let result: Result<String, EngineError>
    private(set) var calls = 0
    init(_ name: String, _ result: Result<String, EngineError>) { self.name = name; self.result = result }
    func clean(raw: String, context: CleanupContext) async throws -> String { calls += 1; return try result.get() }
}

/// Groq's free tier allows ~7 takes/min on the main model; a burst used to drop straight to
/// rule cleanup (no dictionary, no smarts). Rate limits are per model, so a 429 retries once
/// on the backup model first.
@Suite struct RateLimitFallbackTests {
    private let ctx = CleanupContext(appName: "Notes", bundleID: "x", dictionaryTerms: ["Jeriq"])

    @Test func rateLimitedPrimaryRetriesOnBackup() async throws {
        let primary = ScriptedCleanup("llm", .failure(.badResponse(429, "rate_limit_exceeded")))
        let backup = ScriptedCleanup("llm", .success("With Jeriq, so yeah."))
        let engine = RateLimitFallbackCleanup(primary: primary, backup: backup)
        #expect(try await engine.clean(raw: "with Jerry, so yeah.", context: ctx) == "With Jeriq, so yeah.")
        #expect(backup.calls == 1)
    }

    /// Only a rate limit moves to the backup — a bad key or offline would fail there too.
    @Test func otherFailuresDoNotTouchBackup() async throws {
        let primary = ScriptedCleanup("llm", .failure(.badResponse(401, "invalid_api_key")))
        let backup = ScriptedCleanup("llm", .success("unused"))
        let engine = RateLimitFallbackCleanup(primary: primary, backup: backup)
        await #expect(throws: EngineError.badResponse(401, "invalid_api_key")) {
            _ = try await engine.clean(raw: "hi there", context: ctx)
        }
        #expect(backup.calls == 0)
    }

    /// Both rate-limited: surface the PRIMARY's error, so the user's notice says "rate limit".
    @Test func bothRateLimitedThrowsPrimaryError() async throws {
        let primary = ScriptedCleanup("llm", .failure(.badResponse(429, "primary")))
        let backup = ScriptedCleanup("llm", .failure(.badResponse(429, "backup")))
        let engine = RateLimitFallbackCleanup(primary: primary, backup: backup)
        await #expect(throws: EngineError.badResponse(429, "primary")) {
            _ = try await engine.clean(raw: "hi there", context: ctx)
        }
    }

    @Test func backupModelDefaultsToGptOss20b() {
        #expect(AppSettings().groqBackupChatModel == "openai/gpt-oss-20b")
    }

    @Test func onlyA429IsARateLimit() {
        #expect(EngineError.badResponse(429, "x").isRateLimited)
        #expect(!EngineError.badResponse(401, "x").isRateLimited)
        #expect(!EngineError.network("down").isRateLimited)
    }

    /// The backup is used only when it is set and actually differs from the main model
    /// (compared trimmed — a stray space in Settings must not count as "different").
    @Test func backupModelOnlyWhenDistinct() {
        var s = AppSettings()
        #expect(s.distinctBackupChatModel == "openai/gpt-oss-20b")
        s.groqBackupChatModel = "  "
        #expect(s.distinctBackupChatModel == nil)
        s.groqBackupChatModel = "openai/gpt-oss-120b "
        #expect(s.distinctBackupChatModel == nil)
        s.groqChatModel = " my/model"; s.groqBackupChatModel = "my/model"
        #expect(s.distinctBackupChatModel == nil)
    }
}

