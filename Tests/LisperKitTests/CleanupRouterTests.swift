import Testing
@testable import LisperKit

@Suite struct CleanupRouterTests {
    @Test func testEmptyAndWhitespaceUseFastPath() {
        #expect(CleanupRouter.shouldUseRuleFastPath(raw: ""))
        #expect(CleanupRouter.shouldUseRuleFastPath(raw: "   \n\t  "))
    }

    @Test func testSingleWordUsesFastPath() {
        #expect(CleanupRouter.shouldUseRuleFastPath(raw: "yes"))
    }

    @Test func testExactlyMaxWordsUsesFastPath() {
        let raw = Array(repeating: "word", count: CleanupRouter.fastPathMaxWords)
            .joined(separator: " ")
        #expect(CleanupRouter.shouldUseRuleFastPath(raw: raw))
    }

    @Test func testOneOverMaxWordsDoesNotUseFastPath() {
        let raw = Array(repeating: "word", count: CleanupRouter.fastPathMaxWords + 1)
            .joined(separator: " ")
        #expect(!CleanupRouter.shouldUseRuleFastPath(raw: raw))
    }

    @Test func testLongSentenceDoesNotUseFastPath() {
        let raw = "um so i think we should ship this feature today and tell the team"
        #expect(!CleanupRouter.shouldUseRuleFastPath(raw: raw))
    }

    @Test func testCountsWordsTheSameWayAsTranscriptStats() {
        // Multiple/irregular whitespace must collapse the same way TranscriptStats counts.
        let raw = "  yes   send    it  "   // 3 words despite the extra spacing
        #expect(CleanupRouter.shouldUseRuleFastPath(raw: raw))
    }
}
