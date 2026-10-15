// Sources/Lisper/UI/Main/CoachView.swift
import SwiftUI
import Charts
import LisperKit

struct InsightsView: View {
    @ObservedObject var model: MainViewModel
    @State private var heroScore: FlowScore?
    @State private var trend: [(day: Date, mean: Int)] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Masthead(eyebrow: "Speaking coach", title: "Insights",
                         subtitle: "Your Flow Score — measured from your raw transcripts.")

                // The hero and the trend are fed by two DIFFERENT queries (newest 30
                // sessions vs newest 200), so either can be empty while the other has
                // data. Gate each on its own data and show the empty state only when
                // there is genuinely nothing to draw.
                if let hero = heroScore {
                    flowHeroSection(hero).padding(.top, 30)
                }
                if trend.count >= 2 {
                    Text("Trend").sectionLabel().padding(.top, heroScore == nil ? 30 : 28)
                    VStack(spacing: 0) {
                        Divider().overlay(Theme.hairline)
                        flowSparkline.padding(.top, 12)
                    }
                    .padding(.top, 8)
                }
                if heroScore == nil, trend.count < 2 {
                    VStack(spacing: 10) {
                        OrbMark(size: 40)
                        Text("Dictate for a few days and your speaking patterns appear here")
                            .sectionLabel().multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 100)
                }
            }
            .padding(.horizontal, 36).padding(.top, 36).padding(.bottom, 44)
        }
        .onAppear { reload() }
    }

    // MARK: Flow Score hero

    private func flowHeroSection(_ hero: FlowScore) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Flow score").sectionLabel()
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(hero.overall)")
                    .font(Theme.statNumeral(72)).kerning(-2)
                    .foregroundColor(Theme.textPrimary).monospacedDigit()
                Text("/100").font(Theme.statNumeral(24))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(.top, 2)

            HStack(alignment: .top, spacing: 44) {
                subScore("Filler-free", hero.fillerFree)
                subScore("Continuity", hero.continuity)
                subScore("Sustain", hero.sustain)
            }
            .padding(.top, 14)
        }
    }

    private func subScore(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)")
                .font(Theme.statNumeral(28)).kerning(-0.5)
                .foregroundColor(Theme.textPrimary).monospacedDigit()
            Text(label).sectionLabel()
        }
    }

    // MARK: trend chart

    /// One point per DAY (see FlowTrend) and `.monotone` interpolation. The previous
    /// version plotted one point per SESSION on a day-unit axis, so same-day takes shared
    /// an x value and catmullRom overshot into spikes that escaped the plot area.
    private var flowSparkline: some View {
        Chart(trend, id: \.day) { item in
            AreaMark(x: .value("Day", item.day, unit: .day),
                     y: .value("Flow", item.mean))
                .foregroundStyle(LinearGradient(
                    colors: [Theme.accent.opacity(0.4), .clear],
                    startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Day", item.day, unit: .day),
                     y: .value("Flow", item.mean))
                .foregroundStyle(Theme.glowCore)
                .interpolationMethod(.monotone)
            PointMark(x: .value("Day", item.day, unit: .day),
                      y: .value("Flow", item.mean))
                .foregroundStyle(Theme.glowBright)
                .symbolSize(18)
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .chartYScale(domain: 0...100)
        .frame(height: 140)
        .clipped()
    }

    // MARK: data

    private func reload() {
        heroScore = model.heroFlowScore()
        trend = model.flowTrend()
    }
}
