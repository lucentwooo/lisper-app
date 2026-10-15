import Foundation

/// Offline/no-key fallback: strips pure fillers, fixes spacing/casing.
/// Intentionally conservative — only removes words that are never content.
public enum RuleBasedCleanup {
    /// Never content, in any position — always stripped.
    private static let pureFillers = ["um", "uh", "erm", "uhm"]

    /// Content as often as filler: "you know what I mean", "I mean it", "what kind of car".
    /// Stripping them unconditionally pasted "What." for "You know what I mean." (session
    /// 3135). They are only removed when set off as an aside — which Whisper marks with
    /// commas — and kept verbatim otherwise, because cleanup must preserve meaning.
    private static let asideFillers = ["you know", "i mean", "sort of", "kind of"]

    /// For each aside filler: `, P,` mid-sentence → " ", and `P,` opening a sentence → "".
    private static let asideRules: [(NSRegularExpression, String)] = asideFillers.flatMap { phrase in
        let p = phrase.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: #"\s+"#)
        return [
            (try! NSRegularExpression(pattern: #",\s*\b"# + p + #"\b\s*,"#, options: [.caseInsensitive]), " "),
            (try! NSRegularExpression(pattern: #"(^|[.!?]\s+)"# + p + #"\b\s*,\s*"#, options: [.caseInsensitive]), "$1"),
        ]
    }

    public static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        for (re, template) in asideRules {
            text = re.stringByReplacingMatches(in: text, options: [],
                range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        for phrase in pureFillers {
            let re = FillerLexicon.regex(for: phrase)
            text = re.stringByReplacingMatches(in: text, options: [],
                range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        // collapse whitespace, fix space-before-punctuation, drop doubled/orphaned punctuation
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"([,.!?;:]){2,}"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^[,.;:\s]+"#, with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return "" }

        // capitalize sentence starts — a terminator only ends a sentence when whitespace
        // follows it, so "github.com", "claude.md" and "4.99 a month" stay as spoken
        let chars = Array(text)
        var result = ""
        var capitalizeNext = true
        for (i, ch) in chars.enumerated() {
            if capitalizeNext, ch.isLetter {
                result.append(Character(ch.uppercased()))
                capitalizeNext = false
            } else {
                result.append(ch)
                if ".!?…".contains(ch), i + 1 < chars.count, chars[i + 1].isWhitespace {
                    capitalizeNext = true
                }
            }
        }
        if let last = result.last, !".!?…".contains(last) { result.append(".") }
        return result
    }
}
