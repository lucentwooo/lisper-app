import Testing
@testable import LisperKit

@Suite struct VocabularyPromptTests {

    @Test func testNoLabelLeaksIntoPrompt() {
        // Regression: the prompt used to start with "Vocabulary: ", and Whisper
        // regurgitated that label into transcripts on low-confidence audio.
        let prompt = GroqWhisperEngine.vocabularyPrompt(["Groq", "Lisper"])
        #expect(prompt == "Groq, Lisper")
        #expect(!(prompt ?? "").lowercased().contains("vocabulary"))
    }

    @Test func testEmptyTermsGivesNoPrompt() {
        #expect(GroqWhisperEngine.vocabularyPrompt([]) == nil)
        #expect(GroqWhisperEngine.vocabularyPrompt(["", "  "]) == nil)
    }

    @Test func testTrimsAndDropsBlanks() {
        #expect(GroqWhisperEngine.vocabularyPrompt(["  Groq ", "", "GRDB"]) == "Groq, GRDB")
    }

    @Test func testDetectsVocabularyEchoOnSilence() {
        let terms = ["Wispr Flow", "BetterYourAds", "Lisperia", "U.S."]
        #expect(GroqWhisperEngine.isVocabularyEcho("Wispr Flow, BetterYourAds, Lisperia, U.S.", terms: terms))
        // punctuation / spacing differences still count as an echo
        #expect(GroqWhisperEngine.isVocabularyEcho("wispr flow, betteryourads, lisperia, US", terms: terms))
    }

    @Test func testRealSpeechIsNotEcho() {
        let terms = ["Wispr Flow", "BetterYourAds", "Lisperia", "U.S."]
        #expect(!GroqWhisperEngine.isVocabularyEcho("I really like Wispr Flow for dictation", terms: terms))
        #expect(!GroqWhisperEngine.isVocabularyEcho("anything", terms: []))
    }
}
