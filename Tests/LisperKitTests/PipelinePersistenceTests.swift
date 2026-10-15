import Foundation
import Testing
import GRDB
@testable import LisperKit

private struct FixedSTT: TranscriptionEngine {
    let name = "groq"
    func transcribe(audio: CapturedAudio, dictionaryTerms: [String]) async throws -> String {
        "please send the contract to the whole team by noon tomorrow"
    }
}

private struct FixedCleanup: CleanupEngine {
    let name = "llm"
    func clean(raw: String, context: CleanupContext) async throws -> String {
        "Please send the contract to the whole team by noon tomorrow."
    }
}

/// History is a side-effect; the user's dictation is the product. A failed history write
/// (full disk, DB locked by a second instance) used to throw out of `process` after a
/// successful transcription — nothing pasted, "Couldn't transcribe" shown.
@Suite struct PipelinePersistenceTests {
    @Test func failedHistoryWriteStillReturnsTheText() async throws {
        let queue = try DatabaseQueue()
        let db = try LisperDatabase(queue: queue)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_insert BEFORE INSERT ON sessions
                BEGIN SELECT RAISE(ABORT, 'disk full'); END
                """)
        }
        let guardLog = GuardLog()
        let p = DictationPipeline(primarySTT: FixedSTT(), fallbackSTT: nil,
                                  llmCleanup: FixedCleanup(), ruleCleanup: RuleCleanupEngine(),
                                  database: db, guardLog: guardLog)
        let out = try await p.process(
            audio: CapturedAudio(samples: Array(repeating: 0.1, count: 16_000)),
            context: CleanupContext(appName: "Mail", bundleID: "com.apple.mail", dictionaryTerms: []),
            customFillers: [])
        #expect(out.cleanedText == "Please send the contract to the whole team by noon tomorrow.")
        #expect(out.session.id == nil)
        #expect(out.guardsFired.contains("historyWriteFailed"))
    }
}
