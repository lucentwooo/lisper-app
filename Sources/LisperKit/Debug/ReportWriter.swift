import Foundation

/// Assembles a "Report bad dictation" bundle: report.json (technical record +
/// settings snapshot + user note) and, when still on disk, audio.wav. The
/// settings snapshot is passed in already stripped of the API key.
public enum ReportWriter {
    public struct Report: Codable {
        public let record: DictationDebugRecord
        public let settings: [String: String]
        public let note: String
    }

    /// Returns the bundle folder URL (`<base>/<sessionId>/`).
    @discardableResult
    public static func write(into base: URL, sessionId: Int64,
                             record: DictationDebugRecord,
                             settingsSnapshot: [String: String],
                             note: String, audio: Data?) throws -> URL {
        let folder = base.appendingPathComponent("\(sessionId)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let report = Report(record: record, settings: settingsSnapshot, note: note)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try enc.encode(report).write(to: folder.appendingPathComponent("report.json"))

        if let audio { try audio.write(to: folder.appendingPathComponent("audio.wav")) }
        return folder
    }
}
