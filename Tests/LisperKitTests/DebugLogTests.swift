import Testing
@testable import LisperKit

@Suite struct DebugLogTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lisper-debuglog-\(UUID().uuidString)")
            .appendingPathComponent("dictations.jsonl")
    }

    private func record(_ raw: String) -> DictationDebugRecord {
        DictationDebugRecord(timestamp: Date(timeIntervalSince1970: 0), sessionId: 1,
            durationSeconds: 1, rms: 0.1, engineUsed: "groq", cleanupUsed: "llm",
            rawTranscript: raw, cleanedText: raw, guardsFired: [], latencyMs: 1, error: nil)
    }

    private func record(session: Int64, raw: String, guards: [String]) -> DictationDebugRecord {
        DictationDebugRecord(timestamp: Date(timeIntervalSince1970: 0), sessionId: session,
            durationSeconds: 1, rms: 0.5, engineUsed: "apple", cleanupUsed: "rules",
            rawTranscript: raw, cleanedText: raw, guardsFired: guards, latencyMs: 42, error: nil)
    }

    @Test func testAppendCreatesDirAndWritesOneLinePerRecord() throws {
        let url = tempURL()
        let log = DebugLog(fileURL: url, maxBytes: 1_000_000)
        try log.append(record("one"))
        try log.append(record("two"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2)
        #expect(text.contains("\"rawTranscript\":\"one\""))
    }

    @Test func testLatestRecordReturnsRealMetricsForSession() throws {
        // The "Report bad dictation" bundle must carry the REAL captured metrics
        // (rms / guardsFired / latency), not a fabricated empty record. Reading the
        // record back by session id is how the report recovers them.
        let url = tempURL()
        let log = DebugLog(fileURL: url)
        try log.append(record(session: 10, raw: "first", guards: []))
        try log.append(record(session: 11, raw: "rant", guards: ["hallucination", "retry", "sttFallback"]))

        let found = log.latestRecord(forSession: 11)
        #expect(found?.rawTranscript == "rant")
        #expect(found?.guardsFired == ["hallucination", "retry", "sttFallback"])
        #expect(found?.rms == 0.5)
        #expect(found?.latencyMs == 42)
        #expect(log.latestRecord(forSession: 999) == nil)
    }

    @Test func testLatestRecordPrefersNewestForSameSession() throws {
        // A session id can recur if a row is re-logged; the most recent line wins.
        let url = tempURL()
        let log = DebugLog(fileURL: url)
        try log.append(record(session: 5, raw: "stale", guards: []))
        try log.append(record(session: 5, raw: "fresh", guards: ["cleanupFallback"]))
        #expect(log.latestRecord(forSession: 5)?.rawTranscript == "fresh")
    }

    @Test func testRotationCapsFileSize() throws {
        let url = tempURL()
        let log = DebugLog(fileURL: url, maxBytes: 300) // tiny cap forces rotation
        for i in 0..<20 { try log.append(record("entry-\(i)")) }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        #expect(size <= 300 * 2) // current file stays bounded (cap + one over)
        // rotated file exists
        let rotated = url.deletingLastPathComponent().appendingPathComponent("dictations.jsonl.1")
        #expect(FileManager.default.fileExists(atPath: rotated.path))
    }
}
