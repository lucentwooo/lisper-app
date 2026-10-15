import Testing
@testable import LisperKit

@Suite struct RuleBasedCleanupTests {
    @Test func testStripsFillersAndTidiesSpaces() {
        let out = RuleBasedCleanup.clean("Um, so I was like thinking we should uh ship it")
        #expect(!out.lowercased().contains("um"))
        #expect(!out.lowercased().contains(" uh "))
        #expect(!out.contains("  "))
        #expect(!out.contains(" ,"))
    }

    @Test func testCapitalizesSentencesAndAddsFinalPeriod() {
        let out = RuleBasedCleanup.clean("hello there. this is a test")
        #expect(out.hasPrefix("Hello"))
        #expect(out.contains(". This"))
        #expect(out.hasSuffix("."))
    }

    @Test func testDoesNotAddPeriodAfterQuestionMark() {
        let out = RuleBasedCleanup.clean("is this working?")
        #expect(out.hasSuffix("?"))
    }

    @Test func testEmptyAndWhitespaceInput() {
        #expect(RuleBasedCleanup.clean("   ") == "")
    }

    @Test func testKeepsContentWordsIntact() {
        let out = RuleBasedCleanup.clean("the bike is likely fine")
        #expect(out.lowercased().contains("likely")) // boundary safety
    }
}
