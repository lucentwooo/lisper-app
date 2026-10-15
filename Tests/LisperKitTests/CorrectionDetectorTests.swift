import Testing
@testable import LisperKit

@Suite struct CorrectionDetectorTests {
    @Test func testDetectsProperNounRespelling() {
        let c = CorrectionDetector.corrections(
            original: "I built this with grok and lisp today",
            edited: "I built this with Groq and Lisper today")
        #expect(c == [WordCorrection(original: "grok", corrected: "Groq"),
                      WordCorrection(original: "lisp", corrected: "Lisper")])
    }

    @Test func testDetectsCaseOnlyCorrection() {
        let c = CorrectionDetector.corrections(
            original: "ping betteryourads about it",
            edited: "ping BetterYourAds about it")
        #expect(c == [WordCorrection(original: "betteryourads", corrected: "BetterYourAds")])
    }

    @Test func testIgnoresContentRewrites() {
        // Far-apart words (an actual rewrite) and lowercase grammar fixes are not vocabulary.
        let c = CorrectionDetector.corrections(
            original: "this is a good idea and their right",
            edited: "this is a great idea and they're right")
        #expect(c.isEmpty)
    }

    @Test func testIgnoresKnownTermsAndIdenticalText() {
        #expect(CorrectionDetector.corrections(original: "ship Groq now",
                                               edited: "ship Groq now").isEmpty)
        let c = CorrectionDetector.corrections(original: "use grok today",
                                               edited: "use Groq today",
                                               knownTerms: ["groq"])
        #expect(c.isEmpty)
    }

    @Test func testDeduplicatesRepeatedCorrections() {
        let c = CorrectionDetector.corrections(
            original: "wispr is fine but wispr is slow",
            edited: "Wispr is fine but Wispr is slow")
        #expect(c == [WordCorrection(original: "wispr", corrected: "Wispr")])
    }

    /// Learning is automatic now (no approval popup), so a capitalisation fix of an ordinary
    /// word — fixing a sentence start, "the" → "The" — must not add "The" to the dictionary.
    @Test func testIgnoresCaseOnlyFixOfCommonWords() {
        let c = CorrectionDetector.corrections(
            original: "the plan works. so we ship it and i test it",
            edited: "The plan works. So we ship it and I test it")
        #expect(c.isEmpty)
    }
}

