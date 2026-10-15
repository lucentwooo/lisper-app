// Sources/LisperKit/Coach/FlowScore.swift
import Foundation

/// The 60-second-flow challenge as a number: filler-free + uninterrupted + sustained.
/// Pure, deterministic, and computable from a stored session alone — no LLM, no
/// persisted analysis. (A coherence-derived "single thread" component was removed with
/// the coach engine; these three components are the whole score.)
public struct FlowScore: Codable, Equatable, Sendable {
    public let overall: Int
    public let fillerFree: Int
    public let continuity: Int
    public let sustain: Int

    public init(overall: Int, fillerFree: Int, continuity: Int, sustain: Int) {
        self.overall = overall; self.fillerFree = fillerFree
        self.continuity = continuity; self.sustain = sustain
    }

    private static let fillerCeiling = 12.0       // fillers/100w at which fillerFree hits 0
    private static let disfluencyCeiling = 8.0    // immediate-repeats/100w at which continuity hits 0
    private static let sustainTarget = 60.0       // seconds for full sustain credit

    private static func score(_ value: Double, ceiling: Double) -> Int {
        let pct = 100.0 - min(value, ceiling) / ceiling * 100.0
        return Int(max(0, min(100, pct.rounded())))
    }

    public static func compute(stats: TranscriptStats, disfluency: DisfluencyStats,
                               durationSeconds: Double) -> FlowScore {
        let fillerFree = score(stats.fillersPer100Words, ceiling: fillerCeiling)
        let continuity = score(disfluency.per100Words, ceiling: disfluencyCeiling)
        let sustain = Int(max(0, min(100, (durationSeconds / sustainTarget * 100).rounded())))
        let overall = Int((Double(fillerFree) * 0.45 + Double(continuity) * 0.35
                           + Double(sustain) * 0.20).rounded())
        return FlowScore(overall: overall, fillerFree: fillerFree,
                         continuity: continuity, sustain: sustain)
    }
}
