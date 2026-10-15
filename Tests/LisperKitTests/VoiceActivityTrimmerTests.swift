import Testing
@testable import LisperKit

@Suite struct VoiceActivityTrimmerTests {

    private let sr: Double = 16_000

    /// "Speech" = an alternating ±0.3 square wave (RMS 0.3, well above the floor).
    private func tone(seconds: Double, amplitude: Float = 0.3) -> [Float] {
        let n = Int(seconds * sr)
        return (0..<n).map { $0 % 2 == 0 ? amplitude : -amplitude }
    }

    private func silence(seconds: Double) -> [Float] {
        Array(repeating: 0, count: Int(seconds * sr))
    }

    // 1) [silence][speech][silence] -> 0.1 s lead-in + [speech] + 1.0 s tail
    @Test func testTrimsLeadingAndTrailingSilence() {
        let samples = silence(seconds: 0.5) + tone(seconds: 1.0) + silence(seconds: 2.0)
        let trimmer = EnergyVoiceActivityTrimmer()
        let out = trimmer.trim(CapturedAudio(samples: samples, sampleRate: sr))
        // Original is 3.5 s; speech is 1.0 s. Keep 0.1 s before it and 1.0 s after it.
        #expect(out.durationSeconds < 2.2)
        #expect(out.durationSeconds > 2.0)
        // Result is meaningfully shorter than the original 3.5 s.
        #expect(out.samples.count < samples.count)
    }

    // 2a) fully-silent (all zero) -> empty
    @Test func testAllZeroReturnsEmpty() {
        let trimmer = EnergyVoiceActivityTrimmer()
        let out = trimmer.trim(CapturedAudio(samples: silence(seconds: 2.0), sampleRate: sr))
        #expect(out.samples.isEmpty)
    }

    // 2b) sub-silenceRMS noise -> empty
    @Test func testSubSilenceNoiseReturnsEmpty() {
        // ~0.001 amplitude room tone, below AudioGate.silenceRMS (0.008).
        let n = Int(2.0 * sr)
        let noise: [Float] = (0..<n).map { $0 % 2 == 0 ? Float(0.001) : -0.001 }
        let trimmer = EnergyVoiceActivityTrimmer()
        let out = trimmer.trim(CapturedAudio(samples: noise, sampleRate: sr))
        #expect(out.samples.isEmpty)
    }

    // 3) all-speech (no surrounding silence) -> unchanged
    @Test func testPureSpeechIsNotOverTrimmed() {
        let samples = tone(seconds: 1.0)
        let trimmer = EnergyVoiceActivityTrimmer()
        let out = trimmer.trim(CapturedAudio(samples: samples, sampleRate: sr))
        // Every frame clears the threshold, so the kept span is the whole clip and
        // the padding clamps to the bounds — the trimmer returns the input exactly.
        #expect(out.samples.count == samples.count)
    }

    // 3b) sub-one-frame inputs must not crash and must return something sane:
    // a short tone burst survives (non-empty), the same length of zeros is empty.
    @Test func testVeryShortInputDoesNotCrash() {
        let trimmer = EnergyVoiceActivityTrimmer()
        // 100 samples (well under one 400-sample frame) of tone.
        let toneBlip: [Float] = (0..<100).map { $0 % 2 == 0 ? Float(0.3) : -0.3 }
        let toneOut = trimmer.trim(CapturedAudio(samples: toneBlip, sampleRate: sr))
        #expect(!toneOut.samples.isEmpty)
        // 100 samples of silence -> empty (no frame clears the floor).
        let silenceOut = trimmer.trim(CapturedAudio(samples: silence(seconds: 100.0 / sr),
                                                     sampleRate: sr))
        #expect(silenceOut.samples.isEmpty)
    }

    // 4) internal pause preserved: [speech][short silence][speech] keeps both + the gap
    @Test func testInternalPausePreserved() {
        let speechA = tone(seconds: 0.6)
        let gap = silence(seconds: 0.4)
        let speechB = tone(seconds: 0.6)
        let samples = silence(seconds: 0.5) + speechA + gap + speechB + silence(seconds: 2.0)
        let trimmer = EnergyVoiceActivityTrimmer()
        let out = trimmer.trim(CapturedAudio(samples: samples, sampleRate: sr))
        // Span from first speech to last speech is ~1.6s (0.6 + 0.4 + 0.6). The
        // internal 0.4s gap must NOT be removed, so the result keeps the full span
        // (+ 0.1 s lead-in and 1.0 s tail).
        #expect(out.durationSeconds > 2.6)
        #expect(out.durationSeconds < 2.8)   // the rest of the leading/trailing silence is gone
    }

    // 5) very short speech surrounded by silence is preserved
    @Test func testVeryShortSpeechPreserved() {
        let samples = silence(seconds: 0.5) + tone(seconds: 0.12) + silence(seconds: 2.0)
        let trimmer = EnergyVoiceActivityTrimmer()
        let out = trimmer.trim(CapturedAudio(samples: samples, sampleRate: sr))
        #expect(!out.samples.isEmpty)
        // The short burst (plus padding) survives but the other ~1.4 s of silence is gone.
        #expect(out.durationSeconds < 1.3)
    }

    // 7) a quiet trailing phrase must NOT be trimmed off the end.
    @Test func testQuietSpeechTailSurvivesTrimming() {
        // Session 1216 (64.7 s): speech ran at full level to 64.0 s, but the tail sat at
        // RMS ~0.003–0.008 because the input slider was at 39%. The absolute 0.008 floor
        // dominated the peak-relative term (peak*0.1 was only 0.0016), so the trimmer cut
        // 3.59 s of real speech off the end and the transcript ended mid-phrase
        // ("…you're you're doing"). The threshold must adapt to the clip's own noise floor.
        let samples = silence(seconds: 0.5)
            + tone(seconds: 2.0, amplitude: 0.02)    // loud-ish opening
            + tone(seconds: 2.0, amplitude: 0.005)   // quiet trailing phrase (sub-0.008)
            + silence(seconds: 2.0)
        let trimmer = EnergyVoiceActivityTrimmer()
        let out = trimmer.trim(CapturedAudio(samples: samples, sampleRate: sr))
        // The full 4.0 s of speech must survive (+ 0.1 s lead-in, 1.0 s tail).
        #expect(out.durationSeconds > 5.0)
        #expect(out.durationSeconds < 5.2)
    }

    // 6) empty input -> empty output, no crash
    @Test func testEmptyInputReturnsEmpty() {
        let trimmer = EnergyVoiceActivityTrimmer()
        let out = trimmer.trim(CapturedAudio(samples: [], sampleRate: sr))
        #expect(out.samples.isEmpty)
        #expect(out.sampleRate == sr)
    }

    /// Session 3095: one 50 ms bump (RMS 0.32) at 16.4 s set the threshold to 10% of the
    /// loudest frame — above the user's real speech (~0.02–0.05) — and the trimmer threw
    /// away everything after its last "speech" frame. A transient must not set the bar.
    @Test func testSingleTransientDoesNotTrimRealSpeech() {
        // Real speech has gaps between syllables (session 3095: speech ~0.03, its 10th-percentile
        // frame 0.002) — so the clip's noise floor sits well under the speech, as it does here.
        func speechLike(seconds: Double) -> [Float] {
            var out: [Float] = []
            while Double(out.count) < seconds * sr {
                out += tone(seconds: 0.25, amplitude: 0.03) + tone(seconds: 0.08, amplitude: 0.002)
            }
            return Array(out.prefix(Int(seconds * sr)))
        }
        let roomTone = tone(seconds: 0.5, amplitude: 0.002)
        let speech = speechLike(seconds: 16.0)
        let bump = tone(seconds: 0.05, amplitude: 0.32)
        let moreSpeech = speechLike(seconds: 5.0)
        let samples = roomTone + speech + bump + moreSpeech + roomTone + roomTone + roomTone
        let out = EnergyVoiceActivityTrimmer().trim(CapturedAudio(samples: samples, sampleRate: sr))
        #expect(out.durationSeconds > 22.0)   // all 21.05 s of speech kept (+ 0.1 s / 1.0 s), room tone trimmed
        #expect(out.durationSeconds < 22.3)
    }

    /// Syllables at `level` separated by room-tone gaps, like real speech (its quietest frames
    /// sit at the room's noise floor). `bursts` adds loud 0.3 s plosive/close-mic spikes —
    /// together longer than the 150 ms `AudioGate.robustPeak` sets aside as a transient.
    private func phrase(seconds: Double, level: Float, bursts: Int = 0, roomTone: Float = 0.0005) -> [Float] {
        var out: [Float] = []
        for _ in 0..<bursts { out += tone(seconds: 0.3, amplitude: 0.25) + tone(seconds: 0.08, amplitude: roomTone) }
        while Double(out.count) < seconds * sr {
            out += tone(seconds: 0.25, amplitude: level) + tone(seconds: 0.08, amplitude: roomTone)
        }
        return Array(out.prefix(Int(seconds * sr)))
    }

    /// Sessions 3381/3384/3308 (2026-10-11/12): loud bursts set the robust peak at ~0.22, so
    /// the 10%-of-peak threshold (0.022) sat above the user's trailing-off closing phrase
    /// (~0.005–0.015, still 10–30x the 0.0005 room tone) and the trimmer threw away its last
    /// 5–6 s. Whisper then never heard "…at the bottom. There's no need to say…".
    @Test func testQuietClosingPhraseAfterLoudSpeechSurvives() {
        let room = tone(seconds: 0.5, amplitude: 0.0005)
        let samples = room
            + phrase(seconds: 6.0, level: 0.03, bursts: 2)   // loud opening, plosive spikes
            + tone(seconds: 1.2, amplitude: 0.0005)          // pause between sentences
            + phrase(seconds: 4.0, level: 0.008)             // trailing-off last sentence
            + tone(seconds: 2.0, amplitude: 0.0005)
        let out = EnergyVoiceActivityTrimmer().trim(CapturedAudio(samples: samples, sampleRate: sr))
        // All 11.2 s from the first syllable to the end of the quiet sentence must survive
        // (+ 0.1 s lead-in, 1.0 s tail). Before the fix only ~6.2 s did.
        #expect(out.durationSeconds > 12.2)
        #expect(out.durationSeconds < 12.4)
    }

    /// Mirror image (sessions 3378/3379/3384): a quiet opening phrase before loud speech was
    /// cut, so "It turns out… and" reached Whisper as just "and".
    @Test func testQuietOpeningPhraseBeforeLoudSpeechSurvives() {
        let room = tone(seconds: 0.5, amplitude: 0.0005)
        let samples = room
            + phrase(seconds: 1.5, level: 0.008)             // quiet first words
            + tone(seconds: 0.6, amplitude: 0.0005)
            + phrase(seconds: 3.0, level: 0.03, bursts: 2)   // loud rest of the take
            + tone(seconds: 2.0, amplitude: 0.0005)
        let out = EnergyVoiceActivityTrimmer().trim(CapturedAudio(samples: samples, sampleRate: sr))
        // 1.5 + 0.6 + 3.0 s of speech (+ 0.1 s lead-in, 1.0 s tail). Before the fix ~3.2 s.
        #expect(out.durationSeconds > 6.1)
        #expect(out.durationSeconds < 6.3)
    }

    /// Mic start-up blips must not be mistaken for speech (sessions 3385/3391: a single 25 ms
    /// frame at ~4–8x room tone). Keeping one would hand Whisper the whole leading pause —
    /// the dead air it hallucinates over.
    @Test func testStartupBlipDoesNotKeepLeadingSilence() {
        let samples = tone(seconds: 0.025, amplitude: 0.0025) // start-up blip, 5x room tone
            + tone(seconds: 1.5, amplitude: 0.0005)           // leading pause
            + phrase(seconds: 3.0, level: 0.03)
            + tone(seconds: 2.0, amplitude: 0.0005)
        let out = EnergyVoiceActivityTrimmer().trim(CapturedAudio(samples: samples, sampleRate: sr))
        // 3.0 s of speech + 0.1 s lead-in + 1.0 s tail; the blip and the 1.5 s pause are gone.
        #expect(out.durationSeconds < 4.2)
        #expect(out.durationSeconds > 4.0)
    }

    /// Session 3314: the start-up transient decayed over four frames (0.0021 → 0.0014 against
    /// 0.000345 room tone), long enough to pass as a run of quiet speech, and 1.9 s of dead air
    /// went to Whisper ahead of the first word.
    @Test func testMultiFrameStartupTransientDoesNotKeepLeadingSilence() {
        let room: Float = 0.000345
        let blip = [Float(0.0021), 0.0023, 0.0019, 0.0014].flatMap { tone(seconds: 0.025, amplitude: $0) }
        let samples = blip
            + tone(seconds: 1.9, amplitude: room)
            + phrase(seconds: 3.0, level: 0.03, roomTone: room)
            + tone(seconds: 2.0, amplitude: room)
        let out = EnergyVoiceActivityTrimmer().trim(CapturedAudio(samples: samples, sampleRate: sr))
        // 3.0 s of speech + 0.1 s lead-in + 1.0 s tail; the transient and the 1.9 s pause are gone.
        #expect(out.durationSeconds > 4.0)
        #expect(out.durationSeconds < 4.2)
    }

    /// A 25 ms blip that straddles a frame boundary lights up two frames at ~5.7x room tone —
    /// a "run", but still only 50 ms long, so it is a click, not speech.
    @Test func testOffGridStartupBlipDoesNotKeepLeadingSilence() {
        let samples = tone(seconds: 0.0125, amplitude: 0.0005)
            + tone(seconds: 0.025, amplitude: 0.004)          // 8x room tone, off the frame grid
            + tone(seconds: 1.5, amplitude: 0.0005)
            + phrase(seconds: 3.0, level: 0.03)
            + tone(seconds: 2.0, amplitude: 0.0005)
        let out = EnergyVoiceActivityTrimmer().trim(CapturedAudio(samples: samples, sampleRate: sr))
        #expect(out.durationSeconds > 4.0)
        #expect(out.durationSeconds < 4.2)
    }

    /// 44 of 361 saved takes open with exact zeros while the mic warms up. When those are 10% of
    /// the frames the noise floor reads 0, the quiet-speech bar collapses under the room tone,
    /// and every second of trailing room tone was sent as "speech".
    @Test func testLeadingDigitalSilenceDoesNotDisableTailTrimming() {
        let samples = silence(seconds: 0.6)
            + phrase(seconds: 1.0, level: 0.03)
            + tone(seconds: 4.0, amplitude: 0.0005)
        let out = EnergyVoiceActivityTrimmer().trim(CapturedAudio(samples: samples, sampleRate: sr))
        // 1.0 s of speech + 0.1 s lead-in + 1.0 s tail; the other 3 s of room tone are gone.
        #expect(out.durationSeconds > 2.0)
        #expect(out.durationSeconds < 2.2)
    }

    /// Quiet speech made of short syllables (100 ms, with 50 ms gaps) still counts: the gaps
    /// inside a phrase are far shorter than the pause around a click.
    @Test func testQuietPhraseOfShortSyllablesSurvives() {
        var quiet: [Float] = []
        while Double(quiet.count) < 2.0 * sr {
            quiet += tone(seconds: 0.1, amplitude: 0.008) + tone(seconds: 0.05, amplitude: 0.0005)
        }
        let samples = tone(seconds: 0.5, amplitude: 0.0005)
            + phrase(seconds: 3.0, level: 0.03, bursts: 2)
            + tone(seconds: 1.2, amplitude: 0.0005)
            + Array(quiet.prefix(Int(2.0 * sr)))
            + tone(seconds: 2.0, amplitude: 0.0005)
        let out = EnergyVoiceActivityTrimmer().trim(CapturedAudio(samples: samples, sampleRate: sr))
        // 3.0 + 1.2 + 2.0 s of speech (+ 0.1 s lead-in, 1.0 s tail).
        #expect(out.durationSeconds > 7.2)
        #expect(out.durationSeconds < 7.4)
    }

    /// The trimmed clip says where its speech ends, so the ending check can tell words the user
    /// said from what Whisper hears in the trailing pad.
    @Test func testTrimReportsWhereSpeechEndsInTheClip() {
        let samples = silence(seconds: 0.5) + tone(seconds: 1.0) + silence(seconds: 2.0)
        let out = EnergyVoiceActivityTrimmer().trim(CapturedAudio(samples: samples, sampleRate: sr))
        // The clip starts 0.1 s before the speech (at 0.4 s); speech ends at 1.5 s → 1.1 s in.
        #expect(abs((out.speechEndSeconds ?? -1) - 1.1) < 0.03)
        #expect(CapturedAudio(samples: samples, sampleRate: sr).speechEndSeconds == nil)
    }

    /// Session 3455: the mic stays open 0.3 s after the stop press, so it records the key's click.
    /// One loud frame after a 4 s pause made the trimmer send the whole pause to Whisper.
    @Test func testStopKeyClickAfterAPauseIsNotSpeech() {
        let room: Float = 0.0005
        let samples = tone(seconds: 0.5, amplitude: room)
            + phrase(seconds: 3.0, level: 0.03)
            + tone(seconds: 2.0, amplitude: room)
            + tone(seconds: 0.025, amplitude: 0.02)          // the key click, inside the stop tail
            + tone(seconds: 0.275, amplitude: room)
        // The key was pressed where the click's tail-recording starts: 0.5 + 3.0 + 2.0 s in.
        let out = EnergyVoiceActivityTrimmer().trim(CapturedAudio(samples: samples, sampleRate: sr,
                                                                  heldSeconds: 5.5))
        // 3.0 s of speech + 0.1 s lead-in + 1.0 s tail; the click and the rest of the pause are gone.
        #expect(out.durationSeconds > 4.0)
        #expect(out.durationSeconds < 4.2)
    }

    /// Session 3462: a pop as the mic opened anchored the clip at 0 s and sent 12.7 s of silence
    /// ahead of the first word.
    @Test func testMicStartupPopIsNotSpeech() {
        let room: Float = 0.0005
        let samples = tone(seconds: 0.025, amplitude: 0.05)  // the pop
            + tone(seconds: 3.0, amplitude: room)
            + phrase(seconds: 3.0, level: 0.03)
            + tone(seconds: 2.0, amplitude: room)
        let out = EnergyVoiceActivityTrimmer().trim(CapturedAudio(samples: samples, sampleRate: sr))
        #expect(out.durationSeconds > 4.0)
        #expect(out.durationSeconds < 4.2)
    }

    /// Session 3451: two clicks 100 ms apart (Fn, then the Space lock) are still one short click.
    @Test func testTwoQuickStartupClicksAreNotSpeech() {
        let room: Float = 0.0005
        let samples = tone(seconds: 0.075, amplitude: room)
            + tone(seconds: 0.025, amplitude: 0.05) + tone(seconds: 0.1, amplitude: room)
            + tone(seconds: 0.025, amplitude: 0.05)
            + tone(seconds: 2.0, amplitude: room)
            + phrase(seconds: 3.0, level: 0.03)
            + tone(seconds: 2.0, amplitude: room)
        let out = EnergyVoiceActivityTrimmer().trim(CapturedAudio(samples: samples, sampleRate: sr))
        #expect(out.durationSeconds > 4.0)
        #expect(out.durationSeconds < 4.2)
    }

    /// A real word said right as the mic opens lasts longer than a click and is kept.
    @Test func testShortFirstWordAtTheStartIsKept() {
        let room: Float = 0.0005
        let samples = phrase(seconds: 0.3, level: 0.03)       // "So,"
            + tone(seconds: 1.0, amplitude: room)
            + phrase(seconds: 3.0, level: 0.03)
            + tone(seconds: 2.0, amplitude: room)
        let out = EnergyVoiceActivityTrimmer().trim(CapturedAudio(samples: samples, sampleRate: sr))
        // 0.3 + 1.0 + 3.0 s from the first word to the last (+ 1.0 s tail; the lead-in clamps at 0).
        #expect(out.durationSeconds > 5.2)
        #expect(out.durationSeconds < 5.4)
    }

    /// Session 3169: a quick, quiet "yeah" (125 ms at 4–8x room tone) right before the stop press
    /// looks like a click by energy alone. Before the press, it is speech; only what starts after
    /// the press (in the stop tail) can be the key.
    @Test func testShortQuietLastWordBeforeTheStopPressIsKept() {
        let room: Float = 0.0005
        let samples = tone(seconds: 0.5, amplitude: room)
            + phrase(seconds: 3.0, level: 0.03)
            + tone(seconds: 1.5, amplitude: room)
            + tone(seconds: 0.125, amplitude: 0.0035)        // "yeah"
            + tone(seconds: 0.15, amplitude: room)
        let out = EnergyVoiceActivityTrimmer().trim(CapturedAudio(samples: samples, sampleRate: sr))
        // From 0.1 s before the first syllable to the end of the clip (5.275 s - 0.4 s), "yeah"
        // included. Without it the clip would stop 1.0 s after the phrase: 4.1 s.
        #expect(out.durationSeconds > 4.8)
    }

    /// Speech that runs through the stop press is what the stop tail is for: keep it.
    @Test func testSpeechContinuingPastTheStopPressIsKept() {
        let room: Float = 0.0005
        let samples = tone(seconds: 0.5, amplitude: room)
            + phrase(seconds: 3.3, level: 0.03)              // the last word ends 0.3 s after the press
            + tone(seconds: 0.2, amplitude: room)
        let out = EnergyVoiceActivityTrimmer().trim(CapturedAudio(samples: samples, sampleRate: sr,
                                                                  heldSeconds: 3.5))
        #expect(out.durationSeconds > 3.55)                  // all 3.3 s of speech + lead-in + what's left
    }
}
