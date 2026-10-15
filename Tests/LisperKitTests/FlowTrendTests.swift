import Testing
import Foundation
@testable import LisperKit

@Suite struct FlowTrendTests {

    /// Gregorian + fixed UTC: the machine's system calendar is Buddhist and would
    /// otherwise corrupt day bucketing.
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    /// THE BUG: several takes in one day used to become several points sharing an x
    /// value, which made catmullRom interpolation overshoot into spikes. They must
    /// collapse into exactly one averaged point.
    @Test func testSameDayScoresCollapseToOneMean() {
        let points = [(date: date(2026, 7, 19, 9), overall: 52),
                      (date: date(2026, 7, 19, 14), overall: 68),
                      (date: date(2026, 7, 19, 20), overall: 78)]
        let out = FlowTrend.dailyMeans(points, calendar: cal)
        #expect(out.count == 1)
        #expect(out[0].mean == 66)          // (52+68+78)/3 = 66
    }

    /// Separate days stay separate and come back in ascending date order.
    @Test func testDistinctDaysAreSortedAscending() {
        let points = [(date: date(2026, 7, 26), overall: 90),
                      (date: date(2026, 7, 19), overall: 60),
                      (date: date(2026, 8, 2), overall: 70)]
        let out = FlowTrend.dailyMeans(points, calendar: cal)
        #expect(out.count == 3)
        #expect(out.map(\.mean) == [60, 90, 70])
        #expect(out[0].day < out[1].day)
        #expect(out[1].day < out[2].day)
    }

    /// Each returned day is normalised to the START of that day, so the chart's
    /// x values are exactly one per day.
    @Test func testDayIsNormalisedToStartOfDay() {
        let out = FlowTrend.dailyMeans([(date: date(2026, 7, 19, 23), overall: 50)], calendar: cal)
        #expect(out[0].day == date(2026, 7, 19, 0))
    }

    @Test func testEmptyInputReturnsEmpty() {
        #expect(FlowTrend.dailyMeans([], calendar: cal).isEmpty)
    }
}
