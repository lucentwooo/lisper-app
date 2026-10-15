import Testing
@testable import LisperKit

struct SegmentConfidenceFilterTests {
    // Healthy speech: confident, not silent, normal compression → kept.
    private func good(_ text: String) -> WhisperSegment {
        WhisperSegment(text: text, avgLogprob: -0.3, noSpeechProb: 0.02, compressionRatio: 1.5)
    }

    @Test func keepsHealthySpeech() {
        let segs = [good(" hello there"), good(" how are you")]
        #expect(SegmentConfidenceFilter.filter(segs) == "hello there how are you")
        #expect(!SegmentConfidenceFilter.isHallucinated(good(" hi")))
    }

    @Test func dropsRepetitionLoop() {
        // High compression ratio = degenerate loop (e.g. "LisperYourAds" ×10).
        let loop = WhisperSegment(text: " LisperYourAds LisperYourAds LisperYourAds",
                                  avgLogprob: -0.4, noSpeechProb: 0.1, compressionRatio: 4.2)
        #expect(SegmentConfidenceFilter.isHallucinated(loop))
        #expect(SegmentConfidenceFilter.filter([good(" the real message"), loop]) == "the real message")
    }

    @Test func dropsNonSpeechSilence() {
        // High no_speech_prob AND low confidence = silence/noise tail.
        let silence = WhisperSegment(text: " thank you.", avgLogprob: -1.8, noSpeechProb: 0.9, compressionRatio: 1.1)
        #expect(SegmentConfidenceFilter.isHallucinated(silence))
        #expect(SegmentConfidenceFilter.filter([good(" the real message"), silence]) == "the real message")
    }

    @Test func keepsQuietButConfidentSpeech() {
        // Elevated no_speech_prob but high confidence → high confidence overrides (kept),
        // matching Whisper's own silence-skip logic.
        let quiet = WhisperSegment(text: " yes", avgLogprob: -0.5, noSpeechProb: 0.7, compressionRatio: 1.0)
        #expect(!SegmentConfidenceFilter.isHallucinated(quiet))
    }

    @Test func thresholdsAreExclusiveAtBoundary() {
        // compression_ratio exactly 2.4 is NOT a loop (Whisper uses strictly greater-than).
        let edge = WhisperSegment(text: " edge", avgLogprob: -0.5, noSpeechProb: 0.1, compressionRatio: 2.4)
        #expect(!SegmentConfidenceFilter.isHallucinated(edge))
    }

    @Test func wholeClipHallucinationReturnsEmpty() {
        let loop = WhisperSegment(text: " a a a a a", avgLogprob: -0.5, noSpeechProb: 0.1, compressionRatio: 5.0)
        #expect(SegmentConfidenceFilter.filter([loop]) == "")
    }

    @Test func emptySegmentsReturnsEmpty() {
        #expect(SegmentConfidenceFilter.filter([]) == "")
    }
}
