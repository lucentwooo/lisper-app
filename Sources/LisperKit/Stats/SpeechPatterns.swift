import Foundation

public struct DisfluencyStats: Equatable, Sendable {
    public let immediateRepeats: Int       // adjacent duplicate words: "the the", "i i"
    public let per100Words: Double
    public init(immediateRepeats: Int, per100Words: Double) {
        self.immediateRepeats = immediateRepeats; self.per100Words = per100Words
    }

    /// Lowercased word tokens, punctuation stripped. The single source of truth for
    /// "what is a word" stays `TranscriptStats.wordCount`; here we need the tokens
    /// themselves, tokenized the same way (whitespace/newline split) minus punctuation.
    private static func tokens(_ raw: String) -> [String] {
        raw.lowercased()
            .split { $0.isWhitespace || $0.isNewline }
            .map { String($0.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
            .filter { !$0.isEmpty }
    }

    public static func compute(raw: String) -> DisfluencyStats {
        let words = tokens(raw)
        guard words.count >= 2 else { return DisfluencyStats(immediateRepeats: 0, per100Words: 0) }
        var repeats = 0
        for i in 1..<words.count where words[i] == words[i - 1] { repeats += 1 }
        let per100 = Double(repeats) / Double(words.count) * 100
        return DisfluencyStats(immediateRepeats: repeats, per100Words: per100)
    }
}
