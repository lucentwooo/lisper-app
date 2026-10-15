import Foundation

/// A word the user fixed after Lisper pasted: "grok" → "Groq".
public struct WordCorrection: Equatable, Sendable {
    public let original: String
    public let corrected: String
    public init(original: String, corrected: String) {
        self.original = original
        self.corrected = corrected
    }
}

/// Detects vocabulary-style corrections between the text Lisper inserted and the
/// text after the user edited it. Conservative on purpose — it only surfaces
/// likely names/jargon (the corrected word carries a capital or a digit, and the
/// change is a respelling, not a rewrite), because every hit is added to the
/// dictionary automatically (DictionaryLearning) and announced in a toast.
public enum CorrectionDetector {
    public static func corrections(original: String, edited: String,
                                   knownTerms: [String] = []) -> [WordCorrection] {
        guard original != edited else { return [] }
        let a = tokenize(original), b = tokenize(edited)
        let known = Set(knownTerms.map { $0.lowercased() })

        var result: [WordCorrection] = []
        var seen = Set<String>()
        for (orig, corr) in substitutions(a, b) {
            guard corr.count >= 3,
                  corr.lowercased() != orig.lowercased() || corr != orig,  // changed at all
                  looksLikeVocabulary(corr),
                  isRespelling(orig, corr),
                  !isSentenceCaseFixOfCommonWord(orig, corr),
                  !known.contains(corr.lowercased()),
                  seen.insert(corr.lowercased()).inserted
            else { continue }
            result.append(WordCorrection(original: orig, corrected: corr))
        }
        return result
    }

    // MARK: alignment

    private static func tokenize(_ s: String) -> [String] {
        var words: [String] = [], current = ""
        for ch in s {
            if ch.isLetter || ch.isNumber || ch == "'" || ch == "-" {
                current.append(ch)
            } else if !current.isEmpty {
                words.append(current); current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// 1:1 word substitutions from an LCS alignment (exact-match, case-sensitive
    /// so that case fixes surface as substitutions).
    private static func substitutions(_ a: [String], _ b: [String]) -> [(String, String)] {
        let n = a.count, m = b.count
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1
                                         : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var pairs: [(String, String)] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] { i += 1; j += 1; continue }
            // Collect the mismatched run on both sides, then pair positionally.
            var delS: [String] = [], insS: [String] = []
            while i < n, j < m, a[i] != b[j] {
                if lcs[i + 1][j] >= lcs[i][j + 1] { delS.append(a[i]); i += 1 }
                else { insS.append(b[j]); j += 1 }
            }
            for k in 0..<min(delS.count, insS.count) { pairs.append((delS[k], insS[k])) }
        }
        return pairs
    }

    // MARK: filters

    /// Names and jargon carry a capital or a digit; lowercase swaps are grammar, not vocabulary.
    private static func looksLikeVocabulary(_ word: String) -> Bool {
        word.contains { $0.isUppercase || $0.isNumber }
    }

    /// "the" → "The" is the user fixing a sentence start, not teaching a name. Learning is
    /// automatic, so a case-only fix of an ordinary word must not enter the dictionary.
    /// Names stay learnable ("wispr" → "Wispr" is not a common word).
    private static func isSentenceCaseFixOfCommonWord(_ a: String, _ b: String) -> Bool {
        a.lowercased() == b.lowercased() && commonWords.contains(b.lowercased())
    }

    private static let commonWords: Set<String> = [
        "the", "and", "but", "for", "nor", "yet", "you", "your", "she", "her", "him", "his",
        "they", "them", "their", "its", "our", "who", "what", "when", "where", "why", "how",
        "which", "this", "that", "these", "those", "there", "here", "then", "than", "now",
        "not", "yes", "yeah", "okay", "also", "just", "can", "could", "will", "would",
        "should", "shall", "may", "might", "must", "did", "does", "has", "have", "had", "was",
        "were", "are", "been", "being", "let", "lets", "let's", "get", "got", "make", "made",
        "maybe", "well", "actually", "basically", "honestly", "anyway", "because", "after",
        "before", "while", "with", "without", "from", "into", "onto", "about", "over", "under",
        "some", "any", "all", "each", "every", "both", "either", "neither", "one", "two",
        "three", "first", "next", "last", "still", "even", "only", "really", "very", "please",
        "thanks", "thank", "hey", "hello", "sure", "right", "great", "good", "new", "can't",
        "don't", "doesn't", "didn't", "won't", "it's", "i'm", "i've", "i'll", "i'd", "we're",
        "we'll", "you're", "that's", "there's", "what's", "here's", "today", "tomorrow",
        "yesterday", "tonight", "again", "once", "though", "although", "unless", "since",
        "until", "whether", "if", "so", "or", "we", "it", "he", "me", "my", "us", "do", "go",
    ]

    /// A respelling stays close to the original; a distant word is a rewrite.
    private static func isRespelling(_ a: String, _ b: String) -> Bool {
        let la = a.lowercased(), lb = b.lowercased()
        if la == lb { return true }   // pure case fix
        let limit = max(2, min(la.count, lb.count) / 2)
        return editDistance(la, lb) <= limit
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty else { return y.count }
        guard !y.isEmpty else { return x.count }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = x[i - 1] == y[j - 1] ? prev[j - 1]
                       : min(prev[j - 1], prev[j], cur[j - 1]) + 1
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }
}
