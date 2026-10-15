import Foundation
import Testing
@testable import LisperKit

/// GroqWhisperEngine runs a second model alongside the primary and appends any ending the
/// primary dropped (see EndingRecovery). A fake transcriber stands in for Groq.
@Suite struct EndingCheckEngineTests {

    private final class FakeWhisper: WhisperTranscriber, @unchecked Sendable {
        struct Reply {
            var text: String? = nil
            var delay: Double = 0
            /// (start seconds, text) per segment; nil = one segment at 0 s holding all of `text`.
            var segments: [(Double, String)]? = nil
            var noTiming = false
            var ignoresCancellation = false
        }
        private let lock = NSLock()
        private var calls: [String] = []
        let replies: [String: Reply]
        init(_ replies: [String: Reply]) { self.replies = replies }
        var models: [String] { lock.lock(); defer { lock.unlock() }; return calls }

        func transcribe(wav: Data, model: String, prompt: String?, language: String?,
                        temperature: Double) async throws -> WhisperResult {
            lock.withLock { calls.append(model) }
            let reply = replies[model] ?? Reply()
            if reply.ignoresCancellation {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { done.resume() }
                }
            } else if reply.delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(reply.delay * 1e9))
            }
            guard let text = reply.text else { throw EngineError.network("down") }
            if reply.noTiming { return WhisperResult(text: text, segments: []) }
            let segments = (reply.segments ?? [(0, text)]).map {
                WhisperSegment(text: $0.1, avgLogprob: -0.2, noSpeechProb: 0.01, compressionRatio: 1.2, start: $0.0)
            }
            return WhisperResult(text: text, segments: segments)
        }
    }

    private let audio = CapturedAudio(samples: Array(repeating: 0.1, count: 16_000))

    private func engine(_ fake: FakeWhisper, check: String?, grace: Double = 1.5,
                        log: GuardLog) -> GroqWhisperEngine {
        GroqWhisperEngine(transcriber: fake, model: "v3", language: "en", guardLog: log,
                          endingCheckModel: check, endingCheckGraceSeconds: grace)
    }

    @Test func testAppendsTheEndingThePrimaryDropped() async throws {
        let fake = FakeWhisper([
            "v3": .init(text: "If you have screenshots so that I can easily"),
            "turbo": .init(text: "If you have screenshots so that I can easily visually check them."),
        ])
        let log = GuardLog()
        let text = try await engine(fake, check: "turbo", log: log).transcribe(audio: audio, dictionaryTerms: [])
        #expect(text == "If you have screenshots so that I can easily visually check them.")
        #expect(log.all().contains("endingRecovered"))
        #expect(Set(fake.models) == ["v3", "turbo"])
    }

    @Test func testNoCheckModelMeansOneRequest() async throws {
        let fake = FakeWhisper(["v3": .init(text: "so that I can easily")])
        let text = try await engine(fake, check: nil, log: GuardLog()).transcribe(audio: audio, dictionaryTerms: [])
        #expect(text == "so that I can easily")
        #expect(fake.models == ["v3"])
    }

    @Test func testFailedCheckKeepsThePrimaryText() async throws {
        let fake = FakeWhisper(["v3": .init(text: "so that I can easily")])   // "turbo" throws
        let log = GuardLog()
        let text = try await engine(fake, check: "turbo", log: log).transcribe(audio: audio, dictionaryTerms: [])
        #expect(text == "so that I can easily")
        #expect(log.all().contains("endingCheckFailed"))
        #expect(!log.all().contains("endingRecovered"))
    }

    /// A slow checker must never hold up the paste for more than the grace period.
    @Test func testSlowCheckIsAbandonedAfterTheGracePeriod() async throws {
        let fake = FakeWhisper([
            "v3": .init(text: "so that I can easily"),
            "turbo": .init(text: "so that I can easily visually check them.", delay: 5),
        ])
        let log = GuardLog()
        let started = Date()
        let text = try await engine(fake, check: "turbo", grace: 0.05, log: log)
            .transcribe(audio: audio, dictionaryTerms: [])
        #expect(text == "so that I can easily")
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(log.all().contains("endingCheckTimedOut"))
    }

    @Test func testHallucinatingCheckerIsIgnored() async throws {
        let fake = FakeWhisper([
            "v3": .init(text: "so that I can easily"),
            "turbo": .init(text: "so that I can easily check check check check check check check check check"),
        ])
        let text = try await engine(fake, check: "turbo", log: GuardLog()).transcribe(audio: audio, dictionaryTerms: [])
        #expect(text == "so that I can easily")
    }

    /// Two uploads of a long take share the uplink; on a slow one the primary could then miss
    /// its 120 s budget. A long take gets the primary alone.
    @Test func testLongTakeSkipsTheCheck() async throws {
        let fake = FakeWhisper(["v3": .init(text: "so that I can easily"),
                                "turbo": .init(text: "so that I can easily visually check them.")])
        let long = CapturedAudio(samples: Array(repeating: 0.1, count: 16_000 * 61))
        let text = try await GroqWhisperEngine(transcriber: fake, model: "v3", language: "en", guardLog: GuardLog(),
                                               endingCheckModel: "turbo")
            .transcribe(audio: long, dictionaryTerms: [])
        #expect(text == "so that I can easily")
        #expect(fake.models == ["v3"])
    }

    /// Groq's segment times say WHERE the check model heard each phrase. Only words that begin
    /// before the trimmer's last detected speech are evidence; the second of room tone after it
    /// is where Whisper invents "Thank you." (session 3137).
    @Test func testOnlyWordsStartingBeforeSpeechEndsAreRecovered() async throws {
        let primary = "If you have screenshots so that I can easily"
        let fake = FakeWhisper([
            "v3": .init(text: primary),
            "turbo": .init(text: "unused", segments: [(0, primary), (5.0, " visually check them."), (6.2, " Thank you.")]),
        ])
        let clip = CapturedAudio(samples: Array(repeating: 0.1, count: 16_000 * 7), speechEndSeconds: 6.0)
        let text = try await engine(fake, check: "turbo", log: GuardLog()).transcribe(audio: clip, dictionaryTerms: [])
        #expect(text == "If you have screenshots so that I can easily visually check them.")
    }

    @Test func testSignOffAfterSpeechEndsIsNotRecovered() async throws {
        let primary = "any business lingo it should understand as well"
        let fake = FakeWhisper([
            "v3": .init(text: primary),
            "turbo": .init(text: "unused", segments: [(0, primary), (6.3, " Okay.")]),
        ])
        let log = GuardLog()
        let clip = CapturedAudio(samples: Array(repeating: 0.1, count: 16_000 * 7), speechEndSeconds: 6.0)
        let text = try await engine(fake, check: "turbo", log: log).transcribe(audio: clip, dictionaryTerms: [])
        #expect(text == primary)
        #expect(!log.all().contains("endingRecovered"))
    }

    /// Without segment times there is no way to tell speech from the trailing room tone.
    @Test func testCheckWithoutSegmentTimesRecoversNothing() async throws {
        let fake = FakeWhisper([
            "v3": .init(text: "so that I can easily"),
            "turbo": .init(text: "so that I can easily visually check them.", noTiming: true),
        ])
        let text = try await engine(fake, check: "turbo", log: GuardLog()).transcribe(audio: audio, dictionaryTerms: [])
        #expect(text == "so that I can easily")
    }

    /// The grace period is a hard limit even for a request that doesn't stop when cancelled.
    @Test func testGraceIsAHardLimitEvenIfTheCheckIgnoresCancellation() async throws {
        let fake = FakeWhisper([
            "v3": .init(text: "so that I can easily"),
            "turbo": .init(text: "so that I can easily visually check them.", delay: 3, ignoresCancellation: true),
        ])
        let started = Date()
        let text = try await engine(fake, check: "turbo", grace: 0.05, log: GuardLog())
            .transcribe(audio: audio, dictionaryTerms: [])
        #expect(text == "so that I can easily")
        #expect(Date().timeIntervalSince(started) < 1.5)
    }

    /// With silence trimming off the engine gets the raw take, and must measure where speech ends
    /// in THAT clip — not in a trimmed copy whose start was cut.
    @Test func testTimingGateWithoutTheTrimmerMeasuresTheUploadedClip() async throws {
        func tone(_ seconds: Double, _ a: Float) -> [Float] { (0..<Int(seconds * 16_000)).map { $0 % 2 == 0 ? a : -a } }
        var speech: [Float] = []
        while speech.count < 3 * 16_000 + 8_000 { speech += tone(0.25, 0.03) + tone(0.08, 0.0005) }
        let raw = CapturedAudio(samples: tone(1.5, 0.0005) + Array(speech.prefix(56_000)) + tone(1.0, 0.0005))
        let primary = "If you have screenshots so that I can easily"
        let fake = FakeWhisper([
            "v3": .init(text: primary),
            "turbo": .init(text: "unused", segments: [(1.5, primary), (4.4, " visually check them.")]),
        ])
        let text = try await engine(fake, check: "turbo", log: GuardLog()).transcribe(audio: raw, dictionaryTerms: [])
        #expect(text == "If you have screenshots so that I can easily visually check them.")
    }

    /// The primary's failure path is unchanged: nothing heard is still "nothing heard", even if
    /// the checker returned words (the pipeline then falls back to Apple's engine).
    @Test func testEmptyPrimaryStillThrows() async throws {
        let fake = FakeWhisper(["v3": .init(text: "  "), "turbo": .init(text: "hello there")])
        await #expect(throws: EngineError.emptyTranscript) {
            _ = try await engine(fake, check: "turbo", log: GuardLog()).transcribe(audio: audio, dictionaryTerms: [])
        }
    }
}
