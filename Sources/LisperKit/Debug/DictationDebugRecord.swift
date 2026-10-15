import Foundation

/// One dictation's debug footprint: a single JSONL log line, and the technical
/// half of a "Report bad dictation" bundle. Never contains audio or the API key.
public struct DictationDebugRecord: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var sessionId: Int64?
    public var durationSeconds: Double
    public var rms: Double               // mean loudness of the capture, 0...1
    public var engineUsed: String        // "groq" | "apple" | ""
    public var cleanupUsed: String       // "llm" | "rules" | ""
    public var rawTranscript: String
    public var cleanedText: String
    public var guardsFired: [String]     // e.g. ["silence"], ["hallucination","retry"]
    public var latencyMs: Int
    public var error: String?            // thrown error description, if it failed
    /// Why LLM cleanup fell back to rules (the take itself succeeded). Absent in older lines.
    public var cleanupError: String?

    public init(timestamp: Date, sessionId: Int64?, durationSeconds: Double, rms: Double,
                engineUsed: String, cleanupUsed: String, rawTranscript: String,
                cleanedText: String, guardsFired: [String], latencyMs: Int, error: String?,
                cleanupError: String? = nil) {
        self.timestamp = timestamp; self.sessionId = sessionId
        self.durationSeconds = durationSeconds; self.rms = rms
        self.engineUsed = engineUsed; self.cleanupUsed = cleanupUsed
        self.rawTranscript = rawTranscript; self.cleanedText = cleanedText
        self.guardsFired = guardsFired; self.latencyMs = latencyMs; self.error = error
        self.cleanupError = cleanupError
    }

    /// Encodes to one JSON object followed by a single newline (JSONL).
    public func jsonLine() throws -> String {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.withoutEscapingSlashes]
        let data = try enc.encode(self)
        return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
    }
}
