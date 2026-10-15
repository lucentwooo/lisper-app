import Testing
@testable import LisperKit

/// Whisper large-v3 (on Groq, and reproducibly in whisper.cpp) sometimes ends its transcript
/// early, after a pause, though the words are plainly in the clip. turbo hears them. These are
/// real takes from 2026-10-09…12, primary = what Groq large-v3 returned.
@Suite struct EndingRecoveryTests {

    @Test func testRecoversDroppedLastWords() {
        // Session 3340.
        let tail = EndingRecovery.missingEnding(
            primary: "If you have before and after screenshots of the changes that you made so that I can easily",
            checker: "If you have before and after screenshots of the changes that you made so that I can easily visually check them.")
        #expect(tail == "visually check them.")
    }

    @Test func testRecoversDroppedLastSentence() {
        // Session 3194: the whole sentence after the pause was missing.
        let tail = EndingRecovery.missingEnding(
            primary: "When I try to sign in on localhost 3000 and I click continue with Google, it says sign in isn't available right now.",
            checker: "When I try to sign in on localhost 3000, and I click continue with Google, it says sign in isn't available right now. I'll try again in a bit.")
        #expect(tail == "I'll try again in a bit.")
    }

    @Test func testRecoversMostOfAShortTake() {
        // Session 3123: large-v3 stopped after the first four words.
        let tail = EndingRecovery.missingEnding(
            primary: "Anything else on Atlas",
            checker: "Anything else on atlas that I need to do or is everything done now?")
        #expect(tail == "that I need to do or is everything done now?")
    }

    @Test func testCaseAndPunctuationDoNotBreakTheAnchor() {
        // Session 3277: "look over." vs "look over," must still line up.
        let tail = EndingRecovery.missingEnding(
            primary: "Hey Maya, I just sent you a document for you to look over.",
            checker: "Hey Maya, I just sent you a document for you to look over, which is something quick to...")
        #expect(tail == "which is something quick to...")
    }

    @Test func testSameEndingRecoversNothing() {
        #expect(EndingRecovery.missingEnding(primary: "Just follow this structure, but yeah.",
                                             checker: "Just follow this structure but yeah") == nil)
    }

    @Test func testCheckerThatStoppedEarlierRecoversNothing() {
        #expect(EndingRecovery.missingEnding(primary: "so that I can easily visually check them.",
                                             checker: "so that I can easily") == nil)
    }

    /// When the two models disagree about the last words there is no safe place to splice.
    @Test func testDisagreeingEndingsRecoverNothing() {
        #expect(EndingRecovery.missingEnding(
            primary: "This is our analysis of it so far",
            checker: "This is our analysis of it so fast and here's what you could change.") == nil)
    }

    /// The primary's last words appear twice in the checker: either splice could be right, so
    /// neither is made.
    @Test func testAmbiguousAnchorRecoversNothing() {
        #expect(EndingRecovery.missingEnding(
            primary: "we should test it",
            checker: "we should test it and then we should test it again") == nil)
    }

    /// The anchor must sit where the primary's words would end in the checker. A match far
    /// from there is a coincidence, and splicing at it would paste a stretch of the take twice.
    @Test func testAnchorFarFromThePrimaryEndRecoversNothing() {
        let primary = "we ran the numbers again yesterday and honestly I think the margins look fine so we keep going and we test it"
        let checker = "we test it first. We ran the numbers again yesterday and honestly I think the margins look fine, so we keep going and then we tested it in the end."
        #expect(EndingRecovery.missingEnding(primary: primary, checker: checker) == nil)
    }

    @Test func testPunctuationOnlyDifferenceRecoversNothing() {
        #expect(EndingRecovery.missingEnding(primary: "so yeah", checker: "So, yeah. ...") == nil)
    }

    /// Session 3137: turbo (and local large-v3) heard "Thank you." in the second of room tone
    /// after the last word — Whisper's best-known silence hallucination, not speech.
    @Test func testSilenceHallucinationIsNotRecovered() {
        let primary = "any business lingo it should understand as well"
        for junk in ["Thank you.", "you", "Thanks for watching!", "Bye."] {
            #expect(EndingRecovery.missingEnding(primary: primary, checker: "\(primary) \(junk)") == nil, "\(junk)")
        }
    }

    /// A real short ending is still recovered — "thanks" is something people say (session 3179).
    @Test func testRealShortEndingIsRecovered() {
        #expect(EndingRecovery.missingEnding(
            primary: "let's do a screenshot before and after, that'd be great.",
            checker: "let's do a screenshot before and after, that'd be great, thanks.") == "thanks.")
    }

    /// Session 3188: turbo repeated the primary's last word ("…they can see, right? Right."),
    /// which neither large-v3 nor turbo on the full recording heard.
    @Test func testRepeatOfThePrimaryLastWordsIsNotRecovered() {
        #expect(EndingRecovery.missingEnding(
            primary: "the AI can only use what they can see, right?",
            checker: "the AI can only use what they can see, right? Right.") == nil)
    }

    /// A long take whose two transcripts disagree on the very last word ("it" vs "all"): the
    /// primary's last words also occur 14 words earlier, which a percentage-based slack let
    /// through, and the splice pasted those 14 words twice.
    @Test func testEarlierCoincidentalMatchOnALongTakeIsRefused() {
        let body = (0..<170).map { "word\($0)" }.joined(separator: " ")
        let primary = body + " and that's it, we just need to ship the fix and check the numbers next week and that's it."
        let checker = body + " and that's it, we just need to ship the fix and check the numbers next week and that's all."
        #expect(EndingRecovery.missingEnding(primary: primary, checker: checker) == nil)
    }

    /// Sound annotations don't count as words, but real text in brackets is pasted untouched.
    @Test func testBracketsAndSymbolsInARecoveredEndingArePastedIntact() {
        #expect(EndingRecovery.missingEnding(primary: "call the office number which is",
                                             checker: "call the office number which is (415) 555-1234.")
                == "(415) 555-1234.")
        #expect(EndingRecovery.missingEnding(primary: "we should talk about the",
                                             checker: "we should talk about the plan (the second one).")
                == "plan (the second one).")
        #expect(EndingRecovery.missingEnding(primary: "honestly the launch",
                                             checker: "honestly the launch went f***ing great.")
                == "went f***ing great.")
    }

    /// Hallucinations come in runs too.
    @Test func testRepeatedSilenceHallucinationsAreNotRecovered() {
        let primary = "any business lingo it should understand as well"
        for junk in ["Thank you. Thank you.", "Thank you for watching. Please subscribe.", "Bye. Bye."] {
            #expect(EndingRecovery.missingEnding(primary: primary, checker: "\(primary) \(junk)") == nil, "\(junk)")
        }
    }

    @Test func testRepeatedEchoOfTheLastWordIsNotRecovered() {
        #expect(EndingRecovery.missingEnding(primary: "what they can see, right?",
                                             checker: "what they can see, right? Right. Right.") == nil)
    }

    /// Whisper sometimes repeats an earlier sentence over trailing room tone.
    @Test func testRepeatOfAnEarlierSentenceIsNotRecovered() {
        #expect(EndingRecovery.missingEnding(
            primary: "Can you send me the report? I need it by Friday.",
            checker: "Can you send me the report? I need it by Friday. Can you send me the report?") == nil)
    }

    /// A standalone punctuation token ending the primary must not be pasted a second time.
    @Test func testTrailingPunctuationTokenIsNotDoubled() {
        #expect(EndingRecovery.missingEnding(primary: "so that I can easily —",
                                             checker: "so that I can easily — visually check them.")
                == "visually check them.")
    }

    /// The primary says its last phrase twice; a checker that words the second half differently
    /// matches the FIRST copy and would paste the words between them again.
    @Test func testPrimaryRepeatingItsOwnLastPhraseIsRefused() {
        #expect(EndingRecovery.missingEnding(primary: "we test it we test it",
                                             checker: "we test it we test that and more") == nil)
        let body = (0..<200).map { "word\($0)" }.joined(separator: " ")
        #expect(EndingRecovery.missingEnding(
            primary: body + " and that's it, we're gonna ship it and that's it.",
            checker: body + " and that's it, we're going to ship it and that's all.") == nil)
    }

    @Test func testMoreSignOffHallucinationsAreNotRecovered() {
        let primary = "any business lingo it should understand as well"
        for junk in ["Thank you, bye-bye.", "Thank you for listening.", "See you next time.",
                     "Subtitles by the Amara.org community"] {
            #expect(EndingRecovery.missingEnding(primary: primary, checker: "\(primary) \(junk)") == nil, "\(junk)")
        }
    }

    @Test func testTwoWordRepeatOfAnEarlierPhraseIsRefused() {
        #expect(EndingRecovery.missingEnding(
            primary: "Can you send me the report by Friday please.",
            checker: "Can you send me the report by Friday please. The report.") == nil)
    }

    /// Sound annotations are not words.
    @Test func testSoundAnnotationsAreNotRecovered() {
        let primary = "any business lingo it should understand as well"
        for junk in ["[Music]", "(upbeat music)", "*sigh*", "[BLANK_AUDIO]"] {
            #expect(EndingRecovery.missingEnding(primary: primary, checker: "\(primary) \(junk)") == nil, "\(junk)")
        }
    }

    @Test func testVideoOutroHallucinationsAreNotRecovered() {
        let primary = "any business lingo it should understand as well"
        for junk in ["Thank you so much for watching.", "I'll see you next time.", "See you in the next video.",
                     "Please subscribe to my channel.", "Thanks for watching and see you next time.",
                     "Thank you guys.", "Goodbye."] {
            #expect(EndingRecovery.missingEnding(primary: primary, checker: "\(primary) \(junk)") == nil, "\(junk)")
        }
    }

    /// The two models word DIFFERENT copies of a repeated phrase differently: the anchor is unique
    /// in both, but in the checker it lands on the earlier copy. Splicing there pastes words twice.
    @Test func testCrossedRewordingOfARepeatedPhraseIsRefused() {
        #expect(EndingRecovery.missingEnding(primary: "so we tested, we test it",
                                             checker: "so we test it, we tested again") == nil)
        #expect(EndingRecovery.missingEnding(primary: "and that is it, and that's it.",
                                             checker: "and that's it, and that's all, see you Monday.") == nil)
    }

    @Test func testCheckerShorterThanTheAnchorRecoversNothing() {
        #expect(EndingRecovery.missingEnding(primary: "so that I can easily", checker: "easily") == nil)
    }

    @Test func testEmptyInputsRecoverNothing() {
        #expect(EndingRecovery.missingEnding(primary: "", checker: "hello there") == nil)
        #expect(EndingRecovery.missingEnding(primary: "hello there", checker: "") == nil)
    }
}
