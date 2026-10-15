// Sources/LisperKit/Coach/FlowTrend.swift
import Foundation

/// Collapses per-session Flow Scores into one mean point per calendar day.
///
/// The trend chart plots against a day-unit x axis. Feeding it one point per SESSION
/// put several points on the same x, and `.catmullRom` interpolation through duplicate
/// x values overshoots violently — the tall spikes that escaped the plot area. One
/// point per day removes the duplicate x values at the source, which is also what a
/// "trend" chart means.
public enum FlowTrend {

    /// - Parameter calendar: pass an explicit Gregorian calendar. Never rely on
    ///   `Calendar.current` here — this machine's system calendar is Buddhist.
    /// - Returns: one entry per day, ascending, each the rounded mean of that day's scores.
    public static func dailyMeans(_ points: [(date: Date, overall: Int)],
                                  calendar: Calendar) -> [(day: Date, mean: Int)] {
        guard !points.isEmpty else { return [] }
        var buckets: [Date: [Int]] = [:]
        for p in points {
            let day = calendar.startOfDay(for: p.date)
            buckets[day, default: []].append(p.overall)
        }
        return buckets.keys.sorted().map { day in
            let values = buckets[day]!
            let mean = Double(values.reduce(0, +)) / Double(values.count)
            return (day: day, mean: Int(mean.rounded()))
        }
    }
}
