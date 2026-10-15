import Testing
@testable import LisperKit

@Suite struct PromptBuilderTests {
    @Test func testCasualKeepsProfanityVerbatim() {
        let ctx = CleanupContext(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                                 dictionaryTerms: ["Lucent", "BetterYourAds"])
        let sys = CleanupPromptBuilder.systemPrompt(context: ctx)
        #expect(sys.contains("exactly as spoken"))
        #expect(sys.contains("never censor"))
        #expect(sys.lowercased().contains("casual"))
        #expect(sys.contains("Lucent, BetterYourAds"))
        #expect(!sys.contains("Remove profanity"))
    }

    /// The meaning-preservation contract holds.
    @Test func testKeepsCoreContract() {
        let ctx = CleanupContext(appName: "Notes", bundleID: "com.apple.Notes",
                                 dictionaryTerms: [])
        let sys = CleanupPromptBuilder.systemPrompt(context: ctx)
        #expect(sys.contains("filler"))
        #expect(sys.contains("never answer"))
        #expect(sys.contains("original order"))
        #expect(sys.contains("Do not reorganize"))
        #expect(sys.contains("light cleanup, not a rewrite"))
    }

    /// The dictionary must do more than "spell these right" — it must mandate REPLACING a
    /// phonetically-similar mis-hearing (Whisper's "Jerry") with the listed term ("Jeriq").
    @Test func testDictionaryMandatesPhoneticCorrection() {
        let ctx = CleanupContext(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                                 dictionaryTerms: ["Jeriq", "Claude"])
        let sys = CleanupPromptBuilder.systemPrompt(context: ctx)
        #expect(sys.contains("Jeriq, Claude"))                 // listed verbatim
        #expect(sys.lowercased().contains("sounds like"))      // replace similar-sounding mis-hearings
        #expect(sys.lowercased().contains("replace"))
    }

    /// Repetition is noise, like fillers: the prompt must instruct collapsing repeated/restated
    /// phrasing (with a teaching example) WITHOUT crossing into rewriting — the verbatim
    /// contract substrings must survive in both styles.
    @Test func testCollapsesRedundantRepetition() {
        let ctx = CleanupContext(appName: "Notes", bundleID: "com.apple.Notes",
                                 dictionaryTerms: [])
        let sys = CleanupPromptBuilder.systemPrompt(context: ctx)
        #expect(sys.lowercased().contains("repetition"))                 // rule present
        #expect(sys.contains("circle back on the budget"))              // repetition few-shot example
        #expect(sys.contains("light cleanup, not a rewrite"))           // contract intact
        #expect(sys.contains("Do not reorganize"))
    }

    @Test func testUserPromptWrapsTranscript() {
        let user = CleanupPromptBuilder.userPrompt(raw: "um hello world")
        #expect(user.contains("um hello world"))
    }

    /// The few-shot examples live in the base prompt.
    @Test func testFewShotExamplesPresent() {
        let ctx = CleanupContext(appName: "Notes", bundleID: "com.apple.Notes",
                                 dictionaryTerms: [])
        let sys = CleanupPromptBuilder.systemPrompt(context: ctx)
        #expect(sys.contains("Examples"))
    }

    /// The question exemplar teaches "questions stay questions" by example: the cleaned
    /// side is the cleaned QUESTION, not an answer — reinforcing the "never answer" rule.
    @Test func testQuestionExemplarTeachesNeverAnswerByExample() {
        let ctx = CleanupContext(appName: "Notes", bundleID: "com.apple.Notes",
                                 dictionaryTerms: [])
        let sys = CleanupPromptBuilder.systemPrompt(context: ctx)
        #expect(sys.contains("Can you send me the report by Friday?"))
        #expect(sys.contains("never answer"))
    }

    /// "you know" / "I mean" are fillers only as an aside. The prompt must say so, or the LLM
    /// pastes "What." for "You know what I mean." — the bug the rule path had (session 3135).
    @Test func testMeaningBearingFillerPhrasesProtected() {
        let sys = CleanupPromptBuilder.systemPrompt(context: CleanupContext(
            appName: "Notes", bundleID: "com.apple.Notes", dictionaryTerms: []))
        #expect(sys.contains("you know what I mean"))
        #expect(sys.contains("only when they are filler"))
    }

    /// Tech/business terms Whisper mangles ("clawed", "ChatGBT") are known out of the box —
    /// with no user dictionary at all — but only applied when the context means the term.
    @Test func testBuiltInVocabularyWithoutUserDictionary() {
        let sys = CleanupPromptBuilder.systemPrompt(context: CleanupContext(
            appName: "Notes", bundleID: "com.apple.Notes", dictionaryTerms: []))
        #expect(sys.contains("ChatGPT"))
        #expect(sys.contains("Claude"))
        #expect(sys.contains("context"))
        #expect(!sys.contains("Custom vocabulary"))   // no user section for an empty dictionary
    }

    /// The user's own terms are listed once, in their section — not repeated in the built-ins.
    @Test func testUserTermsNotRepeatedInBuiltIns() {
        let sys = CleanupPromptBuilder.systemPrompt(context: CleanupContext(
            appName: "Notes", bundleID: "com.apple.Notes", dictionaryTerms: ["Supabase"]))
        #expect(sys.components(separatedBy: "Supabase").count - 1 == 1)
    }

    /// gpt-oss deleted clauses ("…to be honest I'm tired" → "…") and quoted phrases ("when I
    /// say, you know what I mean, it…" → "when I say it…"). Measured fixes, kept as contract.
    @Test func testContentPreservationGuards() {
        for terms in [[], ["Jeriq"]] {
            let sys = CleanupPromptBuilder.systemPrompt(context: CleanupContext(
                appName: "Notes", bundleID: "com.apple.Notes", dictionaryTerms: terms))
            #expect(sys.contains("Never drop a clause"))
            #expect(sys.contains("talks ABOUT a word or phrase"))
            #expect(sys.hasSuffix("you removed only fillers, stutters, and repeats."))   // must stay LAST
        }
    }
}

