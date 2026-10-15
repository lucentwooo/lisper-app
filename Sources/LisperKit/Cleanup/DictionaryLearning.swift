import Foundation

/// Wispr-style auto-learn: when the user fixes a word Lisper pasted, its corrected spelling
/// goes straight into the dictionary (the app offers an Undo) rather than waiting on a popup.
public enum DictionaryLearning {
    /// The corrected spellings to append: each one not already in the dictionary
    /// (case-insensitively), once, in the order they were corrected.
    ///
    /// Only names and jargon are learnable. There is no approval step, and the cleanup prompt
    /// rewrites sound-alikes into dictionary terms — so learning a content edit ("Tuesday" →
    /// "Thursday", "2024" → "2025") would silently rewrite future takes. A term must contain a
    /// letter and must not be an ordinary word (`isOrdinaryWord` — the app passes a spell
    /// check; "Jeriq", "Groq" and "Wispr" are not words, "Thursday" is).
    public static func newTerms(from corrections: [WordCorrection], existing: [String],
                                isOrdinaryWord: (String) -> Bool = { _ in false }) -> [String] {
        var known = Set(existing.map { $0.lowercased() })
        return corrections.map(\.corrected).filter { term in
            term.contains(where: \.isLetter) && (isMixedCase(term) || !isOrdinaryWord(term))
                && known.insert(term.lowercased()).inserted
        }
    }

    /// Internal capitals ("BetterYourAds", "GitHub") mark a brand or product — always jargon,
    /// even though the system spell checker accepts any mixed-case token.
    static func isMixedCase(_ term: String) -> Bool {
        term.dropFirst().contains(where: \.isUppercase)
    }

    /// Undo a learn: drop exactly the terms it added, leaving everything else in place.
    public static func removing(_ learned: [String], from terms: [String]) -> [String] {
        let drop = Set(learned)
        return terms.filter { !drop.contains($0) }
    }
}
