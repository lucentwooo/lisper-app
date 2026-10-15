// Copies of the two LisperKit types AudioRecorder.swift uses (its `import LisperKit` is stripped).
public struct CapturedAudio: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    public var durationSeconds: Double { Double(samples.count) / sampleRate }
    public init(samples: [Float], sampleRate: Double = 16_000) { self.samples = samples; self.sampleRate = sampleRate }
}
public enum EngineError: Error, Equatable { case noAPIKey, network(String), badResponse(Int, String), emptyTranscript, unavailable(String) }
