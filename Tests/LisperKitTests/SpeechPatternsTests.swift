import Testing
@testable import LisperKit

@Suite struct SpeechPatternsTests {
    @Test func countsImmediateWordRepeats() {
        let raw = "i i think the the plan is good and we we should ship"
        let d = DisfluencyStats.compute(raw: raw)
        #expect(d.immediateRepeats == 3)               // "i i", "the the", "we we"
        #expect(d.per100Words > 0)
    }

    @Test func disfluencyEmptyIsZero() {
        let d = DisfluencyStats.compute(raw: "")
        #expect(d.immediateRepeats == 0)
        #expect(d.per100Words == 0)
    }
}
