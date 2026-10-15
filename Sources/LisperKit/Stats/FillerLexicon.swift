import Foundation

public enum FillerLexicon {
    /// Default crutch/filler phrases tracked by the coach. Multi-word phrases supported.
    public static let defaults: [String] = [
        "um", "uh", "erm", "uhm", "like", "you know", "sort of", "kind of",
        "i mean", "basically", "actually", "literally", "right?", "okay so"
    ]

    /// Builds a case-insensitive word-boundary regex for a phrase.
    static func regex(for phrase: String) -> NSRegularExpression {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
            .replacingOccurrences(of: "\\ ", with: "\\s+")
        // For phrases ending in a non-word character (e.g. "right?"), omit the trailing \b
        let lastChar = phrase.last
        let trailingBoundary = (lastChar?.isLetter == true || lastChar?.isNumber == true) ? "\\b" : ""
        return try! NSRegularExpression(pattern: "\\b\(escaped)\(trailingBoundary)", options: [.caseInsensitive])
    }
}
