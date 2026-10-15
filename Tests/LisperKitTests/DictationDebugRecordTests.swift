import Testing
@testable import LisperKit

@Suite struct DictationDebugRecordTests {
    @Test func testCodableRoundTrip() throws {
        let r = DictationDebugRecord(
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            sessionId: 42, durationSeconds: 3.5, rms: 0.12,
            engineUsed: "groq", cleanupUsed: "llm",
            rawTranscript: "um hello", cleanedText: "Hello.",
            guardsFired: ["silence"], latencyMs: 850, error: nil)
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(DictationDebugRecord.self, from: data)
        #expect(back == r)
    }

    @Test func testJSONLineHasNoNewlines() throws {
        let r = DictationDebugRecord(
            timestamp: Date(timeIntervalSince1970: 0), sessionId: nil,
            durationSeconds: 1, rms: 0, engineUsed: "apple", cleanupUsed: "rules",
            rawTranscript: "line one\nline two", cleanedText: "x",
            guardsFired: [], latencyMs: 1, error: "boom")
        let line = try r.jsonLine()
        #expect(!line.dropLast().contains("\n")) // exactly one trailing newline
        #expect(line.hasSuffix("\n"))
    }
}
