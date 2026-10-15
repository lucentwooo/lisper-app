import Foundation

/// Appends DictationDebugRecords as JSONL to an injected file URL. When the file
/// would exceed `maxBytes`, the current file is rotated to `<name>.1` (overwriting
/// any previous rotation) and a fresh file is started. Location-agnostic: the app
/// passes the real App Support path; tests pass a temp file.
public final class DebugLog: @unchecked Sendable {
    private let fileURL: URL
    private let maxBytes: Int
    private let lock = NSLock()

    public init(fileURL: URL, maxBytes: Int = 5_000_000) {
        self.fileURL = fileURL; self.maxBytes = maxBytes
    }

    public func append(_ record: DictationDebugRecord) throws {
        let line = try record.jsonLine()
        let data = Data(line.utf8)
        lock.lock(); defer { lock.unlock() }

        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        let currentSize: Int = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0

        if currentSize + data.count > maxBytes, currentSize > 0 {
            let rotated = fileURL.deletingLastPathComponent()
                .appendingPathComponent(fileURL.lastPathComponent + ".1")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: fileURL, to: rotated)
        }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL)
        }
    }

    /// All persisted records in write order (rotated `.1` first, then the current
    /// file), so the last element is the newest. Malformed lines are skipped.
    public func readAll() -> [DictationDebugRecord] {
        lock.lock(); defer { lock.unlock() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let rotated = fileURL.deletingLastPathComponent()
            .appendingPathComponent(fileURL.lastPathComponent + ".1")
        var records: [DictationDebugRecord] = []
        for url in [rotated, fileURL] {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                if let rec = try? dec.decode(DictationDebugRecord.self, from: Data(line.utf8)) {
                    records.append(rec)
                }
            }
        }
        return records
    }

    /// The most recently logged record for a session id, if one was written.
    /// This is how a "Report bad dictation" bundle recovers the real captured
    /// metrics (rms / guardsFired / latency) instead of fabricating an empty record.
    public func latestRecord(forSession id: Int64) -> DictationDebugRecord? {
        readAll().last { $0.sessionId == id }
    }
}
