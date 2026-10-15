import Testing
@testable import LisperKit

/// Golden-transcript regression suite for `RuleBasedCleanup`.
///
/// This is the deterministic offline/fast-path cleaner, and (since 0.3) the path
/// EVERY short dictation takes — so its behavior is locked here. Each tuple is
/// (raw → expected). Expected values are the DESIRED cleaned output where the
/// rules can produce it; where the rules have a known limitation (no question
/// detection, no self-correction handling, no proper-noun casing) the expected
/// value is the ACTUAL current output, flagged with a `rule-based limitation`
/// comment so the gap is documented rather than silently "fixed".
@Suite struct RuleBasedCleanupGoldenTests {

    /// One filler token per case, in natural context — each strippable token must vanish
    /// while every content word survives and the sentence is tidied.
    @Test func testFillerRemovalPerToken() {
        let cases: [(raw: String, expected: String)] = [
            ("so um I think we should ship it", "So I think we should ship it."), // "so" stays (content), "um" stripped
            ("I uh forgot to mention it",       "I forgot to mention it."),
            ("well erm that is fine",           "Well that is fine."), // "well" stays (content), "erm" stripped
            ("uhm okay then",                   "Okay then."),
        ]
        for c in cases {
            #expect(RuleBasedCleanup.clean(c.raw) == c.expected,
                    "filler removal failed for raw: \(c.raw)")
        }
    }

    /// "you know" / "I mean" / "sort of" / "kind of" are only fillers when set off as an
    /// aside — Whisper punctuates those with commas. Bracketed by commas (or opening a
    /// sentence with a comma after), they are stripped.
    @Test func testParentheticalFillersStripped() {
        let cases: [(raw: String, expected: String)] = [
            ("we should, you know, move on",     "We should move on."),
            ("I mean, it is fine",               "It is fine."),
            ("it was, sort of, working",         "It was working."),
            ("So, you know, we shipped it",      "So we shipped it."),
            ("That works. I mean, mostly",       "That works. Mostly."),
            ("we should,  you   know , move on", "We should move on."),   // Whisper spacing varies
        ]
        for c in cases {
            #expect(RuleBasedCleanup.clean(c.raw) == c.expected,
                    "parenthetical filler failed for raw: \(c.raw)")
        }
    }

    /// Unpunctuated, the same words are usually CONTENT — and the cleanup contract is
    /// "preserve meaning verbatim". Session 3135 pasted "What." for "You know what I mean."
    /// and 3020 pasted "Do what?" for "Do you know what I mean?". Never strip these.
    @Test func testMeaningBearingPhrasesKept() {
        let cases: [(raw: String, expected: String)] = [
            ("You know what I mean.",               "You know what I mean."),
            ("Do you know what I mean?",            "Do you know what I mean?"),
            ("it's just like blurred out you know what i mean", "It's just like blurred out you know what i mean."),
            ("I mean it.",                          "I mean it."),
            ("I mean it is fine",                   "I mean it is fine."),     // rule-based limitation: unpunctuated filler kept
            ("what kind of car is it?",             "What kind of car is it?"),
            ("it is kind of late",                  "It is kind of late."),    // hedge carries meaning
            ("we should you know move on",          "We should you know move on."), // rule-based limitation: unpunctuated filler kept
            ("do you know where it is?",            "Do you know where it is?"),
        ]
        for c in cases {
            #expect(RuleBasedCleanup.clean(c.raw) == c.expected,
                    "meaning-bearing phrase mangled for raw: \(c.raw)")
        }
    }

    /// Short utterances that now ride the rule-based fast path (0.3 routes all short
    /// dictations through this cleaner). Lock their exact output.
    @Test func testShortFastPathUtterances() {
        let cases: [(raw: String, expected: String)] = [
            ("yes send it",            "Yes send it."),
            ("okay thanks",            "Okay thanks."),
            ("um lets ship it today",  "Lets ship it today."), // rule-based limitation: cannot repair missing apostrophes
        ]
        for c in cases {
            #expect(RuleBasedCleanup.clean(c.raw) == c.expected,
                    "short fast-path failed for raw: \(c.raw)")
        }
    }

    /// Mechanical tidy-ups: whitespace collapse, space-before-punctuation, sentence
    /// capitalization, final-period insertion, leading-orphan-punctuation strip.
    @Test func testMechanicalCleanup() {
        let cases: [(raw: String, expected: String)] = [
            // whitespace collapse
            ("the   bike  is  great",        "The bike is great."),
            // space before punctuation removed; second sentence capitalized
            ("hello there . this is great",  "Hello there. This is great."),
            // existing sentence boundary capitalized, final period kept
            ("hello there. this is a test",  "Hello there. This is a test."),
            // leading orphan punctuation stripped, then capitalized
            ("...so anyway it works",        "So anyway it works."),
            (", and then we left",           "And then we left."),
        ]
        for c in cases {
            #expect(RuleBasedCleanup.clean(c.raw) == c.expected,
                    "mechanical cleanup failed for raw: \(c.raw)")
        }
    }

    /// A period inside a token (domain, file name, decimal) is not a sentence end — only
    /// `.`/`!`/`?` followed by whitespace starts a new sentence. History had "github.Com",
    /// "cloud.Md", "6.1 Million".
    @Test func testNoCapitalAfterInWordPeriod() {
        let cases: [(raw: String, expected: String)] = [
            ("check github.com for the code",   "Check github.com for the code."),
            ("open the claude.md file",         "Open the claude.md file."),
            ("it costs 4.99 a month",           "It costs 4.99 a month."),
            ("we raised 6.1 million",           "We raised 6.1 million."),
            ("done. next one",                  "Done. Next one."),   // real boundary still capitalizes
        ]
        for c in cases {
            #expect(RuleBasedCleanup.clean(c.raw) == c.expected, "in-word period mangled: \(c.raw)")
        }
    }

    /// "like" is content far more often than filler, so it is NOT in the strip list.
    @Test func testLikeIsNotStripped() {
        #expect(RuleBasedCleanup.clean("i like this") == "I like this.")
    }

    /// The rule-based cleaner never censors; profanity passes through untouched.
    @Test func testProfanityUntouched() {
        let out = RuleBasedCleanup.clean("this is fucking great")
        #expect(out == "This is fucking great.")
        #expect(out.lowercased().contains("fucking"))
    }

    /// Empty and whitespace-only input collapse to the empty string.
    @Test func testEmptyAndWhitespaceOnly() {
        #expect(RuleBasedCleanup.clean("") == "")
        #expect(RuleBasedCleanup.clean("   ") == "")
        #expect(RuleBasedCleanup.clean(" \n\t ") == "")
    }

    /// rule-based limitation: the cleaner cannot reliably detect questions, so it
    /// always appends "." (not "?") and does not proper-case nouns ("friday").
    /// Meaning is fully preserved; only end-punctuation/casing differs from ideal.
    /// (The LLM cleanup path handles this correctly — see the few-shot question
    /// exemplar in CleanupPromptBuilder.)
    @Test func testQuestionFallsBackToPeriod() {
        #expect(RuleBasedCleanup.clean("um can you send me the report by friday")
                == "Can you send me the report by friday.")
    }

    /// rule-based limitation: the cleaner does NOT collapse spoken self-corrections
    /// ("tuesday no wait wednesday" stays verbatim). It only removes fillers/tidies.
    /// The LLM cleanup path collapses self-corrections — see few-shot example 2.
    /// Locked here so the rule-based behavior stays predictable and meaning-preserving.
    @Test func testSelfCorrectionNotCollapsed() {
        #expect(RuleBasedCleanup.clean("I want to go on tuesday no wait wednesday")
                == "I want to go on tuesday no wait wednesday.")
    }
}
