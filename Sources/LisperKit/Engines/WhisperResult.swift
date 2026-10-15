// Sources/LisperKit/Engines/WhisperResult.swift

/// One Whisper segment plus the quality signals Groq returns in a `verbose_json`
/// response. These let us detect hallucinations at the source (per segment) instead
/// of pattern-matching the final text.
public struct WhisperSegment: Sendable, Equatable {
    public let text: String
    /// Average token log-probability. Closer to 0 = more confident; very negative = guessing.
    public let avgLogprob: Double
    /// Probability the segment is silence/non-speech. Closer to 1 = likely no speech.
    public let noSpeechProb: Double
    /// gzip compression ratio of the segment text. High values = very repetitive (loops).
    public let compressionRatio: Double
    /// Where the segment starts in the clip, in seconds (nil when the API didn't say).
    public let start: Double?

    public init(text: String, avgLogprob: Double, noSpeechProb: Double, compressionRatio: Double,
                start: Double? = nil) {
        self.text = text
        self.avgLogprob = avgLogprob
        self.noSpeechProb = noSpeechProb
        self.compressionRatio = compressionRatio
        self.start = start
    }
}

/// A transcription plus its segments. `segments` is empty when the API returned no
/// segment detail (then callers fall back to `text`).
public struct WhisperResult: Sendable {
    public let text: String
    public let segments: [WhisperSegment]

    public init(text: String, segments: [WhisperSegment]) {
        self.text = text
        self.segments = segments
    }
}
