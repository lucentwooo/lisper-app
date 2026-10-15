# Simplify Lisper + Multi-Key Hotkey Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Strip the coach/coherence machinery the user never visits, reduce Insights to a working Flow Score + trend graph, drop the Formal style mode, and let several hotkeys trigger dictation at once.

**Architecture:** All logic lands in `Sources/LisperKit/` (unit-tested); `Sources/Lisper/` stays a thin AppKit/SwiftUI shell. Flow Score becomes fully deterministic — computed from stored `SessionRecord`s on read — so it no longer depends on persisted LLM analyses. The hotkey gains a pure `HotkeySetDecision` type that owns multi-key arbitration, keeping `HotkeyMonitor` dumb.

**Tech Stack:** Swift 5 language mode, macOS 15, SPM only, Swift Testing (`@Suite`/`@Test`/`#expect`), GRDB/SQLite, SwiftUI + Swift Charts.

## Global Constraints

- Swift language mode v5 (`.swiftLanguageMode(.v5)` on every target), platform `.macOS(.v15)`. **SPM only — never generate an Xcode project.**
- **Run tests with `swift run LisperKitTests`.** Plain `swift test` exits 0 but executes NOTHING on this machine. `--filter` is unsupported — always run the full suite.
- All UI colors/type/spacing come from the `Theme` namespace. Dark-only. Never hardcode colors.
- LisperKit is developed **test-first**. Commit after every task.
- Coach stats are computed from **raw** transcripts (pre-cleanup), never cleaned text.
- **Never use `Calendar.current` or default `DateFormatter` date handling.** This machine's system calendar is Buddhist, which corrupts default date formatting. Always construct `Calendar(identifier: .gregorian)` explicitly.
- Engine/model identifiers stay user-editable settings strings, never constants at call sites.
- Do not change `Theme` token names or file paths.
- The app must be run as `dist/Lisper.app` via `./scripts/run.sh`, never the bare `.build` binary — TCC permissions and Info.plist only apply to the bundle.

### A note on task ordering

Task 2 is deliberately large. `FlowScore`'s signature change, the engine deletion, and the
Insights rewrite are **mutually dependent** — `CoachAnalysisService` calls the old `FlowScore`
signature and `CoachView` renders the deleted types, so any smaller split leaves the build red at a
task boundary. Every task below ends green.

---

### Task 1: Daily-mean trend aggregation

The trend graph's root cause is one point per session on a day-unit axis. This adds the pure aggregation that fixes it. Fully independent — nothing else changes.

**Files:**
- Create: `Sources/LisperKit/Coach/FlowTrend.swift`
- Test: `Tests/LisperKitTests/FlowTrendTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `FlowTrend.dailyMeans(_ points: [(date: Date, overall: Int)], calendar: Calendar) -> [(day: Date, mean: Int)]`, sorted ascending by day, one entry per calendar day, each the rounded mean of that day's scores.

- [ ] **Step 1: Write the failing test**

Create `Tests/LisperKitTests/FlowTrendTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `swift run LisperKitTests`
Expected: FAIL — compile error, cannot find `FlowTrend` in scope.

- [ ] **Step 3: Create `Sources/LisperKit/Coach/FlowTrend.swift`**

```swift
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
```

- [ ] **Step 4: Run the suite**

Run: `swift run LisperKitTests`
Expected: PASS — `FlowTrendTests` (4 tests) green, everything else unchanged.

- [ ] **Step 5: Commit**

```bash
git add Sources/LisperKit/Coach/FlowTrend.swift Tests/LisperKitTests/FlowTrendTests.swift
git commit -m "feat: FlowTrend.dailyMeans — one averaged point per day for the trend chart"
```

---

### Task 2: Remove the coach engine, reduce Flow Score to 3 tiles, rebuild Insights

One atomic task (see "A note on task ordering"). Order inside the task: write the new `FlowScore` tests → delete the engine → rewrite `FlowScore` → rewrite the UI → green.

**Files:**
- Modify: `Sources/LisperKit/Coach/FlowScore.swift` (rewrite)
- Test: `Tests/LisperKitTests/FlowScoreTests.swift` (rewrite)
- Delete: `Sources/LisperKit/Coach/{CoherenceAnalyzer,CoherenceModels,DailyDigestGenerator,CoachAnalysisService,CoachMetrics,Playbook,WeeklyTipGenerator}.swift`, `Sources/LisperKit/Coach/Playbook/` (dir), `Sources/LisperKit/Stats/{VocabularyStats,FillerContexts}.swift`, `Sources/LisperKit/Store/{WeeklyTip,SessionAnalysis}.swift`
- Delete tests: `CoachAnalysisServiceTests.swift`, `CoachMetricsTests.swift`, `CoachPersistenceTests.swift`, `CoachSettingsTests.swift`, `CoherenceParseTests.swift`, `CoherenceScoreTests.swift`, `DailyDigestTests.swift`, `PlaybookTests.swift`, `VocabularyPromptTests.swift`, `VocabularyStatsTests.swift`
- Modify: `Sources/LisperKit/Stats/SpeechPatterns.swift` — **keep `DisfluencyStats`**, delete `RepeatedPhrase` + `RepeatedPhraseDetector`
- Modify: `Tests/LisperKitTests/SpeechPatternsTests.swift` — delete repeated-phrase tests, keep disfluency tests
- Modify: `Package.swift` — remove `resources: [.process("Coach/Playbook")]`
- Modify: `Sources/LisperKit/Settings/AppSettings.swift` — remove `coachAnalysisEnabled`
- Modify: `Sources/LisperKit/Store/LisperDatabase.swift` — remove analysis / weekly-tip accessors
- Modify: `Sources/Lisper/AppEnvironment.swift:67-81`, `Sources/Lisper/AppDelegate.swift:104,245`, `Sources/Lisper/UI/Main/SettingsView.swift`
- Modify: `Sources/Lisper/UI/Main/MainViewModel.swift:100-139` (replace helper block)
- Modify: `Sources/Lisper/UI/Main/CoachView.swift` (full replacement)

**Interfaces:**
- Consumes: `FlowTrend.dailyMeans(_:calendar:)` (Task 1), `TranscriptStats`, `DisfluencyStats`.
- Produces: `FlowScore(overall:fillerFree:continuity:sustain:)`, `FlowScore.compute(stats:disfluency:durationSeconds:)`, `MainViewModel.heroFlowScore() -> FlowScore?`, `MainViewModel.flowTrend(limit:) -> [(day: Date, mean: Int)]`.

> **Landmine:** `DisfluencyStats` lives *inside* `SpeechPatterns.swift` and is still needed by `FlowScore`. Deleting that file wholesale breaks the build.
>
> **No SQL migration.** Existing `session_analyses` / `weekly_tips` rows stay in SQLite, unread and inert. Dropping tables gains nothing and risks data loss.

- [ ] **Step 1: Replace `Tests/LisperKitTests/FlowScoreTests.swift`**

The old file tests the coherence branch, which is being deleted. Replace the whole file:

```swift
import Testing
@testable import LisperKit

@Suite struct FlowScoreTests {

    /// A clean 60s take: no fillers, no disfluency, full sustain -> a perfect score.
    @Test func testCleanSustainedTakeScoresFull() {
        let raw = String(repeating: "clear words here ", count: 20)
        let stats = TranscriptStats.compute(raw: raw, durationSeconds: 60, customFillers: [])
        let dis = DisfluencyStats.compute(raw: raw)
        let f = FlowScore.compute(stats: stats, disfluency: dis, durationSeconds: 60)
        #expect(f.fillerFree == 100)
        #expect(f.continuity == 100)
        #expect(f.sustain == 100)
        #expect(f.overall == 100)
    }

    /// Sustain is linear against the 60s target and clamps at 100.
    @Test func testSustainScalesToSixtySeconds() {
        let stats = TranscriptStats.compute(raw: "one two three four",
                                            durationSeconds: 30, customFillers: [])
        let dis = DisfluencyStats.compute(raw: "one two three four")
        #expect(FlowScore.compute(stats: stats, disfluency: dis, durationSeconds: 30).sustain == 50)
        #expect(FlowScore.compute(stats: stats, disfluency: dis, durationSeconds: 120).sustain == 100)
    }

    /// Fillers drive fillerFree down; the ceiling is 12 fillers/100 words.
    @Test func testFillersReduceFillerFree() {
        let raw = "um " + String(repeating: "word ", count: 99)   // ~1 filler / 100 words
        let stats = TranscriptStats.compute(raw: raw, durationSeconds: 60, customFillers: [])
        let dis = DisfluencyStats.compute(raw: raw)
        let f = FlowScore.compute(stats: stats, disfluency: dis, durationSeconds: 60)
        #expect(f.fillerFree < 100)
        #expect(f.fillerFree > 80)
    }

    /// Overall uses the deterministic weights: 0.45 / 0.35 / 0.20.
    @Test func testOverallUsesDeterministicWeights() {
        let raw = String(repeating: "word ", count: 100)
        let stats = TranscriptStats.compute(raw: raw, durationSeconds: 30, customFillers: [])
        let dis = DisfluencyStats.compute(raw: raw)
        let f = FlowScore.compute(stats: stats, disfluency: dis, durationSeconds: 30)
        let expected = Int((Double(f.fillerFree) * 0.45
                            + Double(f.continuity) * 0.35
                            + Double(f.sustain) * 0.20).rounded())
        #expect(f.overall == expected)
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `swift run LisperKitTests`
Expected: FAIL — compile error, `compute(stats:disfluency:durationSeconds:)` does not exist (the current signature requires `coherence:`).

- [ ] **Step 3: Delete the engine files**

```bash
git rm -r Sources/LisperKit/Coach/CoherenceAnalyzer.swift \
          Sources/LisperKit/Coach/CoherenceModels.swift \
          Sources/LisperKit/Coach/DailyDigestGenerator.swift \
          Sources/LisperKit/Coach/CoachAnalysisService.swift \
          Sources/LisperKit/Coach/CoachMetrics.swift \
          Sources/LisperKit/Coach/Playbook.swift \
          Sources/LisperKit/Coach/WeeklyTipGenerator.swift \
          Sources/LisperKit/Coach/Playbook \
          Sources/LisperKit/Stats/VocabularyStats.swift \
          Sources/LisperKit/Stats/FillerContexts.swift \
          Sources/LisperKit/Store/WeeklyTip.swift \
          Sources/LisperKit/Store/SessionAnalysis.swift \
          Tests/LisperKitTests/CoachAnalysisServiceTests.swift \
          Tests/LisperKitTests/CoachMetricsTests.swift \
          Tests/LisperKitTests/CoachPersistenceTests.swift \
          Tests/LisperKitTests/CoachSettingsTests.swift \
          Tests/LisperKitTests/CoherenceParseTests.swift \
          Tests/LisperKitTests/CoherenceScoreTests.swift \
          Tests/LisperKitTests/DailyDigestTests.swift \
          Tests/LisperKitTests/PlaybookTests.swift \
          Tests/LisperKitTests/VocabularyPromptTests.swift \
          Tests/LisperKitTests/VocabularyStatsTests.swift
```

- [ ] **Step 4: Remove the Playbook resource from `Package.swift`**

Change the `LisperKit` target from:

```swift
        .target(
            name: "LisperKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            resources: [.process("Coach/Playbook")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
```

to:

```swift
        .target(
            name: "LisperKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
```

- [ ] **Step 5: Rewrite `Sources/LisperKit/Coach/FlowScore.swift`**

```swift
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
```

- [ ] **Step 6: Trim `SpeechPatterns.swift` to `DisfluencyStats` only**

Delete `RepeatedPhrase` (line 3) and `RepeatedPhraseDetector` (line 9) with their doc comments. Keep `DisfluencyStats` (line 41) exactly as-is. Then delete the repeated-phrase `@Test` functions from `Tests/LisperKitTests/SpeechPatternsTests.swift`, keeping every disfluency test.

- [ ] **Step 7: Remove `coachAnalysisEnabled` from `AppSettings.swift`**

Delete all three occurrences:
- the property `public var coachAnalysisEnabled: Bool = true`
- `coachAnalysisEnabled` from the `CodingKeys` case list
- `coachAnalysisEnabled = try c.decodeIfPresent(Bool.self, forKey: .coachAnalysisEnabled) ?? d.coachAnalysisEnabled`

Tolerant decoding means an old stored blob still containing the key decodes fine — unknown keys are ignored.

- [ ] **Step 8: Replace the Flow-coach helper block in `MainViewModel.swift`**

Delete lines 100–139 (from `// MARK: Flow coach helpers` through the end of `heroFlowScore()`) and insert:

```swift
    // MARK: Flow Score helpers — deterministic, computed from stored sessions

    /// Flow Score for a session, computed on read. Nothing is persisted: the score is a
    /// pure function of the raw transcript + duration, so the whole history scores itself
    /// (previously only LLM-analysed sessions had a score, which starved the trend chart).
    private func flowScore(for s: SessionRecord) -> FlowScore {
        let stats = TranscriptStats.compute(raw: s.rawTranscript,
                                            durationSeconds: s.durationSeconds, customFillers: [])
        let dis = DisfluencyStats.compute(raw: s.rawTranscript)
        return FlowScore.compute(stats: stats, disfluency: dis, durationSeconds: s.durationSeconds)
    }

    /// Sessions shorter than this don't say much about flow, so they're excluded.
    private static let minWordsForFlow = 40

    /// The most recent qualifying session's score.
    func heroFlowScore() -> FlowScore? {
        guard let s = (try? env.database.recentSessions(limit: 30))?
            .first(where: { $0.wordCount >= Self.minWordsForFlow }) else { return nil }
        return flowScore(for: s)
    }

    /// One averaged point per day for the trend chart.
    func flowTrend(limit: Int = 200) -> [(day: Date, mean: Int)] {
        let sessions = (try? env.database.recentSessions(limit: limit)) ?? []
        let points = sessions
            .filter { $0.wordCount >= Self.minWordsForFlow }
            .map { (date: $0.startedAt, overall: flowScore(for: $0).overall) }
        var cal = Calendar(identifier: .gregorian)   // never Calendar.current — Buddhist system calendar
        cal.timeZone = .current
        return FlowTrend.dailyMeans(points, calendar: cal)
    }
```

Also delete the `.lisperAnalysisUpdated` notification-name extension from this file.

- [ ] **Step 9: Replace `Sources/Lisper/UI/Main/CoachView.swift` entirely**

```swift
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

                if let hero = heroScore {
                    flowHeroSection(hero).padding(.top, 30)
                    if trend.count >= 2 {
                        Text("Trend").sectionLabel().padding(.top, 28)
                        VStack(spacing: 0) {
                            Divider().overlay(Theme.hairline)
                            flowSparkline.padding(.top, 12)
                        }
                        .padding(.top, 8)
                    }
                } else {
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
```

- [ ] **Step 10: Remove every remaining reference, compiler-driven**

Run: `swift build`

Work through the errors, **deleting** (never stubbing) each reference:
- `AppEnvironment.swift`: delete `coachService()` and `digestGenerator()` entirely.
- `AppDelegate.swift`: delete the `if let svc = env.coachService() { … }` blocks at ~line 104 (launch catch-up) and ~line 245 (per-session trigger).
- `LisperDatabase.swift`: delete `recentAnalyses`, `analysis(forSession:)`, `dailyInsight(day:)`, `saveAnalysis` and the weekly-tip accessors. **Leave existing migrations untouched** so historical databases still open.
- `SettingsView.swift`: delete the coach-analysis toggle row.

Repeat `swift build` until it succeeds.

- [ ] **Step 11: Run the suite**

Run: `swift run LisperKitTests`
Expected: PASS. The total drops (deleted suites are gone); `FlowScoreTests` and `FlowTrendTests` are green.

- [ ] **Step 12: Verify no orphans remain**

Run:
```bash
grep -rn "Coherence\|Playbook\|DailyDigest\|CoachAnalysis\|CoachSummary\|VocabularyStats\|RepeatedPhrase\|FillerContext\|WeeklyTip\|SessionAnalysis\|coachAnalysisEnabled\|lisperAnalysisUpdated" Sources/ Tests/
```
Expected: no output.

- [ ] **Step 13: Commit**

```bash
git add -A
git commit -m "refactor: remove the coach/coherence engine; Insights becomes Flow Score + trend

Deletes CoherenceAnalyzer, CoachAnalysisService, DailyDigestGenerator, Playbook,
WeeklyTipGenerator, CoachMetrics, VocabularyStats, FillerContexts and the analysis
persistence types. Stops one Groq LLM call per dictation, cutting API cost and latency.

Flow Score drops its coherence-derived single-thread component and is now computed
deterministically from stored sessions, so the entire history charts instead of only
LLM-analysed sessions. Fixes the spiking trend graph: one averaged point per DAY (was one
per session on a day-unit axis, so same-day takes shared an x value and catmullRom
overshot) plus .monotone interpolation, which cannot overshoot.

DisfluencyStats is kept (FlowScore needs it). Existing analysis rows stay in SQLite,
unread — no destructive migration."
```

---

### Task 3: Remove the Formal style mode

`StyleMode` would be left with a single case, so the concept is removed entirely rather than kept as a one-case enum.

**Files:**
- Modify: `Sources/LisperKit/Settings/AppSettings.swift` (delete `StyleMode`, `styleMode`)
- Modify: `Sources/LisperKit/Cleanup/CleanupContext.swift` (drop `style`)
- Modify: `Sources/LisperKit/Cleanup/CleanupPromptBuilder.swift:31-32` (drop the formal branch)
- Modify: `Sources/Lisper/UI/Main/SettingsView.swift:78-84` (delete the style picker)
- Test: `Tests/LisperKitTests/SettingsTests.swift`, `Tests/LisperKitTests/PromptBuilderTests.swift`

**Interfaces:**
- Produces: `CleanupContext(appName:bundleID:dictionaryTerms:)` — the `style:` parameter is gone; every call site must be updated.

- [ ] **Step 1: Add the migration guard test**

Add to `Tests/LisperKitTests/SettingsTests.swift` inside the existing `@Suite`:

```swift
    /// A settings blob stored by an older build still contains "styleMode":"formal".
    /// Tolerant decoding must ignore the now-unknown key rather than resetting EVERY
    /// setting to defaults (SettingsStore wipes everything on a decode error).
    @Test func testLegacyFormalStyleModeDecodesWithoutThrowing() throws {
        let json = #"{"styleMode":"formal","llmCleanupEnabled":false}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.llmCleanupEnabled == false)   // the rest of the blob survived
    }
```

This is a **regression guard**, not a red-green test: it passes both before and after, and its job is to fail if Step 2 is done by deleting the tolerant-decode path rather than the key. Run `swift run LisperKitTests` and confirm it passes now.

- [ ] **Step 2: Delete `StyleMode` and every reference**

In `AppSettings.swift`, delete:

```swift
public enum StyleMode: String, Codable, CaseIterable, Sendable {
    case formal, casual
}
```

plus the property `public var styleMode: StyleMode = .casual`, the `styleMode` `CodingKeys` case, and the decode line `styleMode = try c.decodeIfPresent(...)`.

Rewrite `CleanupContext.swift`:

```swift
public struct CleanupContext: Sendable {
    public let appName: String
    public let bundleID: String
    public let dictionaryTerms: [String]
    public init(appName: String, bundleID: String, dictionaryTerms: [String]) {
        self.appName = appName; self.bundleID = bundleID; self.dictionaryTerms = dictionaryTerms
    }
}
```

In `CleanupPromptBuilder.swift`, delete the `switch context.style` statement and both branches, keeping the casual guidance as unconditional prompt text.

In `SettingsView.swift`, delete the style-mode picker rows (~lines 78–84).

- [ ] **Step 3: Fix call sites, compiler-driven**

Run: `swift build`
Update every `CleanupContext(...)` construction to drop `style:`. Repeat until it builds.

- [ ] **Step 4: Update the prompt tests**

Run: `swift run LisperKitTests`
In `PromptBuilderTests.swift`, delete any test asserting formal-style prompt text and drop `style:` from the remaining `CleanupContext` constructions. **Keep** the tests asserting the meaning-preservation contract (the prompt must forbid answering questions or adding content) — that contract is unchanged.

- [ ] **Step 5: Run the suite**

Run: `swift run LisperKitTests`
Expected: PASS.

- [ ] **Step 6: Verify no orphans**

Run: `grep -rn "StyleMode\|styleMode" Sources/ Tests/`
Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: remove the Formal style mode

Cleanup is always casual, so StyleMode and CleanupContext.style are removed rather than
kept as a one-case enum. A stored \"formal\" value decodes harmlessly via tolerant decoding."
```

---

### Task 4: `HotkeyChoice.keyCode` + `AppSettings.hotkeys`

Moves the keycode table out of the app target and migrates the single-key setting to a list.

**Files:**
- Modify: `Sources/LisperKit/Settings/AppSettings.swift`
- Test: `Tests/LisperKitTests/SettingsTests.swift`

**Interfaces:**
- Produces: `HotkeyChoice.keyCode: UInt16`, `HotkeyChoice.isModifier: Bool`, `AppSettings.hotkeys: [HotkeyChoice]` (never empty).

- [ ] **Step 1: Write the failing tests**

Add to `Tests/LisperKitTests/SettingsTests.swift` inside the existing `@Suite`:

```swift
    @Test func testHotkeyKeyCodes() {
        #expect(HotkeyChoice.fn.keyCode == 63)
        #expect(HotkeyChoice.rightCommand.keyCode == 54)
        #expect(HotkeyChoice.rightOption.keyCode == 61)
        #expect(HotkeyChoice.f13.keyCode == 105)
        #expect(HotkeyChoice.f14.keyCode == 107)
        #expect(HotkeyChoice.f15.keyCode == 113)
    }

    /// Modifier keys arrive as flagsChanged; function keys as keyDown/keyUp.
    @Test func testModifierClassification() {
        #expect(HotkeyChoice.fn.isModifier)
        #expect(HotkeyChoice.rightCommand.isModifier)
        #expect(HotkeyChoice.rightOption.isModifier)
        #expect(!HotkeyChoice.f13.isModifier)
        #expect(!HotkeyChoice.f14.isModifier)
        #expect(!HotkeyChoice.f15.isModifier)
    }

    @Test func testDefaultHotkeysIsFn() {
        #expect(AppSettings().hotkeys == [.fn])
    }

    /// A blob from a single-key build migrates its `hotkey` into the new list.
    @Test func testLegacySingleHotkeyMigrates() throws {
        let json = #"{"hotkey":"f13"}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.hotkeys == [.f13])
    }

    @Test func testMissingHotkeysFallsBackToFn() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(s.hotkeys == [.fn])
    }

    /// An empty list would make the app impossible to trigger, with no in-app recovery.
    @Test func testEmptyHotkeysFallsBackToFn() throws {
        let json = #"{"hotkeys":[]}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.hotkeys == [.fn])
    }

    @Test func testDuplicateHotkeysAreRemovedPreservingOrder() throws {
        let json = #"{"hotkeys":["f13","fn","f13"]}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.hotkeys == [.f13, .fn])
    }

    /// `hotkeys` wins over a stale legacy `hotkey` in the same blob.
    @Test func testNewListWinsOverLegacyKey() throws {
        let json = #"{"hotkey":"f15","hotkeys":["fn","f13"]}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.hotkeys == [.fn, .f13])
    }

    @Test func testHotkeysRoundTripThroughEncoding() throws {
        var s = AppSettings()
        s.hotkeys = [.fn, .f13]
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data).hotkeys == [.fn, .f13])
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `swift run LisperKitTests`
Expected: FAIL — `keyCode`, `isModifier` and `hotkeys` do not exist.

- [ ] **Step 3: Extend `HotkeyChoice` in `AppSettings.swift`**

```swift
public enum HotkeyChoice: String, Codable, CaseIterable, Sendable {
    case fn, rightCommand, rightOption, f13, f14, f15

    public var label: String {
        switch self {
        case .fn: return "Fn (🌐)"
        case .rightCommand: return "Right ⌘"
        case .rightOption: return "Right ⌥"
        case .f13: return "F13"
        case .f14: return "F14"
        case .f15: return "F15"
        }
    }

    /// Virtual keycode. Single-sourced here — it used to live in the app target, where it
    /// could not be unit-tested.
    public var keyCode: UInt16 {
        switch self {
        case .fn: return 63             // kVK_Function
        case .rightCommand: return 54
        case .rightOption: return 61
        case .f13: return 105
        case .f14: return 107
        case .f15: return 113
        }
    }

    /// Modifier keys are observed via `flagsChanged`; the F-keys via keyDown/keyUp.
    public var isModifier: Bool {
        switch self {
        case .fn, .rightCommand, .rightOption: return true
        case .f13, .f14, .f15: return false
        }
    }
}
```

- [ ] **Step 4: Migrate the setting**

Replace the `hotkey` property with:

```swift
    /// Every enabled trigger key. All are live at once so the app works across a laptop
    /// keyboard (Fn) and an external one (F13–F15) without changing a setting.
    /// INVARIANT: never empty — an empty list would make the app impossible to trigger.
    public var hotkeys: [HotkeyChoice] = [.fn]
```

In `CodingKeys`, replace `case hotkey` with `case hotkey, hotkeys` (the legacy key is still read).

Replace the `hotkey` decode line with:

```swift
        // Migration: `hotkeys` (current) -> legacy single `hotkey` -> default [.fn].
        // Duplicates are removed and the list is never allowed to be empty.
        let storedList = try c.decodeIfPresent([HotkeyChoice].self, forKey: .hotkeys)
        let legacy = try c.decodeIfPresent(HotkeyChoice.self, forKey: .hotkey)
        var resolved = storedList ?? legacy.map { [$0] } ?? d.hotkeys
        var seen = Set<HotkeyChoice>()
        resolved = resolved.filter { seen.insert($0).inserted }
        hotkeys = resolved.isEmpty ? d.hotkeys : resolved
```

- [ ] **Step 5: Keep the app target compiling**

Run: `swift build`
`HotkeyMonitor.configure(hotkey:mode:)`, `SettingsView`, `HistoryView` and `OnboardingView` reference `settings.hotkey`. Temporarily use `settings.hotkeys.first ?? .fn` at each site; Task 6 replaces them properly.

- [ ] **Step 6: Run the suite**

Run: `swift run LisperKitTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: HotkeyChoice.keyCode + multi-key AppSettings.hotkeys with migration"
```

---

### Task 5: `HotkeySetDecision` — multi-key arbitration

**Files:**
- Create: `Sources/LisperKit/Input/HotkeySetDecision.swift`
- Test: `Tests/LisperKitTests/HotkeySetDecisionTests.swift`

**Interfaces:**
- Consumes: `HotkeyChoice.keyCode` / `.isModifier` (Task 4).
- Produces: `HotkeySetDecision(enabled:)`, `mutating func press(keyCode:) -> Bool`, `mutating func release(keyCode:) -> Bool`, `mutating func clearOwner()`, `var owner: HotkeyChoice?`, `func choice(forKeyCode:) -> HotkeyChoice?`, `static func isDown(eventKeyCode:choice:flagSet:physicallyDown:) -> Bool?`

- [ ] **Step 1: Write the failing test**

Create `Tests/LisperKitTests/HotkeySetDecisionTests.swift`:

```swift
import Testing
@testable import LisperKit

@Suite struct HotkeySetDecisionTests {

    @Test func testKeyCodeOutsideEnabledSetIsIgnored() {
        var d = HotkeySetDecision(enabled: [.fn])
        #expect(d.choice(forKeyCode: HotkeyChoice.f13.keyCode) == nil)
        #expect(!d.press(keyCode: HotkeyChoice.f13.keyCode))
        #expect(d.owner == nil)
    }

    @Test func testEnabledKeyPressStartsTakeAndTakesOwnership() {
        var d = HotkeySetDecision(enabled: [.fn, .f13])
        #expect(d.press(keyCode: HotkeyChoice.f13.keyCode))
        #expect(d.owner == .f13)
    }

    /// OWNERSHIP: every historical hotkey bug in this app is a phantom release from an
    /// unrelated event. A second enabled key must be structurally unable to end the
    /// first key's take.
    @Test func testSecondEnabledKeyIsIgnoredWhileFirstIsHeld() {
        var d = HotkeySetDecision(enabled: [.fn, .f13])
        #expect(d.press(keyCode: HotkeyChoice.fn.keyCode))
        #expect(!d.press(keyCode: HotkeyChoice.f13.keyCode))     // no second take
        #expect(!d.release(keyCode: HotkeyChoice.f13.keyCode))   // CANNOT end the owner's take
        #expect(d.owner == .fn)
    }

    @Test func testOwnerReleaseEndsTakeAndClearsOwnership() {
        var d = HotkeySetDecision(enabled: [.fn, .f13])
        _ = d.press(keyCode: HotkeyChoice.fn.keyCode)
        #expect(d.release(keyCode: HotkeyChoice.fn.keyCode))
        #expect(d.owner == nil)
    }

    @Test func testRepeatPressFromOwnerDoesNotRestart() {
        var d = HotkeySetDecision(enabled: [.fn])
        #expect(d.press(keyCode: HotkeyChoice.fn.keyCode))
        #expect(!d.press(keyCode: HotkeyChoice.fn.keyCode))   // key repeat
    }

    @Test func testReleaseWithoutPressIsNotAnEnd() {
        var d = HotkeySetDecision(enabled: [.fn])
        #expect(!d.release(keyCode: HotkeyChoice.fn.keyCode))
    }

    @Test func testAfterOwnerReleasesAnotherKeyMayStartATake() {
        var d = HotkeySetDecision(enabled: [.fn, .f13])
        _ = d.press(keyCode: HotkeyChoice.fn.keyCode)
        _ = d.release(keyCode: HotkeyChoice.fn.keyCode)
        #expect(d.press(keyCode: HotkeyChoice.f13.keyCode))
        #expect(d.owner == .f13)
    }

    @Test func testClearOwnerAllowsAFreshPress() {
        var d = HotkeySetDecision(enabled: [.fn])
        _ = d.press(keyCode: HotkeyChoice.fn.keyCode)
        d.clearOwner()
        #expect(d.press(keyCode: HotkeyChoice.fn.keyCode))
    }

    /// Fn semantics preserved: the `.function` flag clears while the key is still
    /// physically held, so EITHER signal means "down".
    @Test func testFnIsDownWhenFlagClearsButKeyIsPhysicallyHeld() {
        #expect(HotkeySetDecision.isDown(eventKeyCode: HotkeyChoice.fn.keyCode,
                                         choice: .fn, flagSet: false, physicallyDown: true) == true)
    }

    @Test func testFnIsUpWhenBothSignalsAreFalse() {
        #expect(HotkeySetDecision.isDown(eventKeyCode: HotkeyChoice.fn.keyCode,
                                         choice: .fn, flagSet: false, physicallyDown: false) == false)
    }

    /// nil means "ignore this event entirely" — it must NEVER be read as a release.
    @Test func testMismatchedKeyCodeReturnsNilNotFalse() {
        #expect(HotkeySetDecision.isDown(eventKeyCode: 99,
                                         choice: .fn, flagSet: true, physicallyDown: true) == nil)
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `swift run LisperKitTests`
Expected: FAIL — cannot find `HotkeySetDecision` in scope.

- [ ] **Step 3: Create `Sources/LisperKit/Input/HotkeySetDecision.swift`**

```swift
// Sources/LisperKit/Input/HotkeySetDecision.swift

/// Pure, testable arbitration for a SET of simultaneously-enabled hotkeys.
///
/// Generalises `FnKeyDecision` from "is this the Fn key" to "is this one of my enabled
/// keys", and adds ownership.
///
/// Ownership is the load-bearing part. Every historical hotkey bug in this app is a
/// *phantom release* — an unrelated event interpreted as "the key went up", ending a take
/// that was still in progress (DEBUGGING-LOG 2026-06-14c, 2026-06-29, 2026-06-30).
/// Enabling several keys at once multiplies exactly that risk, so the first key down owns
/// the take and every other enabled key is ignored until the owner releases. A non-owning
/// key is structurally incapable of ending someone else's take.
public struct HotkeySetDecision {
    public let enabled: [HotkeyChoice]
    public private(set) var owner: HotkeyChoice?

    public init(enabled: [HotkeyChoice]) {
        self.enabled = enabled
    }

    /// The enabled choice for a keycode, or nil when the key isn't one of ours.
    public func choice(forKeyCode code: UInt16) -> HotkeyChoice? {
        enabled.first { $0.keyCode == code }
    }

    /// - Returns: true when this press should START a take.
    public mutating func press(keyCode: UInt16) -> Bool {
        guard let choice = choice(forKeyCode: keyCode) else { return false }
        guard owner == nil else { return false }   // key repeat, or a non-owning key
        owner = choice
        return true
    }

    /// - Returns: true when this release should END the take. Only the owner can.
    public mutating func release(keyCode: UInt16) -> Bool {
        guard let choice = choice(forKeyCode: keyCode), choice == owner else { return false }
        owner = nil
        return true
    }

    /// The take ended by some other route (Esc, a lock finished elsewhere) — drop ownership
    /// so the next press starts cleanly.
    public mutating func clearOwner() {
        owner = nil
    }

    /// Pressed-state for a modifier hotkey event.
    ///
    /// - Returns: nil when the event is not this key and must be IGNORED. Never treat nil
    ///   as a release — that is precisely the phantom-release bug.
    ///
    /// A key counts as down when EITHER its modifier flag OR its physical key state says
    /// so: the Fn/Globe `.function` flag clears spuriously while the key is still held.
    public static func isDown(eventKeyCode: UInt16, choice: HotkeyChoice,
                              flagSet: Bool, physicallyDown: Bool) -> Bool? {
        guard eventKeyCode == choice.keyCode else { return nil }
        return flagSet || physicallyDown
    }
}
```

- [ ] **Step 4: Run the suite**

Run: `swift run LisperKitTests`
Expected: PASS (11 new tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LisperKit/Input/HotkeySetDecision.swift Tests/LisperKitTests/HotkeySetDecisionTests.swift
git commit -m "feat: HotkeySetDecision — multi-key arbitration with single-owner semantics"
```

---

### Task 6: Wire multi-key into the app

**Files:**
- Modify: `Sources/Lisper/Input/HotkeyMonitor.swift`
- Modify: `Sources/Lisper/UI/Main/SettingsView.swift:17-30`
- Modify: `Sources/Lisper/UI/Main/HistoryView.swift:50`
- Modify: `Sources/Lisper/UI/Onboarding/OnboardingView.swift`
- Modify: `Sources/Lisper/AppDelegate.swift`

**Interfaces:**
- Consumes: `HotkeySetDecision` (Task 5), `AppSettings.hotkeys` (Task 4).
- Produces: `HotkeyMonitor.configure(hotkeys: [HotkeyChoice], mode: HotkeyMode)`.

- [ ] **Step 1: Replace the key-identity and dispatch members of `HotkeyMonitor.swift`**

Replace the stored `hotkey` / `hotkeyKeyCode` / `keyIsDown` members and `configure`:

```swift
    private(set) var hotkeys: [HotkeyChoice] = [.fn]
    private var decision = HotkeySetDecision(enabled: [.fn])

    func configure(hotkeys: [HotkeyChoice], mode: HotkeyMode) {
        self.hotkeys = hotkeys.isEmpty ? [.fn] : hotkeys
        self.decision = HotkeySetDecision(enabled: self.hotkeys)
        self.mode = mode
        stop(); start()
    }
```

Replace `handleFlags` and `handleKey`:

```swift
    private func handleFlags(_ event: NSEvent) {
        guard !isPaused else { return }
        // Only modifier hotkeys arrive as flagsChanged.
        guard let choice = decision.choice(forKeyCode: event.keyCode), choice.isModifier else { return }
        let physical = CGEventSource.keyState(.combinedSessionState, key: choice.keyCode)
        let flagSet: Bool
        switch choice {
        case .fn: flagSet = event.modifierFlags.contains(.function)
        case .rightCommand: flagSet = event.modifierFlags.rawValue & 0x0010 != 0  // NX_DEVICERCMDKEYMASK
        case .rightOption: flagSet = event.modifierFlags.rawValue & 0x0040 != 0   // NX_DEVICERALTKEYMASK
        default: return
        }
        guard let isDown = HotkeySetDecision.isDown(eventKeyCode: event.keyCode, choice: choice,
                                                    flagSet: flagSet, physicallyDown: physical)
        else { return }   // not ours — ignore, never a release
        HotkeyTrace.log("flags key=\(choice) code=\(event.keyCode) flag=\(flagSet) phys=\(physical) -> down=\(isDown)")
        transition(keyCode: choice.keyCode, down: isDown)
    }

    private func handleKey(_ event: NSEvent, down: Bool) {
        guard !isPaused else { return }
        guard let choice = decision.choice(forKeyCode: event.keyCode), !choice.isModifier else { return }
        transition(keyCode: choice.keyCode, down: down)
    }
```

Replace `transition` — ownership replaces the old `keyIsDown` flag:

```swift
    private func transition(keyCode: UInt16, down: Bool) {
        HotkeyTrace.log("transition code=\(keyCode) down=\(down) owner=\(String(describing: decision.owner)) mode=\(mode)")
        switch mode {
        case .hold:
            if down, decision.press(keyCode: keyCode) {
                HotkeyTrace.log("  -> PRESS edge"); _ = onPress?(); startWatchdog()
            } else if !down, decision.release(keyCode: keyCode) {
                HotkeyTrace.log("  -> RELEASE edge"); _ = onRelease?(); stopWatchdog()
            } else {
                HotkeyTrace.log("  -> no edge (ignored)")
            }
        case .toggle:
            guard down, decision.press(keyCode: keyCode) else { return }
            decision.clearOwner()   // in toggle mode a press is an edge, not a hold
            toggledOn.toggle()
            if toggledOn { _ = onPress?() } else { _ = onRelease?() }
        }
    }
```

Update the watchdog to poll the **owner's** keycode:

```swift
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let owner = self.decision.owner else { self?.stopWatchdog(); return }
            // Physical key state — catches releases the event monitors never saw
            // (e.g. swallowed by a secure-input field).
            if !CGEventSource.keyState(.combinedSessionState, key: owner.keyCode) {
                HotkeyTrace.log("watchdog: owner \(owner) physically released -> synth release")
                self.transition(keyCode: owner.keyCode, down: false)
            }
        }
    }
```

In `stop()`, replace `keyIsDown = false` with `decision.clearOwner()`. In `noteSessionEnded()`, add `decision.clearOwner()` alongside `toggledOn = false`.

- [ ] **Step 2: Update `AppDelegate.swift`**

Change every `hotkey.configure(hotkey: settings.hotkey, mode: settings.hotkeyMode)` call to:

```swift
hotkey.configure(hotkeys: settings.hotkeys, mode: settings.hotkeyMode)
```

- [ ] **Step 3: Replace the Settings key picker**

In `SettingsView.swift`, replace the `Picker("Key", …)` block (~lines 19–21) with a multi-select list that cannot reach zero:

```swift
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Keys").sectionLabel()
                            ForEach(HotkeyChoice.allCases, id: \.self) { choice in
                                let isOn = model.settings.hotkeys.contains(choice)
                                // The last remaining key can't be unticked — a zero-key
                                // state would make the app impossible to trigger.
                                let isLast = isOn && model.settings.hotkeys.count == 1
                                Toggle(choice.label, isOn: Binding(
                                    get: { isOn },
                                    set: { on in
                                        var keys = model.settings.hotkeys
                                        if on {
                                            if !keys.contains(choice) { keys.append(choice) }
                                        } else {
                                            keys.removeAll { $0 == choice }
                                        }
                                        if !keys.isEmpty { model.settings.hotkeys = keys }
                                    }))
                                    .disabled(isLast)
                                    .toggleStyle(.checkbox)
                            }
                            Text("All ticked keys work at once — handy across a laptop and an external keyboard.")
                                .font(.system(size: 11)).foregroundColor(Theme.textFaint)
                        }
```

Also change the `if model.settings.hotkey == .fn` conditional (~line 26) to `if model.settings.hotkeys.contains(.fn)`.

- [ ] **Step 4: Update the labels**

In `HistoryView.swift:50`, replace:

```swift
                    Text("Hold \(model.settings.hotkey.label) anywhere and start talking")
```

with:

```swift
                    Text("Hold \(model.settings.hotkeys.map(\.label).joined(separator: " or ")) anywhere and start talking")
```

Apply the same `.map(\.label).joined(separator: " or ")` treatment to the hotkey label in `OnboardingView.swift`.

- [ ] **Step 5: Build and run the suite**

Run: `swift build && swift run LisperKitTests`
Expected: build succeeds, all tests pass.

- [ ] **Step 6: Verify in the real app**

Run: `./scripts/run.sh`

Then, by hand:
1. Settings → tick **Fn** and **F13**.
2. Hold Fn, speak, release → text is inserted.
3. Hold F13 (external keyboard), speak, release → text is inserted.
4. Hold Fn and, while still holding, tap F13 → the take must NOT end; releasing Fn ends it.
5. Untick every key but one → the last toggle is disabled.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: multiple hotkeys live at once

All ticked keys trigger dictation, so the app works across a laptop keyboard (Fn) and an
external one (F13-F15) with no setting change. HotkeySetDecision arbitrates: the first key
down owns the take and other keys cannot end it."
```

---

### Task 7: Update the docs

**Files:**
- Modify: `docs/DEBUGGING-LOG.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add the trend-graph bug to `docs/DEBUGGING-LOG.md`**

Add a row to the symptom→cause table:

```markdown
| **Chart spikes** shooting out of the plot area | Duplicate x values. Plotting one point per SESSION on a `unit: .day` axis puts several points on the same x, and `.catmullRom` interpolation through them overshoots violently. Aggregate to one point per day and use `.monotone` (which cannot overshoot). → [2026-08-02b](#2026-08-02--flow-score-trend-chart-spikes-out-of-the-plot-area) |
```

And this entry immediately above the `## Entry template` heading:

```markdown
### 2026-08-02 — Flow Score trend chart spikes out of the plot area

- **Symptom:** the Insights trend chart drew tall translucent spikes escaping the plot area.
- **Root cause:** two compounding defects in `CoachView.flowSparkline`. (1) It plotted one point
  per **session** against a `unit: .day` x axis, so every take in a day landed on the same x —
  visible as vertically stacked dots (52/68/78 on 19 Jul). (2) `.interpolationMethod(.catmullRom)`
  through duplicate x values overshoots violently, and the `AreaMark` rendered the overshoot.
- **Fix:** `FlowTrend.dailyMeans` collapses each day to one mean point (removing the duplicate x at
  the source, which is what a "trend" means anyway) and the chart uses `.monotone`, which cannot
  overshoot, plus `.clipped()` as a backstop.
- **Lesson:** a spline through duplicate/near-duplicate x values will overshoot. Aggregate to the
  axis's unit BEFORE plotting, and prefer `.monotone` for any monotonic-ish series.
```

- [ ] **Step 2: Update `CLAUDE.md`**

In "What this is", replace:

> Local SQLite history powers a speaking-coach dashboard (filler words, WPM, weekly LLM tips).

with:

> Local SQLite history powers a minimal Insights page (a deterministic Flow Score + per-day trend).

In "Architecture", remove `coach metrics` from the LisperKit responsibilities list.

**Keep** the hard rule "Coach stats are computed from raw transcripts (pre-cleanup), not cleaned text" — `FlowScore` still reads raw transcripts, so it still applies.

- [ ] **Step 3: Commit**

```bash
git add docs/DEBUGGING-LOG.md CLAUDE.md
git commit -m "docs: log the trend-chart spike bug; update CLAUDE.md for the slimmed app"
```

---

## Verification

After Task 7:

- [ ] `swift build` — clean
- [ ] `swift run LisperKitTests` — all pass
- [ ] `grep -rn "Coherence\|Playbook\|DailyDigest\|CoachAnalysis\|StyleMode\|coachAnalysisEnabled" Sources/ Tests/` — no output
- [ ] `./scripts/run.sh`, then confirm by hand: Insights shows a Flow Score and a spike-free trend; Settings has a multi-key list and no style picker; both a laptop key and an external key start dictation.
