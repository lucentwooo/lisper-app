// Sources/LisperKit/Engines/SegmentConfidenceFilter.swift

/// Drops hallucinated Whisper segments using the model's *own* quality signals
/// (avg_logprob / no_speech_prob / compression_ratio from a `verbose_json` response),
/// instead of pattern-matching the final text. Catches the two dominant failure modes:
///   - non-speech / silence tails (high no_speech_prob AND low confidence), and
///   - repetition loops (high compression_ratio — "LisperYourAds…", "Crap, Lid, Mace…").
///
/// Defaults mirror openai-whisper's decode thresholds (no_speech_threshold 0.6,
/// logprob_threshold -1.0, compression_ratio_threshold 2.4), which are conservative —
/// real speech segments sit well inside them, so genuine words are not dropped.
public enum SegmentConfidenceFilter {
    public struct Thresholds: Sendable {
        public var noSpeechProb: Double
        public var avgLogprob: Double
        public var compressionRatio: Double
        public init(noSpeechProb: Double = 0.6, avgLogprob: Double = -1.0, compressionRatio: Double = 2.4) {
            self.noSpeechProb = noSpeechProb
            self.avgLogprob = avgLogprob
            self.compressionRatio = compressionRatio
        }
    }

    /// A segment looks hallucinated when it is non-speech (high no_speech_prob AND low
    /// confidence — high confidence overrides, matching Whisper) OR a repetition loop
    /// (compression_ratio above threshold).
    public static func isHallucinated(_ s: WhisperSegment, _ t: Thresholds = .init()) -> Bool {
        let nonSpeech = s.noSpeechProb > t.noSpeechProb && s.avgLogprob < t.avgLogprob
        let loop = s.compressionRatio > t.compressionRatio
        return nonSpeech || loop
    }

    /// Returns the rejoined text of the surviving segments. If everything is dropped
    /// (whole-clip hallucination) returns "" so the caller can degrade rather than paste garbage.
    public static func filter(_ segments: [WhisperSegment], thresholds: Thresholds = .init()) -> String {
        segments
            .filter { !isHallucinated($0, thresholds) }
            .map(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
