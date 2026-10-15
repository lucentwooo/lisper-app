import Testing
@testable import LisperKit

@Suite struct AudioGateTests {

    @Test func testPureSilenceIsGated() {
        let silent = CapturedAudio(samples: Array(repeating: 0, count: 16_000))
        #expect(AudioGate.isLikelySilent(silent))
    }

    @Test func testMicNoiseFloorIsGated() {
        // ~0.001 amplitude room tone — below the speech floor.
        let noise = (0..<16_000).map { i in (i % 2 == 0 ? Float(0.001) : -0.001) }
        #expect(AudioGate.isLikelySilent(CapturedAudio(samples: noise)))
    }

    @Test func testSpeechLevelIsNotGated() {
        // A 0.1-amplitude square wave stands in for speech energy (RMS 0.1).
        let tone = (0..<16_000).map { i in (i % 2 == 0 ? Float(0.1) : -0.1) }
        #expect(!AudioGate.isLikelySilent(CapturedAudio(samples: tone)))
    }

    @Test func testShortSpeechAfterLongLeadingSilenceIsNotGated() {
        // Real-world failure (session 20:28:19Z, rms 0.007, guard "silence"): the user
        // thought for ~19 s then said one sentence. The WHOLE-CLIP MEAN rms is dragged
        // under the 0.008 floor by the dead air, so the mean-based gate dropped a take
        // that plainly contains speech. The loudest 30 ms window is unmistakable speech.
        let sr = 16_000
        var samples = (0..<(19 * sr)).map { i in (i % 2 == 0 ? Float(0.001) : -0.001) } // ~19 s room tone
        samples += (0..<(1 * sr)).map { i in (i % 2 == 0 ? Float(0.03) : -0.03) }        // ~1 s sentence
        let audio = CapturedAudio(samples: samples)
        #expect(AudioGate.rms(audio.samples) < AudioGate.silenceRMS)  // mean really is sub-floor…
        #expect(!AudioGate.isLikelySilent(audio))                     // …yet it is NOT silent.
    }

    @Test func testTrailingSilenceDoesNotGateSpeech() {
        // Symmetric: a sentence then a long trailing pause must also survive.
        let sr = 16_000
        var samples = (0..<(1 * sr)).map { i in (i % 2 == 0 ? Float(0.03) : -0.03) }
        samples += (0..<(19 * sr)).map { i in (i % 2 == 0 ? Float(0.001) : -0.001) }
        #expect(!AudioGate.isLikelySilent(CapturedAudio(samples: samples)))
    }

    @Test func testQuietMicSpeechIsNotGated() {
        // Real-world failure (2026-07-17 / 2026-08-01 clusters): the macOS input-volume
        // slider sat at 39%, so speech landed at RMS ~0.005 — BELOW the absolute 0.008
        // floor the gate was calibrated against at ~0.023 input. Every window failed the
        // fixed floor and real takes were discarded as "too short". Speech must be judged
        // relative to the clip's OWN noise floor, not an absolute level tied to one gain.
        let sr = 16_000
        var samples = (0..<sr).map { i in (i % 2 == 0 ? Float(0.0008) : -0.0008) }      // 1 s room tone
        samples += (0..<(2 * sr)).map { i in (i % 2 == 0 ? Float(0.005) : -0.005) }     // 2 s quiet speech
        samples += (0..<sr).map { i in (i % 2 == 0 ? Float(0.0008) : -0.0008) }         // 1 s room tone
        let audio = CapturedAudio(samples: samples)
        #expect(AudioGate.rms(audio.samples) < AudioGate.silenceRMS)  // whole clip is sub-floor…
        #expect(!AudioGate.isLikelySilent(audio))                     // …yet it is clearly speech.
    }

    @Test func testIsolatedTransientClickStaysGated() {
        // A single ~2 ms pop in otherwise-dead air is NOT speech: spread across a 30 ms
        // window its energy stays under the floor, so a stray click can't sneak past.
        let sr = 16_000
        var samples = Array(repeating: Float(0), count: 20 * sr)
        for i in 0..<32 { samples[5 * sr + i] = (i % 2 == 0 ? 0.2 : -0.2) }  // ~2 ms click
        #expect(AudioGate.isLikelySilent(CapturedAudio(samples: samples)))
    }

    /// The same bump must not make a quiet take read as near-silent either.
    @Test func testSingleTransientDoesNotGateQuietSpeech() {
        let sr = 16_000.0
        func tone(_ seconds: Double, _ a: Float) -> [Float] { (0..<Int(seconds * sr)).map { $0 % 2 == 0 ? a : -a } }
        let samples = tone(0.5, 0.0005) + tone(1.0, 0.012) + tone(0.05, 0.4) + tone(0.5, 0.0005)
        #expect(!AudioGate.isLikelySilent(CapturedAudio(samples: samples, sampleRate: sr)))
    }

    /// Setting the loudest ~150 ms aside must not let room noise pass as speech: an accidental
    /// tap with a key click in a noisy room (ambient ~0.005) was gated before and must stay so.
    @Test func testClickInNoisyRoomStaysGated() {
        let sr = 16_000.0
        func tone(_ seconds: Double, _ a: Float) -> [Float] { (0..<Int(seconds * sr)).map { $0 % 2 == 0 ? a : -a } }
        let ambient = (0..<Int(1.0 * sr)).map { i -> Float in (i % 2 == 0 ? 1 : -1) * (0.004 + 0.002 * Float((i / 400) % 2)) }
        let samples = Array(ambient[0..<8000]) + tone(0.03, 0.3) + Array(ambient[8000...])
        #expect(AudioGate.isLikelySilent(CapturedAudio(samples: samples, sampleRate: sr)))
    }

    /// A single short word in a long hold is speech, not a transient to set aside.
    @Test func testLoneShortWordInLongHoldIsNotGated() {
        let sr = 16_000.0
        func tone(_ seconds: Double, _ a: Float) -> [Float] { (0..<Int(seconds * sr)).map { $0 % 2 == 0 ? a : -a } }
        let samples = tone(5.0, 0.001) + tone(0.12, 0.05) + tone(5.0, 0.001)
        #expect(!AudioGate.isLikelySilent(CapturedAudio(samples: samples, sampleRate: sr)))
    }

    /// Same word, but surrounded by exact digital zeros (some inputs mute to true silence). The
    /// noise floor is 0, so "is the robust peak above 3x the floor?" read 0 >= 0 as yes, set
    /// the word itself aside as a transient, and called the clip silent.
    @Test func testLoneShortWordInDigitalSilenceIsNotGated() {
        let sr = 16_000.0
        func tone(_ seconds: Double, _ a: Float) -> [Float] { (0..<Int(seconds * sr)).map { $0 % 2 == 0 ? a : -a } }
        let samples = tone(0.5, 0) + tone(0.12, 0.05) + tone(2.0, 0)
        let silent = AudioGate.isLikelySilent(CapturedAudio(samples: samples, sampleRate: sr))
        #expect(!silent)
    }

    /// Speech at exactly 3x the room tone is still speech: the digital-silence fix above must not
    /// turn "at least 3x" into "more than 3x", or one click becomes the peak and sets the bar
    /// above the whole take.
    @Test func testRobustPeakExactlyAtSNRBarIsStillThePeak() {
        let floor: Float = 0.002
        let speech = floor * AudioGate.speechSNR
        let frames = Array(repeating: floor, count: 20) + Array(repeating: speech, count: 60) + [0.5, 0.5]
        let threshold = AudioGate.speechThreshold(frameRMS: frames, thresholdFraction: 0.1)
        #expect(threshold != nil)
        #expect((threshold ?? .infinity) < speech)
    }
}
