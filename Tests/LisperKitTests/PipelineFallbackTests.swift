import Testing
import GRDB
@testable import LisperKit

private struct MockSTT: TranscriptionEngine {
    let name: String
    let result: Result<String, EngineError>
    func transcribe(audio: CapturedAudio, dictionaryTerms: [String]) async throws -> String {
        try result.get()
    }
}

private struct MockCleanup: CleanupEngine {
    let name: String
    let result: Result<String, EngineError>
    func clean(raw: String, context: CleanupContext) async throws -> String { try result.get() }
}

/// Records whether `clean` was ever invoked, so a test can prove the fast path
/// skipped the LLM entirely (not just that its output went unused).
private final class SpyCleanup: CleanupEngine, @unchecked Sendable {
    let name: String
    let output: String
    private nonisolated(unsafe) var called = false
    init(name: String, output: String) { self.name = name; self.output = output }
    func clean(raw: String, context: CleanupContext) async throws -> String {
        called = true
        return output
    }
    var wasCalled: Bool { called }
}

/// Records the dictionaryTerms the pipeline fed to Whisper, so a test can prove the
/// vocabulary prompt is withheld when the LLM cleanup will fix spelling instead.
private final class SpySTT: TranscriptionEngine, @unchecked Sendable {
    let name: String
    let output: String
    private nonisolated(unsafe) var received: [String]? = nil
    init(name: String, output: String) { self.name = name; self.output = output }
    func transcribe(audio: CapturedAudio, dictionaryTerms: [String]) async throws -> String {
        received = dictionaryTerms
        return output
    }
    var receivedTerms: [String]? { received }
}

@Suite struct PipelineFallbackTests {

    func makePipeline(primary: TranscriptionEngine?, fallback: TranscriptionEngine?,
                      cleanup: CleanupEngine?, db: LisperDatabase) -> DictationPipeline {
        DictationPipeline(
            primarySTT: primary, fallbackSTT: fallback,
            llmCleanup: cleanup, ruleCleanup: RuleCleanupEngine(), database: db)
    }

    func audio() -> CapturedAudio { CapturedAudio(samples: Array(repeating: 0.1, count: 16_000)) }

    func ctx() -> CleanupContext {
        CleanupContext(appName: "TextEdit", bundleID: "com.apple.TextEdit", dictionaryTerms: [])
    }

    @Test func testHappyPathUsesPrimaryAndLLM() async throws {
        let db = try LisperDatabase(queue: DatabaseQueue())
        // Intentionally longer than CleanupRouter.fastPathMaxWords words so the
        // happy path exercises the LLM hop (short inputs now take the rule fast path).
        let longRaw = "um so i think we should ship this feature today"
        let p = makePipeline(
            primary: MockSTT(name: "groq", result: .success(longRaw)),
            fallback: MockSTT(name: "apple", result: .success("WRONG")),
            cleanup: MockCleanup(name: "llm", result: .success("Hello world.")), db: db)
        let outcome = try await p.process(audio: audio(), context: ctx(), customFillers: [])
        #expect(outcome.cleanedText == "Hello world.")
        #expect(outcome.engineUsed == "groq")
        #expect(outcome.cleanupUsed == "llm")
        #expect(try db.recentSessions(limit: 5).count == 1)
        #expect(try db.recentSessions(limit: 5)[0].rawTranscript == longRaw)
    }

    @Test func testSTTFallsBackToApple() async throws {
        let db = try LisperDatabase(queue: DatabaseQueue())
        let p = makePipeline(
            primary: MockSTT(name: "groq", result: .failure(.network("down"))),
            fallback: MockSTT(name: "apple", result: .success("um hello")),
            cleanup: MockCleanup(name: "llm", result: .success("Hello.")), db: db)
        let outcome = try await p.process(audio: audio(), context: ctx(), customFillers: [])
        #expect(outcome.engineUsed == "apple")
        #expect(outcome.cleanupUsed == "rules")  // short input takes the fast path; the llm fixture is unused
    }

    @Test func testCleanupFallsBackToRules() async throws {
        let db = try LisperDatabase(queue: DatabaseQueue())
        // Longer than CleanupRouter.fastPathMaxWords words so the LLM is genuinely
        // invoked (a short input would take the fast path and never call it). The
        // LLM mock then throws, which must trigger the rules fallback — proving the
        // fallback path, not the fast path, is what selected rules here.
        let guardLog = GuardLog()
        let p = DictationPipeline(
            primarySTT: MockSTT(name: "groq", result: .success("um hello there friends how are you")),
            fallbackSTT: nil,
            llmCleanup: MockCleanup(name: "llm", result: .failure(.network("down"))),
            ruleCleanup: RuleCleanupEngine(), database: db, guardLog: guardLog)
        let outcome = try await p.process(audio: audio(), context: ctx(), customFillers: [])
        #expect(outcome.cleanupUsed == "rules")
        #expect(!outcome.cleanedText.lowercased().contains("um"))
        #expect(outcome.guardsFired.contains("cleanupFallback"))
        #expect(!outcome.guardsFired.contains("fastPathCleanup"))
    }

    /// Every engine heard nothing (an accidental tap): that is "no speech", not a connection
    /// or key problem — the old catch-all told the user to check their connection.
    @Test func testAllEnginesHearingNothingThrowsNoSpeech() async throws {
        let db = try LisperDatabase(queue: DatabaseQueue())
        let p = makePipeline(
            primary: MockSTT(name: "groq", result: .failure(.emptyTranscript)),
            fallback: MockSTT(name: "apple", result: .failure(.emptyTranscript)),
            cleanup: nil, db: db)
        await #expect(throws: PipelineError.noSpeech) {
            _ = try await p.process(audio: audio(), context: ctx(), customFillers: [])
        }
    }

    @Test func testBothSTTFailThrows() async throws {
        let db = try LisperDatabase(queue: DatabaseQueue())
        let p = makePipeline(
            primary: MockSTT(name: "groq", result: .failure(.network("down"))),
            fallback: MockSTT(name: "apple", result: .failure(.unavailable("no permission"))),
            cleanup: nil, db: db)
        await #expect(throws: (any Error).self) {
            _ = try await p.process(audio: audio(), context: ctx(), customFillers: [])
        }
        #expect(try db.recentSessions(limit: 5).count == 0) // nothing saved on failure
    }

    @Test func testNoLLMCleanupUsesRulesDirectly() async throws {
        let db = try LisperDatabase(queue: DatabaseQueue())
        let p = makePipeline(
            primary: MockSTT(name: "apple", result: .success("um hello there")),
            fallback: nil, cleanup: nil, db: db)
        let outcome = try await p.process(audio: audio(), context: ctx(), customFillers: [])
        #expect(outcome.cleanupUsed == "rules")
        #expect(!outcome.cleanedText.lowercased().contains("um"))
    }

    @Test func testLocalizedHallucinationLoopIsExcisedNotFalledBack() async throws {
        // Regression for the reported bug: Groq returns a good long transcript that
        // ends in a back-to-back loop. The pipeline must KEEP Groq's transcript with
        // the loop excised — NOT discard it and fall back to Apple (which eats the start).
        let db = try LisperDatabase(queue: DatabaseQueue())
        let looped = "this is the real message I dictated and it should survive intact " +
            "lisperyourads lisperyourads lisperyourads lisperyourads lisperyourads lisperyourads"
        let p = makePipeline(
            primary: MockSTT(name: "groq", result: .success(looped)),
            fallback: MockSTT(name: "apple", result: .success("TRUNCATED START LOST")),
            cleanup: nil, db: db)
        let outcome = try await p.process(audio: audio(), context: ctx(), customFillers: [])
        #expect(outcome.engineUsed == "groq")                                  // no fallback
        #expect(outcome.rawTranscript.contains("this is the real message I dictated"))
        #expect(outcome.rawTranscript.lowercased().components(separatedBy: "lisperyourads").count - 1 <= 1)
    }

    @Test func testSession205VocabEchoAndLoopExcisedEndToEnd() async throws {
        // The exact reported regression (session 205): a good 70-word take whose real
        // ending Whisper lost on quiet audio, replaced by a vocab-prompt echo
        // ("FowlerAds, Lisper") + a "Crap, Lid, Mace" loop. The pipeline must keep the
        // good prefix, paste NONE of the burst, and stay on Groq (no Apple fallback).
        let db = try LisperDatabase(queue: DatabaseQueue())
        let raw = "okay so right now there's some mix between like oh grainy but also futuristic " +
            "FowlerAds, Lisper, Crap, Lid, Mace, Crap, Lid, Mace, Crap, Lid, Mace."
        let context = CleanupContext(appName: "TextEdit", bundleID: "com.apple.TextEdit",
                                     dictionaryTerms: ["Wispr Flow", "BetterYourAds", "Lisper"])
        let p = DictationPipeline(
            primarySTT: MockSTT(name: "groq", result: .success(raw)),
            fallbackSTT: MockSTT(name: "apple", result: .success("TRUNCATED")),
            llmCleanup: nil, ruleCleanup: RuleCleanupEngine(), database: db,
            guardLog: GuardLog())
        let outcome = try await p.process(audio: audio(), context: context, customFillers: [])
        #expect(outcome.engineUsed == "groq")
        #expect(outcome.rawTranscript.contains("futuristic"))
        for garbage in ["FowlerAds", "Crap", "Lid", "Mace"] {
            #expect(!outcome.rawTranscript.contains(garbage), "raw kept garbage: \(garbage)")
            #expect(!outcome.cleanedText.contains(garbage), "cleaned kept garbage: \(garbage)")
        }
        #expect(outcome.guardsFired.contains("excisedTrailingHallucination"))
    }

    @Test func testTooShortAudioThrowsTooShort() async throws {
        let db = try LisperDatabase(queue: DatabaseQueue())
        let p = makePipeline(primary: MockSTT(name: "groq", result: .success("hi")),
                             fallback: nil, cleanup: nil, db: db)
        let tiny = CapturedAudio(samples: Array(repeating: 0.1, count: 3000)) // <0.4s
        await #expect(throws: PipelineError.tooShort) {
            _ = try await p.process(audio: tiny, context: ctx(), customFillers: [])
        }
    }

    // Fast path: a short utterance with an LLM configured skips the LLM entirely,
    // cleans with rules, and records the fastPathCleanup guard.
    @Test func testShortUtteranceUsesRuleFastPathAndSkipsLLM() async throws {
        let db = try LisperDatabase(queue: DatabaseQueue())
        let guardLog = GuardLog()
        let spy = SpyCleanup(name: "llm", output: "LLM_WAS_CALLED")
        let p = DictationPipeline(
            primarySTT: MockSTT(name: "groq", result: .success("yes send it")), // 3 words ≤ threshold
            fallbackSTT: nil, llmCleanup: spy, ruleCleanup: RuleCleanupEngine(),
            database: db, guardLog: guardLog)
        let outcome = try await p.process(audio: audio(), context: ctx(), customFillers: [])
        #expect(outcome.cleanupUsed == "rules")
        #expect(outcome.cleanedText != "LLM_WAS_CALLED")
        #expect(outcome.guardsFired.contains("fastPathCleanup"))
        #expect(!spy.wasCalled)   // the LLM hop was genuinely skipped
    }

    // The vocabulary prompt is Whisper's hallucination fuel: it primes the decoder
    // toward dictionary tokens and loops on them ("LisperYourAds…", "Crap, Lid, Mace…").
    // When an LLM cleanup is configured it already enforces spelling
    // ("always spell these exactly: …"), so we withhold the prompt from Whisper —
    // killing the echo at the source while keeping spelling correct downstream.
    @Test func testWhisperPromptWithheldWhenLLMCleanupConfigured() async throws {
        let db = try LisperDatabase(queue: DatabaseQueue())
        let spy = SpySTT(name: "groq", output: "um so i think we should ship this feature today")
        let context = CleanupContext(appName: "TextEdit", bundleID: "com.apple.TextEdit",
                                     dictionaryTerms: ["Wispr Flow", "BetterYourAds", "Lisper"])
        let p = DictationPipeline(
            primarySTT: spy, fallbackSTT: nil,
            llmCleanup: MockCleanup(name: "llm", result: .success("Clean.")),
            ruleCleanup: RuleCleanupEngine(), database: db)
        _ = try await p.process(audio: audio(), context: context, customFillers: [])
        #expect(spy.receivedTerms == [])   // dictionary NOT fed to Whisper
    }

    // With no LLM cleanup to fix spelling, fall back to giving Whisper the vocab hint.
    @Test func testWhisperPromptSentWhenNoLLMCleanup() async throws {
        let db = try LisperDatabase(queue: DatabaseQueue())
        let terms = ["Wispr Flow", "BetterYourAds", "Lisper"]
        let spy = SpySTT(name: "groq", output: "um so i think we should ship this feature today")
        let context = CleanupContext(appName: "TextEdit", bundleID: "com.apple.TextEdit",
                                     dictionaryTerms: terms)
        let p = DictationPipeline(
            primarySTT: spy, fallbackSTT: nil,
            llmCleanup: nil, ruleCleanup: RuleCleanupEngine(), database: db)
        _ = try await p.process(audio: audio(), context: context, customFillers: [])
        #expect(spy.receivedTerms == terms)   // no LLM downstream → Whisper gets the spelling hint
    }

    // A SHORT utterance WITH a dictionary must still run the LLM (NOT the rule fast path),
    // so phonetic corrections like "Jerry" -> "Jeriq" reach even one-word takes.
    @Test func testShortUtteranceWithDictionaryUsesLLM() async throws {
        let db = try LisperDatabase(queue: DatabaseQueue())
        let guardLog = GuardLog()
        let spy = SpyCleanup(name: "llm", output: "Jeriq")
        let context = CleanupContext(appName: "TextEdit", bundleID: "com.apple.TextEdit",
                                     dictionaryTerms: ["Jeriq"])
        let p = DictationPipeline(
            primarySTT: MockSTT(name: "groq", result: .success("Jerry")),  // 1 word — would normally fast-path
            fallbackSTT: nil, llmCleanup: spy, ruleCleanup: RuleCleanupEngine(),
            database: db, guardLog: guardLog)
        let outcome = try await p.process(audio: audio(), context: context, customFillers: [])
        #expect(spy.wasCalled)                                   // LLM ran despite the short input
        #expect(outcome.cleanupUsed == "llm")
        #expect(!outcome.guardsFired.contains("fastPathCleanup"))
    }

    // A short utterance with NO dictionary still takes the fast path (latency win preserved).
    @Test func testShortUtteranceNoDictionaryStillFastPaths() async throws {
        let db = try LisperDatabase(queue: DatabaseQueue())
        let guardLog = GuardLog()
        let spy = SpyCleanup(name: "llm", output: "LLM_WAS_CALLED")
        let p = DictationPipeline(
            primarySTT: MockSTT(name: "groq", result: .success("yes send it")),
            fallbackSTT: nil, llmCleanup: spy, ruleCleanup: RuleCleanupEngine(),
            database: db, guardLog: guardLog)   // ctx() has empty dictionaryTerms
        let outcome = try await p.process(audio: audio(), context: ctx(), customFillers: [])
        #expect(!spy.wasCalled)
        #expect(outcome.guardsFired.contains("fastPathCleanup"))
    }

    // Long utterance with an LLM configured still uses the LLM (no fast path fired).
    @Test func testLongUtteranceUsesLLMNotFastPath() async throws {
        let db = try LisperDatabase(queue: DatabaseQueue())
        let guardLog = GuardLog()
        let spy = SpyCleanup(name: "llm", output: "Cleaned by the LLM.")
        let p = DictationPipeline(
            primarySTT: MockSTT(name: "groq",
                                result: .success("um so i think we should ship this feature today")),
            fallbackSTT: nil, llmCleanup: spy, ruleCleanup: RuleCleanupEngine(),
            database: db, guardLog: guardLog)
        let outcome = try await p.process(audio: audio(), context: ctx(), customFillers: [])
        #expect(outcome.cleanupUsed == "llm")
        #expect(outcome.cleanedText == "Cleaned by the LLM.")
        #expect(spy.wasCalled)
        #expect(!outcome.guardsFired.contains("fastPathCleanup"))
    }
}
