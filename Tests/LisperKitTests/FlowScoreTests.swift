import Testing
@testable import LisperKit

@Suite struct FlowScoreTests {

    /// A clean 60s take: no fillers, no disfluency, full sustain -> a perfect score.
    @Test func testCleanSustainedTakeScoresFull() {
        let raw = String(repeating: "clear words here ", count: 20)
        let stats = TranscriptStats.compute(raw: raw, durationSeconds: 60, customFillers: [])
        let dis = DisfluencyStats.compute(raw: raw)
        let f = FlowScore.compute(stats: stats, disfluency: dis, durationSeconds: 60)
        #expect(f.fillerFree == 100)
        #expect(f.continuity == 100)
        #expect(f.sustain == 100)
        #expect(f.overall == 100)
    }

    /// Sustain is linear against the 60s target and clamps at 100.
    @Test func testSustainScalesToSixtySeconds() {
        let stats = TranscriptStats.compute(raw: "one two three four",
                                            durationSeconds: 30, customFillers: [])
        let dis = DisfluencyStats.compute(raw: "one two three four")
        #expect(FlowScore.compute(stats: stats, disfluency: dis, durationSeconds: 30).sustain == 50)
        #expect(FlowScore.compute(stats: stats, disfluency: dis, durationSeconds: 120).sustain == 100)
    }

    /// Fillers drive fillerFree down; the ceiling is 12 fillers/100 words.
    @Test func testFillersReduceFillerFree() {
        let raw = "um " + String(repeating: "word ", count: 99)   // ~1 filler / 100 words
        let stats = TranscriptStats.compute(raw: raw, durationSeconds: 60, customFillers: [])
        let dis = DisfluencyStats.compute(raw: raw)
        let f = FlowScore.compute(stats: stats, disfluency: dis, durationSeconds: 60)
        #expect(f.fillerFree < 100)
        #expect(f.fillerFree > 80)
    }

    /// Overall uses the deterministic weights: 0.45 / 0.35 / 0.20.
    @Test func testOverallUsesDeterministicWeights() {
        let raw = String(repeating: "word ", count: 100)
        let stats = TranscriptStats.compute(raw: raw, durationSeconds: 30, customFillers: [])
        let dis = DisfluencyStats.compute(raw: raw)
        let f = FlowScore.compute(stats: stats, disfluency: dis, durationSeconds: 30)
        let expected = Int((Double(f.fillerFree) * 0.45
                            + Double(f.continuity) * 0.35
                            + Double(f.sustain) * 0.20).rounded())
        #expect(f.overall == expected)
    }
}
