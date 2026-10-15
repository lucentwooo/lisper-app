import Foundation

public struct CapturedAudio: Sendable {
    public let samples: [Float]        // mono PCM, -1...1
    public let sampleRate: Double      // 16_000
    public var durationSeconds: Double { Double(samples.count) / sampleRate }
    /// Where the last detected speech ends in this clip, in seconds — set by the VAD trimmer;
    /// nil when no trimmer looked at it. Words heard after it are in the trailing pad.
    public let speechEndSeconds: Double?
    /// How much of the clip was recorded while the key was held — the rest is the stop tail the
    /// recorder adds after the press. nil = all of it.
    public let heldSeconds: Double?
    public init(samples: [Float], sampleRate: Double = 16_000, speechEndSeconds: Double? = nil,
                heldSeconds: Double? = nil) {
        self.samples = samples; self.sampleRate = sampleRate
        self.speechEndSeconds = speechEndSeconds; self.heldSeconds = heldSeconds
    }
}

public enum EngineError: Error, Equatable {
    case noAPIKey
    case network(String)
    case badResponse(Int, String)
    case emptyTranscript
    case unavailable(String)
}

extension EngineError {
    /// HTTP 429. Groq rate limits are per model, so this — unlike a bad key or being
    /// offline — is worth retrying on a different model.
    public var isRateLimited: Bool {
        if case .badResponse(429, _) = self { return true }
        return false
    }
}

public protocol TranscriptionEngine: Sendable {
    var name: String { get }   // "groq" | "apple"
    func transcribe(audio: CapturedAudio, dictionaryTerms: [String]) async throws -> String
}

public protocol CleanupEngine: Sendable {
    var name: String { get }   // "llm" | "rules"
    func clean(raw: String, context: CleanupContext) async throws -> String
}
