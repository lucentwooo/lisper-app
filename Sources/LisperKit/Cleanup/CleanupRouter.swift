import Foundation

/// Decides whether a raw transcript is short enough to clean with the instant
/// rule-based path, skipping the slower second Groq (LLM) round-trip.
public enum CleanupRouter {
    /// Raw transcripts with at most this many words are cleaned by the instant
    /// rule-based path, skipping the slower LLM round-trip. Conservative on purpose:
    /// short utterances rarely need grammar/structure fixes the rules can't do.
    public static let fastPathMaxWords = 4

    /// True when `raw` is short enough that rule-based cleanup is sufficient and the
    /// LLM cleanup hop can be skipped. Empty/whitespace-only counts as 0 words → true.
    public static func shouldUseRuleFastPath(raw: String) -> Bool {
        TranscriptStats.wordCount(of: raw) <= fastPathMaxWords
    }
}
