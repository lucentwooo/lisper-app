import Foundation

/// Trims leading/trailing non-speech from a capture before it reaches Whisper.
///
/// Silence-on-input is Whisper's #1 hallucination trigger ("Thank you.", prompt
/// regurgitation), and dead air is pure upload latency/cost. Cutting the quiet
/// edges proactively kills the hallucination at the source. Internal pauses are
/// LEFT INTACT — they carry coaching signal and natural rhythm; only the leading
/// and trailing edges are trimmed.
///
/// A future Silero CoreML model will conform to this same protocol app-side, so
/// the pipeline never needs to know which trimmer it holds.
public protocol VoiceActivityTrimmer: Sendable {
    /// Trim leading/trailing non-speech from a capture, returning only the
    /// speech-bearing span. If no speech is detected, returns a CapturedAudio
    /// with empty samples (the caller gates it as silence).
    func trim(_ audio: CapturedAudio) -> CapturedAudio
}

/// Pure-Swift, energy-based trimmer. Fully unit-testable (no audio frameworks).
///
/// Algorithm:
///  1. Window samples into short frames and take each frame's RMS (reusing
///     `AudioGate.rms` so it matches the existing silence gate).
///  2. Threshold comes from `AudioGate.speechThreshold` — peak-relative, floored by the
///     clip's OWN noise floor (see AudioGate). It must never be a fixed absolute RMS: at
///     39% input volume the old `max(AudioGate.silenceRMS, peak * thresholdFraction)`
///     collapsed to the constant 0.008 (peak*0.1 was only 0.0016), so only 4.4% of frames
///     cleared it and a real 64 s take had 3.59 s of quiet trailing speech sheared off —
///     the transcript ended mid-phrase. A clip with no possible speech yields `nil` → empty.
///  3. Quiet speech counts too: a stretch of at least 150 ms of runs above
///     `AudioGate.quietSpeechThreshold` (relative to the room tone, not the peak). Loud
///     bursts put 10% of the peak above a trailing-off last sentence, and the trimmer cut
///     5–6 s of real speech (sessions 3381/3384/3308: "…at the bottom. There's no need to say…").
///  4. Not speech: a lone click in the first half second (the mic's start-up pop), or anything
///     that only starts after the stop press (`CapturedAudio.heldSeconds` — the stop key's click).
///  5. Keep the span from the first to the last speech frame, plus `leadingPaddingSeconds`
///     before and `trailingPaddingSeconds` after. Internal sub-threshold frames are kept.
public struct EnergyVoiceActivityTrimmer: VoiceActivityTrimmer {
    /// Frame length in seconds (~20–30 ms). At 16 kHz, 0.025 s = 400 samples.
    public let frameSeconds: Double
    /// Speech threshold as a fraction of the loudest frame's RMS.
    public let thresholdFraction: Float
    /// Kept before the first speech frame (~80–150 ms) so onsets and soft consonants survive.
    public let leadingPaddingSeconds: Double
    /// Kept after the last speech frame. Long on purpose: in a noisy room the last words of a
    /// sentence that trails off sit AT the noise floor, where no energy test can find them
    /// (sessions 3119/3192/3196: "…internally testing", "…do that", "…and shortly" were cut).
    /// Whisper hallucinates over long silences, not over a second of room tone.
    public let trailingPaddingSeconds: Double
    /// Consecutive frames (50 ms) above the quiet bar that make a quiet run. Runs less than
    /// `quietSpeechMaxGapSeconds` apart join into one stretch, and a stretch counts only once it
    /// lasts `AudioGate.transientSeconds` (150 ms): a syllable run does, but a click or the mic's
    /// start-up blip does not. Session 3314's blip decayed over four frames and would otherwise
    /// have kept 1.9 s of dead air ahead of the first word.
    public let quietSpeechMinFrames: Int

    /// Longest dip that still joins two quiet runs into one stretch — the gap between syllables,
    /// far shorter than the pause around a click.
    static let quietSpeechMaxGapSeconds: Double = 0.1

    /// Start-up clicks (see `trim`): a burst shorter than `edgeClickMaxSeconds`, more than
    /// `edgeClickGapSeconds` from any other speech, wholly within the first `edgeZoneSeconds`
    /// of the capture. A real word lasts longer than 200 ms above the quiet bar.
    static let edgeClickMaxSeconds: Double = 0.2
    static let edgeClickGapSeconds: Double = 0.25
    static let edgeZoneSeconds: Double = 0.5

    public init(frameSeconds: Double = 0.025,
                thresholdFraction: Float = 0.1,
                leadingPaddingSeconds: Double = 0.1,
                trailingPaddingSeconds: Double = 1.0,
                quietSpeechMinFrames: Int = 2) {
        self.frameSeconds = frameSeconds
        self.thresholdFraction = thresholdFraction
        self.leadingPaddingSeconds = leadingPaddingSeconds
        self.trailingPaddingSeconds = trailingPaddingSeconds
        self.quietSpeechMinFrames = quietSpeechMinFrames
    }

    public func trim(_ audio: CapturedAudio) -> CapturedAudio {
        let samples = audio.samples
        guard let (firstSpeech, lastSpeech, frameLength) = speechFrames(audio) else {
            return CapturedAudio(samples: [], sampleRate: audio.sampleRate)
        }

        // Convert frame indices to sample indices, add padding, clamp to bounds.
        let lo = max(0, firstSpeech * frameLength - Int(leadingPaddingSeconds * audio.sampleRate))
        let speechEnd = min(samples.count, (lastSpeech + 1) * frameLength)
        let hi = min(samples.count, speechEnd + Int(trailingPaddingSeconds * audio.sampleRate))
        return CapturedAudio(samples: Array(samples[lo..<hi]), sampleRate: audio.sampleRate,
                             speechEndSeconds: Double(speechEnd - lo) / audio.sampleRate)
    }

    /// Where the last detected speech ends in `audio` itself (not in a trimmed copy), in seconds;
    /// nil when it holds no speech. For a clip that was sent untrimmed.
    public func speechEndSeconds(in audio: CapturedAudio) -> Double? {
        guard let (_, lastSpeech, frameLength) = speechFrames(audio) else { return nil }
        return Double(min(audio.samples.count, (lastSpeech + 1) * frameLength)) / audio.sampleRate
    }

    /// The first and last speech frames, or nil when the clip holds no speech.
    private func speechFrames(_ audio: CapturedAudio) -> (first: Int, last: Int, frameLength: Int)? {
        let samples = audio.samples
        guard !samples.isEmpty else { return nil }

        let frameLength = max(1, Int(frameSeconds * audio.sampleRate))

        // Per-frame RMS.
        let frameRMS = AudioGate.frameRMS(samples, frameLength: frameLength)

        // Thresholds relative to the clip's own noise floor. `nil` means the clip cannot
        // contain speech (true silence / room tone).
        guard let threshold = AudioGate.speechThreshold(frameRMS: frameRMS,
                                                        thresholdFraction: thresholdFraction,
                                                        frameSeconds: frameSeconds),
              let quietThreshold = AudioGate.quietSpeechThreshold(frameRMS: frameRMS,
                                                                  thresholdFraction: thresholdFraction,
                                                                  frameSeconds: frameSeconds)
        else { return nil }

        // Speech evidence: every frame above the speech threshold, and every quiet stretch.
        var evidence: [ClosedRange<Int>] = []
        // Quiet runs closer together than `maxGapFrames` form one stretch; a stretch counts as
        // speech only once it lasts `minStretchFrames` — a click or start-up blip never does.
        let minStretchFrames = max(quietSpeechMinFrames,
                                   Int((AudioGate.transientSeconds / frameSeconds).rounded()))
        let maxGapFrames = Int((Self.quietSpeechMaxGapSeconds / frameSeconds).rounded())
        var stretch: ClosedRange<Int>? = nil
        func closeStretch() {
            if let s = stretch, s.count >= minStretchFrames { evidence.append(s) }
            stretch = nil
        }
        var quietRun = 0
        for (i, r) in frameRMS.enumerated() {
            if r > threshold { evidence.append(i...i) }
            quietRun = r > quietThreshold ? quietRun + 1 : 0
            guard quietRun >= quietSpeechMinFrames else { continue }
            let runStart = i - quietRun + 1
            if let s = stretch, runStart - s.upperBound - 1 <= maxGapFrames {
                stretch = s.lowerBound...i
            } else {
                closeStretch()
                stretch = runStart...i
            }
        }
        closeStretch()
        // Anything that only STARTS after the stop press — in the stop tail — is the key's click
        // (3455: one loud frame kept a 4 s pause) or a word for something else. Speech running
        // through the press started before it, and stays.
        if let held = audio.heldSeconds {
            let heldFrames = Int(held / frameSeconds)
            evidence.removeAll { $0.lowerBound >= heldFrames }
        }
        guard !evidence.isEmpty else { return nil }

        // Bursts: evidence separated by more than `edgeClickGapSeconds` of non-speech.
        let gapFrames = Int((Self.edgeClickGapSeconds / frameSeconds).rounded())
        var bursts: [ClosedRange<Int>] = []
        for e in evidence.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = bursts.last, e.lowerBound - last.upperBound - 1 <= gapFrames {
                bursts[bursts.count - 1] = last.lowerBound...max(last.upperBound, e.upperBound)
            } else {
                bursts.append(e)
            }
        }
        // The mic's start-up pop or the hotkey's click: a lone burst shorter than a syllable,
        // wholly in the first half second. As a speech frame it anchored the span and kept the
        // whole pause after it (3462: 12.7 s of silence before the first word). Never the only
        // burst. Only the START: at the end, a quick quiet "yeah" before the press looks just
        // like a click (3169), and the stop key's click is handled by `heldSeconds` above.
        let clickFrames = Int((Self.edgeClickMaxSeconds / frameSeconds).rounded())
        let zoneFrames = Int((Self.edgeZoneSeconds / frameSeconds).rounded())
        while bursts.count > 1, bursts[0].count < clickFrames, bursts[0].upperBound < zoneFrames {
            bursts.removeFirst()
        }
        return (bursts[0].lowerBound, bursts[bursts.count - 1].upperBound, frameLength)
    }
}
