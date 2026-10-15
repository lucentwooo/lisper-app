import Testing
@testable import LisperKit

@Suite struct TranscriptStatsTests {
    @Test func testCountsFillersCaseInsensitive() {
        let raw = "Um, so I was, like, thinking that, you know, we should, uh, ship it. Like, actually, like, ship it."
        let stats = TranscriptStats.compute(raw: raw, durationSeconds: 10, customFillers: [])
        #expect(stats.fillerCounts["um"] == 1)
        #expect(stats.fillerCounts["uh"] == 1)
        #expect(stats.fillerCounts["like"] == 3)
        #expect(stats.fillerCounts["you know"] == 1)
    }

    @Test func testMultiWordFillersAndWordCount() {
        let raw = "I mean it is sort of done you know"
        let stats = TranscriptStats.compute(raw: raw, durationSeconds: 4, customFillers: [])
        #expect(stats.fillerCounts["i mean"] == 1)
        #expect(stats.fillerCounts["sort of"] == 1)
        #expect(stats.wordCount == 9)
        #expect(stats.fillerCount == 3) // i mean + sort of + you know
    }

    @Test func testWpmAndRate() {
        let raw = Array(repeating: "word", count: 120).joined(separator: " ")
        let stats = TranscriptStats.compute(raw: raw, durationSeconds: 60, customFillers: [])
        #expect(abs(stats.wordsPerMinute - 120) < 0.01)
        #expect(abs(stats.fillersPer100Words - 0) < 0.01)
    }

    @Test func testCustomFillersAndWordBoundaries() {
        let raw = "Basically the bike is likely fine basically"
        let stats = TranscriptStats.compute(raw: raw, durationSeconds: 5, customFillers: ["basically"])
        #expect(stats.fillerCounts["basically"] == 2)
        #expect(stats.fillerCounts["like"] == nil) // "likely" must not match "like"
    }

    @Test func testZeroDurationSafe() {
        let stats = TranscriptStats.compute(raw: "hello", durationSeconds: 0, customFillers: [])
        #expect(stats.wordsPerMinute == 0)
    }
}
