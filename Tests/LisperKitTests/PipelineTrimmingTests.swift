import Testing
import GRDB
@testable import LisperKit

private struct FixedSTT: TranscriptionEngine {
    let name: String
    let result: String
    func transcribe(audio: CapturedAudio, dictionaryTerms: [String]) async throws -> String { result }
}

/// Always trims to empty — exercises the pipeline's "trimmed to silence" branch
/// independently of the energy heuristic (the real trimmer only returns empty for
/// clips the whole-clip silence gate would already have caught).
private struct EmptyingTrimmer: VoiceActivityTrimmer {
    func trim(_ audio: CapturedAudio) -> CapturedAudio {
        CapturedAudio(samples: [], sampleRate: audio.sampleRate)
    }
}

@Suite struct PipelineTrimmingTests {

    private let sr: Double = 16_000

    private func tone(seconds: Double, amplitude: Float = 0.3) -> [Float] {
        let n = Int(seconds * sr)
        return (0..<n).map { $0 % 2 == 0 ? amplitude : -amplitude }
    }
    private func silence(seconds: Double) -> [Float] {
        Array(repeating: 0, count: Int(seconds * sr))
    }
    private func ctx() -> CleanupContext {
        CleanupContext(appName: "TextEdit", bundleID: "com.apple.TextEdit", dictionaryTerms: [])
    }

    private func makePipeline(stt: TranscriptionEngine, guardLog: GuardLog,
                              db: LisperDatabase) -> DictationPipeline {
        DictationPipeline(
            primarySTT: stt, fallbackSTT: nil,
            llmCleanup: nil, ruleCleanup: RuleCleanupEngine(), database: db,
            guardLog: guardLog, trimmer: EnergyVoiceActivityTrimmer())
    }

    // (a) A clip whose trimmer returns empty (no speech survived) throws tooShort
    // and records the trimmedToSilence guard — nothing reaches Whisper or the DB.
    @Test func testTrimsToSilenceThrowsTooShort() async throws {
        let db = try LisperDatabase(queue: DatabaseQueue())
        let guardLog = GuardLog()
        // Real audio on the gates (RMS 0.3 ≫ 0.008, >0.4s) so it gets past the
        // duration/silence gates and into the trimmer, which here returns empty.
        let samples = tone(seconds: 1.0)
        let p = DictationPipeline(
            primarySTT: FixedSTT(name: "groq", result: "should not be reached"), fallbackSTT: nil,
            llmCleanup: nil, ruleCleanup: RuleCleanupEngine(), database: db,
            guardLog: guardLog, trimmer: EmptyingTrimmer())
        await #expect(throws: PipelineError.tooShort) {
            _ = try await p.process(audio: CapturedAudio(samples: samples, sampleRate: sr),
                                    context: ctx(), customFillers: [])
        }
        #expect(guardLog.all().contains("trimmedToSilence"))
        #expect(try db.recentSessions(limit: 5).count == 0)   // nothing persisted
    }

    // (b) A [silence][speech][silence] clip transcribes normally AND records
    // vadTrimmed — but the persisted duration is the ORIGINAL 2.0s capture, not
    // the trimmed span. Trimming changes only what Whisper sees; coaching numbers
    // describe the full take.
    @Test func testRealSpeechTranscribesAndRecordsVadTrimmed() async throws {
        let db = try LisperDatabase(queue: DatabaseQueue())
        let guardLog = GuardLog()
        let samples = silence(seconds: 0.5) + tone(seconds: 1.0) + silence(seconds: 0.5)
        let p = makePipeline(stt: FixedSTT(name: "groq", result: "um hello world"),
                             guardLog: guardLog, db: db)
        let outcome = try await p.process(audio: CapturedAudio(samples: samples, sampleRate: sr),
                                          context: ctx(), customFillers: [])
        #expect(outcome.rawTranscript == "um hello world")
        #expect(outcome.engineUsed == "groq")
        #expect(guardLog.all().contains("vadTrimmed"))
        // Persisted/reported duration is the ORIGINAL 2.0s capture, NOT the
        // ~1.6s trimmed clip — coaching stats must reflect the full take.
        let originalDuration = Double(samples.count) / sr
        let saved = try db.recentSessions(limit: 5)
        #expect(saved.count == 1)
        #expect(abs(saved[0].durationSeconds - originalDuration) < 0.01)
        #expect(saved[0].durationSeconds > 1.9)
        // WPM is computed over the full ~2.0s capture: 3 words / (2.0/60) ≈ 90.
        // Over the ~1.6s trimmed clip it would be ~112. Assert the un-inflated value.
        #expect(outcome.stats.wordsPerMinute < 100)
        #expect(abs(saved[0].wpm - outcome.stats.wordsPerMinute) < 0.01)
    }

    // (c) The bug this fix targets: a short speech blip wrapped in silence passes
    // the whole-clip silence gate (so it reaches the trimmer), then trims to a
    // much shorter span. It must STILL transcribe (short real words are valid),
    // and the persisted/stats duration must be the ORIGINAL capture so WPM is
    // computed over the full time the key was held — NOT inflated by dividing the
    // word count by the trimmed sliver.
    @Test func testShortBlipUsesOriginalDurationForWpm() async throws {
        let db = try LisperDatabase(queue: DatabaseQueue())
        let guardLog = GuardLog()
        // ~1.0s held; ~0.15s of actual speech. The whole clip is not silent
        // (the blip lifts the RMS past the gate) so it reaches the real trimmer.
        let samples = silence(seconds: 0.45) + tone(seconds: 0.15) + silence(seconds: 0.45)
        let originalDuration = Double(samples.count) / sr   // ~1.05s
        let p = makePipeline(stt: FixedSTT(name: "groq", result: "yes"),
                             guardLog: guardLog, db: db)
        let outcome = try await p.process(audio: CapturedAudio(samples: samples, sampleRate: sr),
                                          context: ctx(), customFillers: [])
        // (a) Still transcribes — short utterances are not rejected.
        #expect(outcome.rawTranscript == "yes")
        #expect(outcome.engineUsed == "groq")
        #expect(guardLog.all().contains("vadTrimmed"))
        // (b) Persisted duration == ORIGINAL capture, so WPM is over the full
        // ~1.05s, not the trimmed ~0.7s sliver (which would inflate it).
        let saved = try db.recentSessions(limit: 5)
        #expect(saved.count == 1)
        #expect(abs(saved[0].durationSeconds - originalDuration) < 0.01)
        // 1 word over ~1.05s ≈ 57 WPM. If duration were the trimmed sliver,
        // WPM would be ~86. Assert it stays at the un-inflated full-capture rate.
        #expect(outcome.stats.wordsPerMinute < 70)
    }

    // Sanity: with no trimmer injected (the default), behavior is unchanged —
    // the full clip transcribes and no vad guard fires.
    @Test func testNoTrimmerLeavesPipelineUnchanged() async throws {
        let db = try LisperDatabase(queue: DatabaseQueue())
        let guardLog = GuardLog()
        let samples = silence(seconds: 0.5) + tone(seconds: 1.0) + silence(seconds: 0.5)
        let p = DictationPipeline(
            primarySTT: FixedSTT(name: "groq", result: "um hello world"), fallbackSTT: nil,
            llmCleanup: nil, ruleCleanup: RuleCleanupEngine(), database: db, guardLog: guardLog)
        let outcome = try await p.process(audio: CapturedAudio(samples: samples, sampleRate: sr),
                                          context: ctx(), customFillers: [])
        #expect(outcome.rawTranscript == "um hello world")
        #expect(!guardLog.all().contains("vadTrimmed"))
        let saved = try db.recentSessions(limit: 5)
        #expect(saved[0].durationSeconds > 1.9)   // full 2.0s preserved, no trim
    }

    // (d) The recorder keeps the mic open 0.3 s after the stop press. That tail must not turn an
    // accidental tap (a missed Fn→Space lock: ~0.29 s held, speech-level) into a pasted fragment:
    // "too short" is judged on how long the key was held.
    @Test func testStopTailDoesNotRescueAnAccidentalTap() async throws {
        let db = try LisperDatabase(queue: DatabaseQueue())
        let samples = tone(seconds: 0.29, amplitude: 0.03) + tone(seconds: 0.3, amplitude: 0.03)
        let p = makePipeline(stt: FixedSTT(name: "groq", result: "So"), guardLog: GuardLog(), db: db)
        await #expect(throws: PipelineError.tooShort) {
            _ = try await p.process(audio: CapturedAudio(samples: samples, sampleRate: sr),
                                    context: ctx(), customFillers: [], heldSeconds: 0.29)
        }
    }

    // (e) Coaching numbers describe the time the key was held, not the stop tail.
    @Test func testStatsUseTheHeldDurationNotTheStopTail() async throws {
        let db = try LisperDatabase(queue: DatabaseQueue())
        let samples = silence(seconds: 0.5) + tone(seconds: 1.0) + silence(seconds: 0.8)   // 2.3 s
        let p = makePipeline(stt: FixedSTT(name: "groq", result: "um hello world"), guardLog: GuardLog(), db: db)
        let outcome = try await p.process(audio: CapturedAudio(samples: samples, sampleRate: sr),
                                          context: ctx(), customFillers: [], heldSeconds: 2.0)
        let saved = try db.recentSessions(limit: 5)
        #expect(abs(saved[0].durationSeconds - 2.0) < 0.01)
        #expect(abs(outcome.stats.wordsPerMinute - 90) < 1)   // 3 words over 2.0 s
    }

    // (f) rms describes the held take too: "0.0 s, rms 0" is how a vanished (empty) capture is
    // spotted in dictations.jsonl, and the stop tail must not fill that in.
    @Test func testRmsIgnoresTheStopTail() async throws {
        let db = try LisperDatabase(queue: DatabaseQueue())
        let samples = tone(seconds: 1.0, amplitude: 0.1) + tone(seconds: 0.3, amplitude: 0.02)
        let p = makePipeline(stt: FixedSTT(name: "groq", result: "hello there"), guardLog: GuardLog(), db: db)
        let outcome = try await p.process(audio: CapturedAudio(samples: samples, sampleRate: sr),
                                          context: ctx(), customFillers: [], heldSeconds: 1.0)
        #expect(abs(outcome.rms - 0.1) < 0.001)
    }

    // (g) Speech only in the stop tail (said after the press) and a start-up click: the held take
    // is silence. Judged on the whole clip, the gate passed and the trimmer — which ignores the
    // tail — uploaded the lone click, Whisper's classic input for "Thank you.".
    @Test func testSpeechOnlyAfterTheStopPressIsSilence() async throws {
        let db = try LisperDatabase(queue: DatabaseQueue())
        let samples = tone(seconds: 0.05, amplitude: 0.05) + tone(seconds: 0.75, amplitude: 0.0005)
            + tone(seconds: 0.3, amplitude: 0.03)
        let p = makePipeline(stt: FixedSTT(name: "groq", result: "Thank you."), guardLog: GuardLog(), db: db)
        await #expect(throws: PipelineError.tooShort) {
            _ = try await p.process(audio: CapturedAudio(samples: samples, sampleRate: sr),
                                    context: ctx(), customFillers: [], heldSeconds: 0.8)
        }
    }
}
