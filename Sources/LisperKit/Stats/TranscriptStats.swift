import Foundation

public struct TranscriptStats: Codable, Equatable, Sendable {
    public let wordCount: Int
    public let fillerCounts: [String: Int]   // phrase -> occurrences (only non-zero)
    public let wordsPerMinute: Double
    public var fillerCount: Int { fillerCounts.values.reduce(0, +) }
    public var fillersPer100Words: Double {
        wordCount == 0 ? 0 : Double(fillerCount) / Double(wordCount) * 100
    }

    /// The single source of truth for "how many words is this transcript" —
    /// whitespace/newline split, empties dropped. Both stats and the cleanup
    /// router count words through here so "words" means the same thing everywhere.
    public static func wordCount(of raw: String) -> Int {
        raw.split { $0.isWhitespace || $0.isNewline }.count
    }

    public static func compute(raw: String, durationSeconds: Double, customFillers: [String]) -> TranscriptStats {
        let words = wordCount(of: raw)
        var counts: [String: Int] = [:]
        let phrases = Array(Set(FillerLexicon.defaults + customFillers.map { $0.lowercased() }))
        let range = NSRange(raw.startIndex..., in: raw)
        for phrase in phrases {
            let n = FillerLexicon.regex(for: phrase).numberOfMatches(in: raw, options: [], range: range)
            if n > 0 { counts[phrase] = n }
        }
        let wpm = durationSeconds > 0 ? Double(words) / (durationSeconds / 60) : 0
        return TranscriptStats(wordCount: words, fillerCounts: counts, wordsPerMinute: wpm)
    }
}
