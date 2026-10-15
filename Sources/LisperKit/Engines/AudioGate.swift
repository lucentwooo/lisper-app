import Foundation

/// Cheap energy gate that rejects silent / near-silent captures before they ever
/// reach Whisper. On non-speech input Whisper invents text ("Thank you.", or it
/// regurgitates its prompt), so the safest fix is to never transcribe silence.
///
/// The speech/silence decision is **relative to each clip's own noise floor**, never
/// an absolute RMS. An absolute floor silently encodes one particular input gain: when
/// the macOS input-volume slider drifted to 39%, speech landed at RMS ~0.005 — under the
/// old fixed 0.008 floor — and real takes were discarded as "too short" while the
/// trimmer sheared seconds of quiet speech off the edges. Measured across real captures
/// the peak-to-noise-floor ratio is 11x–1180x even for 1-second single-word takes, so
/// an SNR-relative test separates speech from room tone with a wide margin at any gain.
public enum AudioGate {
    /// Nominal speech floor at the *reference* input gain (~0.023 median RMS) this app
    /// was first calibrated against. **Not a gate** — nothing thresholds on it; it is
    /// kept as the documented reference level that the adaptive logic replaced.
    public static let silenceRMS: Float = 0.008

    /// Window for the speech-energy test (~30 ms at 16 kHz). Short enough that a brief
    /// utterance lights up several windows, long enough to be a stable RMS estimate.
    public static let speechWindowSeconds: Double = 0.03

    /// A clip needs at least this many speech-level windows (~90 ms total) to count as
    /// non-silent. Below this is an isolated transient (a keyboard click / pop), not
    /// speech — so a stray click can't sneak past, yet even a one-word take clears it.
    public static let minSpeechWindows: Int = 3

    /// The clip's noise floor is the Nth percentile of frame RMS. Low enough to land in
    /// genuine room tone even when the clip is mostly speech.
    public static let noiseFloorPercentile: Double = 0.10

    /// Speech must exceed the clip's own noise floor by this factor. Real captures show
    /// a peak-to-floor ratio of 11x at worst, so 3x rejects room tone with room to spare.
    public static let speechSNR: Float = 3.0

    /// The adaptive threshold is capped at this fraction of the loudest frame. Without the
    /// cap a clip that is *uniformly* speech (no pauses, so the noise-floor estimate lands
    /// on speech itself) would set a threshold above its own peak and be called silent.
    public static let maxThresholdFraction: Float = 0.5

    /// Absolute backstop: a clip whose loudest frame is below this contains no speech at
    /// any plausible gain. Load-bearing for pure room tone, where noise ≈ peak makes the
    /// SNR test alone indecisive. Sits ~2x above observed room-tone peaks (~0.0018) and
    /// ~3x below the quietest observed real speech peak (0.0118).
    public static let minSpeechPeak: Float = 0.004

    /// The clip's "peak" ignores its loudest ~150 ms. A click, bump or pop lasts a frame or
    /// two (session 3095: a 50 ms bump at RMS 0.32 against speech at ~0.03); taken as the
    /// peak it lifted the threshold above the user's real speech, so the trimmer cut the
    /// take short and the gate could call it silent. Real speech always outlasts this.
    public static let transientSeconds: Double = 0.15

    /// Quiet speech must clear the clip's own noise floor by this factor. Not a peak ratio:
    /// one take spans more than 20 dB — plosive bursts at ~0.22, a trailing-off last sentence
    /// at ~0.008 — so 10% of the peak sat above whole sentences (sessions 3381/3384/3308) while
    /// they were still 10–30x the room tone.
    public static let quietSpeechSNR: Float = 4.0

    /// Quiet speech is never judged below this fraction of the peak, so a near-zero noise floor
    /// can't drag the bar down to dither.
    public static let quietSpeechPeakFraction: Float = 0.01

    /// Frames below this are digital silence (the zeros a mic emits while it warms up), not room
    /// tone. Real room tone sits at ~3e-4; the quietest non-zero frame in any saved take is ~2e-6.
    public static let digitalSilenceRMS: Float = 1e-5

    /// The loudest frame once the top `transientSeconds` are set aside — never more than a
    /// tenth of the clip, so a short take's own speech is never skipped as a "transient".
    static func robustPeak(sortedAscending sorted: [Float], frameSeconds: Double) -> Float {
        let skip = min(Int(transientSeconds / frameSeconds), sorted.count / 10)
        return sorted[sorted.count - 1 - skip]
    }

    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Per-frame RMS over consecutive (non-overlapping) frames of `frameLength` samples.
    public static func frameRMS(_ samples: [Float], frameLength: Int) -> [Float] {
        guard !samples.isEmpty, frameLength > 0 else { return [] }
        var frames: [Float] = []
        frames.reserveCapacity(samples.count / frameLength + 1)
        var start = 0
        while start < samples.count {
            let end = min(start + frameLength, samples.count)
            frames.append(rms(Array(samples[start..<end])))
            start = end
        }
        return frames
    }

    /// The RMS above which a frame counts as speech, derived from the clip itself.
    ///
    /// Returns `nil` when the clip cannot contain speech at all (loudest frame below
    /// `minSpeechPeak`), which callers treat as silence.
    ///
    /// `threshold = max(peak * thresholdFraction, min(noiseFloor * speechSNR, peak * maxThresholdFraction))`
    /// where `peak` is the `robustPeak` (transients set aside).
    ///
    /// The peak-relative term preserves the previous behaviour on loud clips; the
    /// noise-floor term is what adapts to a quiet mic; the cap keeps an all-speech clip
    /// from thresholding itself out of existence.
    public static func speechThreshold(frameRMS frames: [Float], thresholdFraction: Float,
                                       frameSeconds: Double = speechWindowSeconds) -> Float? {
        guard let (noiseFloor, peak) = levels(frameRMS: frames, frameSeconds: frameSeconds) else {
            return nil
        }
        let adaptive = min(noiseFloor * speechSNR, peak * maxThresholdFraction)
        return max(peak * thresholdFraction, adaptive)
    }

    /// The RMS above which a SUSTAINED run of frames counts as (quiet) speech:
    /// `min(speechThreshold, max(roomTone * quietSpeechSNR, peak * quietSpeechPeakFraction))`.
    /// Only for finding where speech starts and ends — callers must require speech-length
    /// stretches, because a click or the mic's start-up blip clears it too.
    ///
    /// `roomTone` is the noise floor with digital silence left out. The mic's warm-up zeros can
    /// make up 10% of a short take; counted in, they put the floor at 0, the bar fell under the
    /// room tone, and every second of trailing room tone was kept as "speech".
    public static func quietSpeechThreshold(frameRMS frames: [Float], thresholdFraction: Float,
                                            frameSeconds: Double = speechWindowSeconds) -> Float? {
        guard let (noiseFloor, peak) = levels(frameRMS: frames, frameSeconds: frameSeconds),
              let speech = speechThreshold(frameRMS: frames, thresholdFraction: thresholdFraction,
                                           frameSeconds: frameSeconds)
        else { return nil }
        let sound = frames.filter { $0 >= digitalSilenceRMS }.sorted()
        let roomTone = sound.isEmpty ? noiseFloor : sound[Int(noiseFloorPercentile * Double(sound.count - 1))]
        return min(speech, max(roomTone * quietSpeechSNR, peak * quietSpeechPeakFraction))
    }

    /// The clip's noise floor and peak (see `robustPeak`), or `nil` when that peak is below
    /// `minSpeechPeak`.
    private static func levels(frameRMS frames: [Float], frameSeconds: Double) -> (noiseFloor: Float, peak: Float)? {
        guard !frames.isEmpty else { return nil }
        let sorted = frames.sorted()
        let index = Int(noiseFloorPercentile * Double(sorted.count - 1))
        let noiseFloor = sorted[index]
        // Set the transient aside only when what remains is still clearly speech (at least the
        // SNR bar). If it isn't, the loudest frames ARE the only signal — a lone short word in
        // a long hold — or a click in a noisy room, and the raw max is the right reference:
        // using the robust peak there called the word silent and let the room noise through.
        // A robust peak of 0 is no signal at all: in digital silence (floor 0) "0 >= 3 * 0"
        // would set a lone word aside as a transient and call the take silent.
        let robust = robustPeak(sortedAscending: sorted, frameSeconds: frameSeconds)
        let peak = robust > 0 && robust >= noiseFloor * speechSNR ? robust : sorted[sorted.count - 1]
        guard peak >= minSpeechPeak else { return nil }
        return (noiseFloor, peak)
    }

    /// Number of ~30 ms windows that reach the clip's speech threshold.
    ///
    /// Counting WINDOWS — not the whole-clip MEAN — is the crux: a short sentence
    /// preceded (or followed) by a long thinking-pause has a mean RMS dragged *under*
    /// any floor by all that dead air, even though the speech itself is plainly loud.
    /// The speech windows themselves stay above the clip's own noise floor regardless of
    /// how much silence surrounds them; requiring several also rejects a lone transient.
    public static func speechWindowCount(_ audio: CapturedAudio) -> Int {
        let frameLength = max(1, Int(speechWindowSeconds * audio.sampleRate))
        let frames = frameRMS(audio.samples, frameLength: frameLength)
        guard let threshold = speechThreshold(frameRMS: frames, thresholdFraction: 0.1) else {
            return 0
        }
        return frames.reduce(into: 0) { count, r in if r >= threshold { count += 1 } }
    }

    public static func isLikelySilent(_ audio: CapturedAudio) -> Bool {
        speechWindowCount(audio) < minSpeechWindows
    }
}
