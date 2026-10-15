import Testing
@testable import LisperKit

@Suite struct HallucinationGuardTests {

    @Test func testFlagsRepeatedNGramLoop() {
        // The exact failure mode reported from a noisy coffee shop: Whisper drops
        // its language lock and spews a short token run over and over.
        let garbage = """
        VHL VAR JARREW RETTA BAK AVAILABS VHL VAR GEMETSUI VHL VAR GEMETSUI \
        VHL VAR GEMETSUI VHL VAR GEMETSUI VHL VAR GEMETSUI VHL VAR GEMETSUI \
        VHL VAR GEMETSUI
        """
        #expect(HallucinationGuard.isLikelyHallucination(garbage))
    }

    @Test func testFlagsBackToBackPhraseRepeat() {
        #expect(HallucinationGuard.isLikelyHallucination(
            "whicher levels whicher levels whicher levels whicher levels to opper"))
    }

    @Test func testFlagsSingleTokenSpam() {
        #expect(HallucinationGuard.isLikelyHallucination(
            "you you you you you you you you you you"))
    }

    @Test func testDoesNotFlagNormalDictation() {
        #expect(!HallucinationGuard.isLikelyHallucination(
            "um okay whisper flow has this feature where if there is stuff playing in the background they still understand your voice"))
    }

    @Test func testDoesNotFlagShortClip() {
        #expect(!HallucinationGuard.isLikelyHallucination("um hello world"))
        #expect(!HallucinationGuard.isLikelyHallucination(""))
    }

    @Test func testDoesNotFlagEmphaticDoubling() {
        // Real speech doubles words for emphasis — must not trip the guard.
        #expect(!HallucinationGuard.isLikelyHallucination(
            "no no I really really think we should ship this today"))
    }

    @Test func testDoesNotFlagRepeatedFillerInLongRamble() {
        // Long casual dictation sprinkles the same filler phrase several times
        // across hundreds of words — that's not a Whisper loop, it's how people
        // talk. A raw "phrase repeats 4+ times" rule wrongly flags this; the
        // repeated phrase covers only a sliver of the transcript, so it must pass.
        let ramble = "so like you know I really think we should ship the new thing " +
            "you know and then like maybe we can test it you know before the big demo " +
            "because you know honestly it could totally work and like you know we will " +
            "just have to see what actually happens on the day"
        #expect(!HallucinationGuard.isLikelyHallucination(ramble))
    }

    @Test func testDoesNotFlagRealReportedRamble() {
        // Same shape as a real "Report bad dictation" (session 165), reworded: a
        // 90-second loud rant that Whisper transcribed correctly but the guard
        // discarded, forcing a lossy Apple-on-device fallback. Must NOT be flagged.
        let real = "But people still cook it they go out their way to cook it right " +
            "so like you can go order a meal for cheap but people still buy cookbooks " +
            "so like all this different stuff you know like you know there's a recipe " +
            "search built into every phone but people still pay for a meal planner why is " +
            "that right I'm not like you're saying all this stuff which annoys me and " +
            "that's fine my roommate has even told me to not bother with it but I'm like " +
            "I'm doing this anyway I'm gonna learn all of it I think it's just that the fact " +
            "that I am cooking every day will level me up a lot in terms of the recipes I " +
            "could potentially try the dishes I could potentially learn I don't know but " +
            "you know I'm I'm interested like is it worth it that's a question"
        #expect(!HallucinationGuard.isLikelyHallucination(real))
    }

    @Test func testDoesNotFlagReportedRambleSession171() {
        // Same shape as the Groq Whisper transcript recovered by replaying session 171's
        // saved audio ("a lot of the start was missed"), reworded. The old top>=4 rule
        // tripped on "what people" (~4x) and discarded it, dropping the user to Apple's
        // on-device engine, which then truncated the first ~40s. Must NOT be flagged.
        let real = "Go through the app, see if there's any ways that we can improve the " +
            "onboarding based off what people are complaining about in reviews and what people " +
            "really like about it. then lean on, lean even more into what people " +
            "like about it, but also more into what people hate about it so that we can " +
            "now say, hey, all those things you didn't like about the old version, we fixed. " +
            "And now we can ship the next release and tell everyone about it."
        #expect(!HallucinationGuard.isLikelyHallucination(real))
    }

    // MARK: collapseRepetitionLoops — excise LOCALIZED back-to-back loops while
    // keeping the surrounding good speech (the coverage-based whole-clip guard
    // misses these, so they get pasted verbatim — the reported `LisperYourAds`×10 bug).

    @Test func testCollapsesLocalizedLoopAtEndOfLongMessage() {
        // Verbatim shape of the real failure: a good long message that ends in a
        // back-to-back hallucination loop. Coverage is well under 50%, so
        // isLikelyHallucination correctly does NOT fire — excision must handle it.
        let looped = "okay so before you run the goal as you can see it messed up a bit while i " +
            "was dictating this long message to you and honestly i just wanted you to go through " +
            "it carefully and fix the transcription problems we keep running into every single time " +
            "i talk for a while and ramble on about the product and the plan " +
            "LisperYourAds LisperYourAds LisperYourAds LisperYourAds LisperYourAds " +
            "LisperYourAds LisperYourAds LisperYourAds LisperYourAds LisperYourAds"
        #expect(!HallucinationGuard.isLikelyHallucination(looped))   // coverage too low to flag
        let cleaned = HallucinationGuard.collapseRepetitionLoops(looped)
        #expect(cleaned.contains("dictating this long message to you"))
        let hits = cleaned.lowercased().components(separatedBy: "lisperyourads").count - 1
        #expect(hits <= 1)   // the 10× run is collapsed away
    }

    @Test func testCollapsesPunctuatedBackToBackLoop() {
        // Whisper emits the loop with comma separators; token compare must ignore punctuation.
        let looped = "here is my actual note, word, word, word, word, word, word"
        let cleaned = HallucinationGuard.collapseRepetitionLoops(looped)
        #expect(cleaned.lowercased().contains("here is my actual note"))
        let hits = cleaned.lowercased().components(separatedBy: "word").count - 1
        #expect(hits <= 1)
    }

    @Test func testCollapsesMultiWordLoop() {
        // Classic trailing-silence loop: a 2-word phrase repeated back-to-back.
        let looped = "thanks for listening to my note thank you thank you thank you thank you thank you"
        let cleaned = HallucinationGuard.collapseRepetitionLoops(looped)
        #expect(cleaned.contains("thanks for listening to my note"))
        #expect(cleaned.components(separatedBy: "thank you").count - 1 <= 1)
    }

    @Test func testCollapsePreservesNormalSpeech() {
        let s = "this is a totally normal sentence with no runaway repeats at all"
        #expect(HallucinationGuard.collapseRepetitionLoops(s) == s)
    }

    @Test func testCollapsePreservesEmphaticDoublingAndTripling() {
        // Real emphasis (2–3×) must survive untouched; only runaway runs collapse.
        #expect(HallucinationGuard.collapseRepetitionLoops("no no I really really think we should ship")
                == "no no I really really think we should ship")
        #expect(HallucinationGuard.collapseRepetitionLoops("go go go team")
                == "go go go team")
    }

    @Test func testCollapsePreservesScatteredFillers() {
        // The session-165/171 failure mode: fillers recur but never back-to-back.
        let ramble = "so like you know I really think we should ship the new thing " +
            "you know and then like maybe we can test it you know before the big demo"
        #expect(HallucinationGuard.collapseRepetitionLoops(ramble) == ramble)
    }

    // MARK: exciseTrailingHallucination — remove a LOCALIZED trailing hallucination
    // burst (vocab-prompt echo + degenerate loop) appended to otherwise-good speech.
    // This is the session-205 failure mode: whole-clip guards stay silent (good
    // speech dominates) and collapse-to-one still pastes the garbage clause.

    @Test func testExcisesSession205TrailingBurst() {
        // Verbatim raw Groq transcript from session 205. Ground truth ended
        // "...but also futuristic and they don't really pair well together...";
        // Whisper lost the real tail and emitted "FowlerAds, Lisper, Crap, Lid, Mace"×.
        let raw = "I think if instead of these Ones that you have maybe could we change it to " +
            "some sort of liquid glass thing to fit the vibe better in terms of like the film " +
            "grain and the You know Deep blue gradient like I feel like the grain needs to be " +
            "applied to everything But right now there's some mix between like oh grainy but " +
            "also futuristic FowlerAds, Lisper, Crap, Lid, Mace, Crap, Lid, Mace, Crap, Lid, Mace."
        let out = HallucinationGuard.exciseTrailingHallucination(
            raw, dictionaryTerms: ["Wispr Flow", "BetterYourAds", "Lisper"])
        // The good speech is preserved verbatim up to the last real word.
        #expect(out.hasSuffix("but also futuristic"))
        // None of the hallucinated tokens survive — including the vocab-echo lead-in.
        for garbage in ["Crap", "Lid", "Mace", "FowlerAds", "Lisper"] {
            #expect(!out.contains(garbage), "garbage token survived: \(garbage)")
        }
        #expect(out.contains("liquid glass thing"))   // body untouched
    }

    @Test func testExciseLeavesCleanSpeechUntouched() {
        let s = "this is a totally normal sentence with no runaway repeats at all"
        #expect(HallucinationGuard.exciseTrailingHallucination(s) == s)
    }

    @Test func testExcisePreservesEmphaticLowercaseRepeat() {
        // Real emphasis: a lowercase phrase repeated 3× with no hallucination
        // signature must NOT be excised (collapse-to-one handles it elsewhere).
        let s = "okay i really think we should ship it ship it ship it"
        let out = HallucinationGuard.exciseTrailingHallucination(s)
        #expect(out.contains("ship it"))   // not wiped out
    }

    @Test func testExciseDoesNotTouchReportedRambles() {
        // The session 157/165/171 rambles (good long takes) have no trailing loop —
        // excision must be a no-op so we never regress the "missed the start" bug.
        let s165 = "But people still cook it they go out their way to cook it right " +
            "so like you can go order a meal for cheap but people still buy cookbooks " +
            "so like all this different stuff you know like you know there's a recipe"
        #expect(HallucinationGuard.exciseTrailingHallucination(s165) == s165)
    }

    @Test func testExciseRemovesLongTrailingLoopEntirely() {
        let looped = "here is my actual note that i dictated word word word word word word"
        let out = HallucinationGuard.exciseTrailingHallucination(looped)
        #expect(out.hasSuffix("note that i dictated"))
        #expect(out.components(separatedBy: "word").count - 1 == 0)
    }

    @Test func testExciseNeverDeletesEntireTranscript() {
        // If the whole thing is a loop (no good prefix), leave it for the
        // whole-clip guard / engine fallback — don't return empty.
        let allLoop = "Crap, Lid, Mace, Crap, Lid, Mace, Crap, Lid, Mace, Crap, Lid, Mace."
        let out = HallucinationGuard.exciseTrailingHallucination(allLoop, dictionaryTerms: [])
        #expect(!out.isEmpty)
    }

    @Test func testDoesNotFlagReportedRambleSession157() {
        // Same shape as the Groq Whisper transcript recovered by replaying session 157's
        // saved audio (its opening went missing), reworded. One place name recurs ~5x as
        // ordinary phrasing (~9% coverage) — the old rule flagged it and forced the lossy
        // Apple fallback that ate the opening. Must NOT be flagged.
        let real = "what apartments are in green valley or very near green valley that " +
            "i can afford my savings aren't amazing so definitely not the big ones by the river " +
            "um something decent i guess but like as long as i think as i think as long " +
            "as i'm in Green Valley I think that's important right at least I to me I think " +
            "it is right because like we'll just go to the markets and stuff like you let me know " +
            "what do you think like is it worth it to go there to a tiny apartment or but " +
            "you're still in Green Valley or stay here in town where it's not Green " +
            "Valley but in a big apartment"
        #expect(!HallucinationGuard.isLikelyHallucination(real))
    }

    /// Real speech ends in repeats too. Four repeats alone is not a hallucination signature,
    /// and a single capitalised word repeated ("Bye. Bye.") is a goodbye, not a garbage list —
    /// these used to be deleted along with the words before them.
    @Test func testRealTrailingRepeatsAreNotExcised() {
        let real = [
            "I asked if he wanted to come and he said no, no, no, no.",
            "Alright, see you Monday. Bye. Bye. Bye. Bye.",
            "Okay so the code for the gate is 1 1 1 1",
        ]
        for text in real {
            #expect(HallucinationGuard.exciseTrailingHallucination(text) == text, "real speech excised: \(text)")
        }
    }

    /// A genuinely degenerate tail (many back-to-back repeats) is still removed.
    @Test func testLongDegenerateTailStillExcised() {
        let text = "Send the deck to the team tonight. thank you thank you thank you thank you thank you thank you thank you"
        #expect(HallucinationGuard.exciseTrailingHallucination(text) == "Send the deck to the team tonight.")
    }
}

