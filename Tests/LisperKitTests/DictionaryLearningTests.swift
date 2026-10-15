import Testing
@testable import LisperKit

/// Wispr-style auto-learn: a word the user fixes after a paste goes straight into the
/// dictionary (with an Undo), instead of waiting on a popup they have to approve.
@Suite struct DictionaryLearningTests {
    @Test func learnsCorrectedSpelling() {
        let new = DictionaryLearning.newTerms(
            from: [WordCorrection(original: "Jerry", corrected: "Jeriq")], existing: ["Lucent"])
        #expect(new == ["Jeriq"])
    }

    @Test func skipsTermsAlreadyKnownIgnoringCase() {
        let new = DictionaryLearning.newTerms(
            from: [WordCorrection(original: "groc", corrected: "Groq"),
                   WordCorrection(original: "Jerry", corrected: "Jeriq")],
            existing: ["groq"])
        #expect(new == ["Jeriq"])
    }

    @Test func learnsEachTermOnceInOrder() {
        let new = DictionaryLearning.newTerms(
            from: [WordCorrection(original: "a", corrected: "Supabase"),
                   WordCorrection(original: "b", corrected: "Jeriq"),
                   WordCorrection(original: "c", corrected: "supabase")],
            existing: [])
        #expect(new == ["Supabase", "Jeriq"])
    }

    /// Undo removes exactly what that learn added — never a term the user had already.
    @Test func undoRemovesOnlyTheLearnedTerms() {
        let after = DictionaryLearning.removing(["Jeriq"], from: ["Lucent", "Jeriq", "Groq"])
        #expect(after == ["Lucent", "Groq"])
    }

    /// Auto-learn has no approval step, and the dictionary prompt makes the LLM rewrite
    /// sound-alikes into learned terms. So a content edit ("Tuesday" → "Thursday", "2024" →
    /// "2025") must never be learned: only words that aren't ordinary dictionary words (names,
    /// jargon) and contain a letter.
    @Test func learnsOnlyNamesAndJargonNotOrdinaryWordsOrNumbers() {
        let ordinary: Set<String> = ["thursday", "john"]
        let new = DictionaryLearning.newTerms(
            from: [WordCorrection(original: "Tuesday", corrected: "Thursday"),
                   WordCorrection(original: "2024", corrected: "2025"),
                   WordCorrection(original: "Jon", corrected: "John"),
                   WordCorrection(original: "Jerry", corrected: "Jeriq")],
            existing: [], isOrdinaryWord: { ordinary.contains($0.lowercased()) })
        #expect(new == ["Jeriq"])
    }

    /// macOS's spell checker accepts any mixed-case token, but internal capitals ("BetterYourAds",
    /// "GitHub") mark a product or brand — always learnable.
    @Test func mixedCaseJargonIsLearnableEvenIfSpellCheckAcceptsIt() {
        let new = DictionaryLearning.newTerms(
            from: [WordCorrection(original: "better your ads", corrected: "BetterYourAds")],
            existing: [], isOrdinaryWord: { _ in true })
        #expect(new == ["BetterYourAds"])
    }
}

