import Testing
@testable import LisperKit

@Suite struct GuardLogTests {
    @Test func testRecordsInOrderAndDeduplicates() {
        let log = GuardLog()
        log.record("hallucination")
        log.record("retry")
        log.record("hallucination") // duplicate ignored
        #expect(log.all() == ["hallucination", "retry"])
    }

    @Test func testEmptyByDefault() {
        #expect(GuardLog().all() == [])
    }
}
