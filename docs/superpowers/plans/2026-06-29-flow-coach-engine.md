# Flow Coach Engine (v1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a private, science-backed "clarity-of-thinking" coach to Lisper, centered on a deterministic **Flow Score** (the 60-second-uninterrupted-no-filler challenge as a number) computed from the user's everyday dictation, with daily→weekly→monthly trends.

**Architecture:** All scoring/selection/aggregation logic is **pure LisperKit** (unit-tested, raw-text-only). The single LLM-judgment step is *coherence extraction* (evidence-anchored, schema'd, behind a protocol), which runs **after paste, off the hot path**. The app shell only provides triggers, the `GroqClient`, the DB, and UI. Coherence reliability = **extract (LLM) → score (pure Swift) → advise (cited Playbook)**.

**Tech Stack:** Swift 6 toolchain / language mode v5, macOS 15, SPM-only, GRDB/SQLite, Swift Testing (`@Test`), Groq (OpenAI-compatible) for LLM.

## Global Constraints

- Swift language mode v5 (`.swiftLanguageMode(.v5)` on every target); platform `.macOS(.v15)`; SPM-only — never generate an Xcode project.
- Run tests with `swift run LisperKitTests` (runs the FULL suite; `swift test` executes nothing here, and `--filter` is unsupported).
- All coach stats are computed from **raw** transcripts (pre-cleanup), never cleaned text.
- Engine/model identifiers come from `AppSettings` strings (e.g. `s.groqChatModel`), never hardcoded at call sites.
- All UI colors/type/spacing come from the `Theme` namespace; dark-only; never hardcode colors.
- Do not rename existing public LisperKit types/methods, Theme tokens, or file paths. Every change in this plan is **additive**.
- All date bucketing/rendering uses an explicit **Gregorian** calendar + **`en_US`** locale (the Buddhist-system-calendar landmine on this machine corrupts default formatting).
- Test files import with `import Testing` and `@testable import LisperKit` (internal helpers like parsers are tested directly, mirroring `GroqTranscriptionParsingTests`).
- Commit after every task using the task's commit message.

---

## File Structure

**New (LisperKit — pure, tested):**
- `Sources/LisperKit/Stats/SpeechPatterns.swift` — `RepeatedPhraseDetector`, `DisfluencyStats`.
- `Sources/LisperKit/Stats/VocabularyStats.swift` — `VocabularyStats`.
- `Sources/LisperKit/Coach/CoherenceModels.swift` — `CoherenceAnalysis`, `CoherenceScore`.
- `Sources/LisperKit/Coach/FlowScore.swift` — `FlowScore`.
- `Sources/LisperKit/Coach/CoherenceAnalyzer.swift` — `ChatCompleting`, `CoherenceAnalyzer`, `LLMCoherenceAnalyzer`, `parseCoherence`, `CoherencePrompt`.
- `Sources/LisperKit/Coach/Playbook.swift` — `PlaybookCategory`, `PlaybookEntry`, `Playbook`.
- `Sources/LisperKit/Coach/Playbook/playbook.json` — seed cited corpus (bundled resource).
- `Sources/LisperKit/Coach/CoachAnalysisService.swift` — orchestration (gate/idempotent/score/persist).
- `Sources/LisperKit/Coach/DailyDigestGenerator.swift` — `DayMetrics`, `DailyDigestGenerator`, `DigestPrompt`.
- `Sources/LisperKit/Store/SessionAnalysis.swift` — `SessionAnalysis` record.
- `Sources/LisperKit/Store/DailyInsight.swift` — `DailyInsight` record.

**Modified (LisperKit):**
- `Sources/LisperKit/Engines/GroqClient.swift` — add `temperature`/`jsonObject` params to `chat`; conform to `ChatCompleting`.
- `Sources/LisperKit/Store/LisperDatabase.swift` — `v2` migration + new query methods.
- `Sources/LisperKit/Settings/AppSettings.swift` — `coachAnalysisEnabled` field.
- `Package.swift` — bundle the Playbook resource into LisperKit.

**Modified (Lisper app shell — thin, not unit-tested):**
- `Sources/Lisper/AppEnvironment.swift` — build the analyzer + `CoachAnalysisService` + `DailyDigestGenerator`.
- `Sources/Lisper/AppDelegate.swift` — trigger per-session analysis + launch catch-up.
- `Sources/Lisper/UI/Main/MainViewModel.swift` — `.lisperAnalysisUpdated`; load methods.
- `Sources/Lisper/UI/Main/CoachView.swift` — Flow Score hero + coherence/vocab/phrase panels + daily digest.
- `Sources/Lisper/UI/Main/SettingsView.swift` — `coachAnalysisEnabled` toggle.

**New tests:** one `*Tests.swift` per pure component under `Tests/LisperKitTests/`.

---

### Task 1: Speech-pattern metrics — repeated phrases + disfluency

**Files:**
- Create: `Sources/LisperKit/Stats/SpeechPatterns.swift`
- Test: `Tests/LisperKitTests/SpeechPatternsTests.swift`

**Interfaces:**
- Consumes: nothing (pure, raw text).
- Produces:
  - `RepeatedPhrase { let phrase: String; let count: Int }` (Equatable, Sendable)
  - `RepeatedPhraseDetector.detect(raw: String, minCount: Int = 3, maxN: Int = 4) -> [RepeatedPhrase]`
  - `DisfluencyStats { let immediateRepeats: Int; let per100Words: Double }` with `DisfluencyStats.compute(raw: String) -> DisfluencyStats`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/LisperKitTests/SpeechPatternsTests.swift
import Testing
@testable import LisperKit

@Suite struct SpeechPatternsTests {
    @Test func detectsRepeatedMultiwordPhrase() {
        let raw = "you know what i mean it works you know what i mean and you know what i mean again"
        let phrases = RepeatedPhraseDetector.detect(raw: raw, minCount: 3, maxN: 4)
        #expect(phrases.contains { $0.phrase == "you know what i mean" && $0.count == 3 })
    }

    @Test func ignoresPhrasesBelowThreshold() {
        let raw = "a totally unique sentence with no repetition here at all today"
        #expect(RepeatedPhraseDetector.detect(raw: raw, minCount: 3, maxN: 4).isEmpty)
    }

    @Test func countsImmediateWordRepeats() {
        let raw = "i i think the the plan is good and we we should ship"
        let d = DisfluencyStats.compute(raw: raw)
        #expect(d.immediateRepeats == 3)               // "i i", "the the", "we we"
        #expect(d.per100Words > 0)
    }

    @Test func disfluencyEmptyIsZero() {
        let d = DisfluencyStats.compute(raw: "")
        #expect(d.immediateRepeats == 0)
        #expect(d.per100Words == 0)
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `swift run LisperKitTests`
Expected: FAIL — compile error, `RepeatedPhraseDetector` / `DisfluencyStats` are not defined.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/LisperKit/Stats/SpeechPatterns.swift
import Foundation

public struct RepeatedPhrase: Equatable, Sendable {
    public let phrase: String
    public let count: Int
    public init(phrase: String, count: Int) { self.phrase = phrase; self.count = count }
}

public enum RepeatedPhraseDetector {
    /// Lowercased word tokens, punctuation stripped. The single source of truth for
    /// "what is a word" stays `TranscriptStats.wordCount`; here we need the tokens
    /// themselves, tokenized the same way (whitespace/newline split) minus punctuation.
    static func tokens(_ raw: String) -> [String] {
        raw.lowercased()
            .split { $0.isWhitespace || $0.isNewline }
            .map { String($0.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
            .filter { !$0.isEmpty }
    }

    /// n-grams (2…maxN words) occurring at least `minCount` times, ranked by count
    /// then phrase length (longer, more-specific phrases first). Targets multi-word
    /// pet phrases ("you know what i mean"); single-word crutches are already covered
    /// by `TranscriptStats.fillerCounts`.
    public static func detect(raw: String, minCount: Int = 3, maxN: Int = 4) -> [RepeatedPhrase] {
        let words = tokens(raw)
        guard words.count >= 2 else { return [] }
        var counts: [String: Int] = [:]
        for n in 2...max(2, maxN) where words.count >= n {
            for i in 0...(words.count - n) {
                let gram = words[i..<(i + n)].joined(separator: " ")
                counts[gram, default: 0] += 1
            }
        }
        return counts
            .filter { $0.value >= minCount }
            .map { RepeatedPhrase(phrase: $0.key, count: $0.value) }
            .sorted { ($0.count, $0.phrase.count) > ($1.count, $1.phrase.count) }
    }
}

public struct DisfluencyStats: Equatable, Sendable {
    public let immediateRepeats: Int       // adjacent duplicate words: "the the", "i i"
    public let per100Words: Double
    public init(immediateRepeats: Int, per100Words: Double) {
        self.immediateRepeats = immediateRepeats; self.per100Words = per100Words
    }

    public static func compute(raw: String) -> DisfluencyStats {
        let words = RepeatedPhraseDetector.tokens(raw)
        guard words.count >= 2 else { return DisfluencyStats(immediateRepeats: 0, per100Words: 0) }
        var repeats = 0
        for i in 1..<words.count where words[i] == words[i - 1] { repeats += 1 }
        let per100 = Double(repeats) / Double(words.count) * 100
        return DisfluencyStats(immediateRepeats: repeats, per100Words: per100)
    }
}
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `swift run LisperKitTests`
Expected: PASS — all suites green (existing 157 + the 4 new tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LisperKit/Stats/SpeechPatterns.swift Tests/LisperKitTests/SpeechPatternsTests.swift
git commit -m "feat: repeated-phrase + disfluency metrics (raw-text, pure)"
```

---

### Task 2: Vocabulary diversity

**Files:**
- Create: `Sources/LisperKit/Stats/VocabularyStats.swift`
- Test: `Tests/LisperKitTests/VocabularyStatsTests.swift`

**Interfaces:**
- Consumes: `RepeatedPhrase` (Task 1), `RepeatedPhraseDetector.tokens` (internal), `FillerLexicon.defaults` (existing).
- Produces: `VocabularyStats { uniqueWords, totalWords: Int; typeTokenRatio: Double; leanedOnWords: [RepeatedPhrase] }` with `VocabularyStats.compute(raw: String) -> VocabularyStats`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/LisperKitTests/VocabularyStatsTests.swift
import Testing
@testable import LisperKit

@Suite struct VocabularyStatsTests {
    @Test func computesTypeTokenRatio() {
        let v = VocabularyStats.compute(raw: "cat dog cat dog bird")   // 5 tokens, 3 unique
        #expect(v.totalWords == 5)
        #expect(v.uniqueWords == 3)
        #expect(abs(v.typeTokenRatio - 0.6) < 0.0001)
    }

    @Test func leanedOnWordsExcludeStopwordsAndFillers() {
        let raw = "the project the project the project is basically basically great"
        let v = VocabularyStats.compute(raw: raw)
        // "the" (stopword) and "basically" (filler) are excluded; "project" leads.
        #expect(v.leanedOnWords.first?.phrase == "project")
        #expect(!v.leanedOnWords.contains { $0.phrase == "the" })
        #expect(!v.leanedOnWords.contains { $0.phrase == "basically" })
    }

    @Test func emptyIsZero() {
        let v = VocabularyStats.compute(raw: "")
        #expect(v.totalWords == 0 && v.uniqueWords == 0 && v.typeTokenRatio == 0)
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `swift run LisperKitTests`
Expected: FAIL — `VocabularyStats` not defined.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/LisperKit/Stats/VocabularyStats.swift
import Foundation

public struct VocabularyStats: Equatable, Sendable {
    public let uniqueWords: Int
    public let totalWords: Int
    public let typeTokenRatio: Double           // uniqueWords / totalWords
    public let leanedOnWords: [RepeatedPhrase]   // most-used content words, ranked
    public init(uniqueWords: Int, totalWords: Int, typeTokenRatio: Double, leanedOnWords: [RepeatedPhrase]) {
        self.uniqueWords = uniqueWords; self.totalWords = totalWords
        self.typeTokenRatio = typeTokenRatio; self.leanedOnWords = leanedOnWords
    }

    /// Common English function words excluded from "leaned-on" content words.
    static let stopwords: Set<String> = [
        "the","a","an","and","or","but","if","so","to","of","in","on","at","for","with","as","by",
        "is","am","are","was","were","be","been","being","it","its","this","that","these","those",
        "i","you","he","she","we","they","me","him","her","us","them","my","your","our","their",
        "do","does","did","have","has","had","will","would","can","could","should","not","no","yes",
        "just","really","very","then","there","here","what","which","who","when","where","how","why",
        "from","up","out","about","into","over","than","too","also","get","got","go","going"
    ]

    public static func compute(raw: String, extraFillers: [String] = []) -> VocabularyStats {
        let words = RepeatedPhraseDetector.tokens(raw)
        let total = words.count
        guard total > 0 else { return VocabularyStats(uniqueWords: 0, totalWords: 0, typeTokenRatio: 0, leanedOnWords: []) }
        let unique = Set(words).count
        let ttr = Double(unique) / Double(total)
        let excluded = stopwords
            .union(FillerLexicon.defaults.flatMap { $0.split(separator: " ").map(String.init) })
            .union(extraFillers.map { $0.lowercased() })
        var freq: [String: Int] = [:]
        for w in words where !excluded.contains(w) && w.count > 2 { freq[w, default: 0] += 1 }
        let leaned = freq
            .map { RepeatedPhrase(phrase: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.phrase) > ($1.count, $0.phrase) }
            .prefix(8)
        return VocabularyStats(uniqueWords: unique, totalWords: total, typeTokenRatio: ttr, leanedOnWords: Array(leaned))
    }
}
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `swift run LisperKitTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LisperKit/Stats/VocabularyStats.swift Tests/LisperKitTests/VocabularyStatsTests.swift
git commit -m "feat: vocabulary diversity metric (TTR + leaned-on content words)"
```

---

### Task 3: Coherence model + deterministic score

**Files:**
- Create: `Sources/LisperKit/Coach/CoherenceModels.swift`
- Test: `Tests/LisperKitTests/CoherenceScoreTests.swift`

**Interfaces:**
- Produces:
  - `CoherenceAnalysis` with nested `Point { summary, openedQuote: String; resolved: Bool; closedQuote: String? }`, `Restart { quote: String }`, `Transition { fromTopic, toTopic: String; signposted: Bool; quote: String }`, and `points/restarts/transitions` arrays. All `Codable, Equatable, Sendable`.
  - `CoherenceScore { pointsOpened, pointsClosed: Int; closureRate: Double; restartCount: Int; restartsPer100Words: Double; topicJumps: Int; jumpsPerMinute: Double }` with `CoherenceScore.from(_:wordCount:durationSeconds:) -> CoherenceScore`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/LisperKitTests/CoherenceScoreTests.swift
import Testing
@testable import LisperKit

@Suite struct CoherenceScoreTests {
    private func analysis() -> CoherenceAnalysis {
        CoherenceAnalysis(
            points: [
                .init(summary: "a", openedQuote: "first I want", resolved: true, closedQuote: "so that's done"),
                .init(summary: "b", openedQuote: "another thing", resolved: false, closedQuote: nil),
            ],
            restarts: [.init(quote: "actually no"), .init(quote: "wait let me")],
            transitions: [
                .init(fromTopic: "a", toTopic: "b", signposted: true, quote: "moving on"),
                .init(fromTopic: "b", toTopic: "c", signposted: false, quote: "oh and also"),
            ]
        )
    }

    @Test func derivesDeterministicScore() {
        let s = CoherenceScore.from(analysis(), wordCount: 200, durationSeconds: 120)
        #expect(s.pointsOpened == 2)
        #expect(s.pointsClosed == 1)
        #expect(abs(s.closureRate - 0.5) < 0.0001)
        #expect(s.restartCount == 2)
        #expect(abs(s.restartsPer100Words - 1.0) < 0.0001)   // 2 / 200 * 100
        #expect(s.topicJumps == 1)                            // one unsignposted transition
        #expect(abs(s.jumpsPerMinute - 0.5) < 0.0001)         // 1 / (120/60)
    }

    @Test func emptyAnalysisIsSafe() {
        let s = CoherenceScore.from(CoherenceAnalysis(points: [], restarts: [], transitions: []),
                                    wordCount: 0, durationSeconds: 0)
        #expect(s.closureRate == 1.0)     // nothing opened ⇒ nothing left dangling
        #expect(s.restartsPer100Words == 0 && s.jumpsPerMinute == 0)
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `swift run LisperKitTests`
Expected: FAIL — `CoherenceAnalysis` / `CoherenceScore` not defined.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/LisperKit/Coach/CoherenceModels.swift
import Foundation

public struct CoherenceAnalysis: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        public let summary: String
        public let openedQuote: String
        public let resolved: Bool
        public let closedQuote: String?
        public init(summary: String, openedQuote: String, resolved: Bool, closedQuote: String?) {
            self.summary = summary; self.openedQuote = openedQuote
            self.resolved = resolved; self.closedQuote = closedQuote
        }
    }
    public struct Restart: Codable, Equatable, Sendable {
        public let quote: String
        public init(quote: String) { self.quote = quote }
    }
    public struct Transition: Codable, Equatable, Sendable {
        public let fromTopic: String
        public let toTopic: String
        public let signposted: Bool
        public let quote: String
        public init(fromTopic: String, toTopic: String, signposted: Bool, quote: String) {
            self.fromTopic = fromTopic; self.toTopic = toTopic
            self.signposted = signposted; self.quote = quote
        }
    }
    public let points: [Point]
    public let restarts: [Restart]
    public let transitions: [Transition]
    public init(points: [Point], restarts: [Restart], transitions: [Transition]) {
        self.points = points; self.restarts = restarts; self.transitions = transitions
    }
}

public struct CoherenceScore: Codable, Equatable, Sendable {
    public let pointsOpened: Int
    public let pointsClosed: Int
    public let closureRate: Double            // closed / opened (1.0 when nothing opened)
    public let restartCount: Int
    public let restartsPer100Words: Double
    public let topicJumps: Int                // unsignposted transitions
    public let jumpsPerMinute: Double
    public init(pointsOpened: Int, pointsClosed: Int, closureRate: Double, restartCount: Int,
                restartsPer100Words: Double, topicJumps: Int, jumpsPerMinute: Double) {
        self.pointsOpened = pointsOpened; self.pointsClosed = pointsClosed; self.closureRate = closureRate
        self.restartCount = restartCount; self.restartsPer100Words = restartsPer100Words
        self.topicJumps = topicJumps; self.jumpsPerMinute = jumpsPerMinute
    }

    /// Pure: same analysis always yields the same score.
    public static func from(_ a: CoherenceAnalysis, wordCount: Int, durationSeconds: Double) -> CoherenceScore {
        let opened = a.points.count
        let closed = a.points.filter { $0.resolved }.count
        let closure = opened == 0 ? 1.0 : Double(closed) / Double(opened)
        let restarts = a.restarts.count
        let restartsPer100 = wordCount == 0 ? 0 : Double(restarts) / Double(wordCount) * 100
        let jumps = a.transitions.filter { !$0.signposted }.count
        let jpm = durationSeconds <= 0 ? 0 : Double(jumps) / (durationSeconds / 60)
        return CoherenceScore(pointsOpened: opened, pointsClosed: closed, closureRate: closure,
                              restartCount: restarts, restartsPer100Words: restartsPer100,
                              topicJumps: jumps, jumpsPerMinute: jpm)
    }
}
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `swift run LisperKitTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LisperKit/Coach/CoherenceModels.swift Tests/LisperKitTests/CoherenceScoreTests.swift
git commit -m "feat: coherence model + deterministic coherence score"
```

---

### Task 4: Flow Score

**Files:**
- Create: `Sources/LisperKit/Coach/FlowScore.swift`
- Test: `Tests/LisperKitTests/FlowScoreTests.swift`

**Interfaces:**
- Consumes: `TranscriptStats` (existing), `DisfluencyStats` (Task 1), `CoherenceScore` (Task 3).
- Produces: `FlowScore { overall, fillerFree, continuity, singleThread, sustain: Int; isComplete: Bool }` with `FlowScore.compute(stats:disfluency:coherence:durationSeconds:) -> FlowScore`. `singleThread == -1` sentinel means "unavailable" (shown as "—").

- [ ] **Step 1: Write the failing test**

```swift
// Tests/LisperKitTests/FlowScoreTests.swift
import Testing
@testable import LisperKit

@Suite struct FlowScoreTests {
    private func stats(words: Int, fillers: Int, wpm: Double) -> TranscriptStats {
        TranscriptStats(wordCount: words, fillerCounts: fillers > 0 ? ["um": fillers] : [:], wordsPerMinute: wpm)
    }

    @Test func cleanSustainedFlowApproaches100() {
        let s = stats(words: 150, fillers: 0, wpm: 150)
        let c = CoherenceScore(pointsOpened: 2, pointsClosed: 2, closureRate: 1, restartCount: 0,
                               restartsPer100Words: 0, topicJumps: 0, jumpsPerMinute: 0)
        let f = FlowScore.compute(stats: s, disfluency: DisfluencyStats(immediateRepeats: 0, per100Words: 0),
                                  coherence: c, durationSeconds: 60)
        #expect(f.isComplete)
        #expect(f.overall >= 90)
        #expect(f.fillerFree == 100 && f.continuity == 100 && f.singleThread == 100)
    }

    @Test func ramblyFillerHeavyScoresLow() {
        let s = stats(words: 150, fillers: 20, wpm: 150)
        let c = CoherenceScore(pointsOpened: 5, pointsClosed: 1, closureRate: 0.2, restartCount: 9,
                               restartsPer100Words: 6, topicJumps: 5, jumpsPerMinute: 5)
        let f = FlowScore.compute(stats: s, disfluency: DisfluencyStats(immediateRepeats: 6, per100Words: 4),
                                  coherence: c, durationSeconds: 60)
        #expect(f.isComplete)
        #expect(f.overall <= 45)
    }

    @Test func degradedWhenNoCoherence() {
        let s = stats(words: 100, fillers: 2, wpm: 150)
        let f = FlowScore.compute(stats: s, disfluency: DisfluencyStats(immediateRepeats: 1, per100Words: 1),
                                  coherence: nil, durationSeconds: 60)
        #expect(!f.isComplete)
        #expect(f.singleThread == -1)         // unavailable, not faked
        #expect(f.overall > 0)                 // still computed from available components
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `swift run LisperKitTests`
Expected: FAIL — `FlowScore` not defined.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/LisperKit/Coach/FlowScore.swift
import Foundation

/// The 60-second-flow challenge as a number: filler-free + uninterrupted +
/// single-thread + sustained. Pure & deterministic. `singleThread == -1` ⇒
/// unavailable (no coherence). Component ceilings are the v1 calibration point.
public struct FlowScore: Codable, Equatable, Sendable {
    public let overall: Int
    public let fillerFree: Int
    public let continuity: Int
    public let singleThread: Int   // -1 ⇒ unavailable
    public let sustain: Int
    public let isComplete: Bool
    public init(overall: Int, fillerFree: Int, continuity: Int, singleThread: Int, sustain: Int, isComplete: Bool) {
        self.overall = overall; self.fillerFree = fillerFree; self.continuity = continuity
        self.singleThread = singleThread; self.sustain = sustain; self.isComplete = isComplete
    }

    private static let fillerCeiling = 12.0       // fillers/100w at which fillerFree hits 0
    private static let restartCeiling = 6.0       // restarts/100w at which continuity hits 0
    private static let disfluencyCeiling = 8.0    // immediate-repeats/100w proxy ceiling
    private static let jumpCeiling = 4.0          // unsignposted jumps/min at which thread hits 0
    private static let sustainTarget = 60.0       // seconds for full sustain credit

    private static func score(_ value: Double, ceiling: Double) -> Int {
        let pct = 100.0 - min(value, ceiling) / ceiling * 100.0
        return Int(max(0, min(100, pct.rounded())))
    }

    public static func compute(stats: TranscriptStats, disfluency: DisfluencyStats,
                               coherence: CoherenceScore?, durationSeconds: Double) -> FlowScore {
        let fillerFree = score(stats.fillersPer100Words, ceiling: fillerCeiling)
        let sustain = Int(max(0, min(100, (durationSeconds / sustainTarget * 100).rounded())))

        if let c = coherence {
            let continuity = score(c.restartsPer100Words, ceiling: restartCeiling)
            // single-thread blends "did you finish what you opened" with "did you avoid drift".
            let closure = Int(max(0, min(100, (c.closureRate * 100).rounded())))
            let drift = score(c.jumpsPerMinute, ceiling: jumpCeiling)
            let singleThread = Int((Double(closure) * 0.6 + Double(drift) * 0.4).rounded())
            let overall = Int((Double(fillerFree) * 0.30 + Double(continuity) * 0.25
                               + Double(singleThread) * 0.30 + Double(sustain) * 0.15).rounded())
            return FlowScore(overall: overall, fillerFree: fillerFree, continuity: continuity,
                             singleThread: singleThread, sustain: sustain, isComplete: true)
        } else {
            // Degraded: continuity from a disfluency proxy; single-thread unavailable.
            let continuity = score(disfluency.per100Words, ceiling: disfluencyCeiling)
            let overall = Int((Double(fillerFree) * 0.45 + Double(continuity) * 0.35
                               + Double(sustain) * 0.20).rounded())
            return FlowScore(overall: overall, fillerFree: fillerFree, continuity: continuity,
                             singleThread: -1, sustain: sustain, isComplete: false)
        }
    }
}
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `swift run LisperKitTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LisperKit/Coach/FlowScore.swift Tests/LisperKitTests/FlowScoreTests.swift
git commit -m "feat: Flow Score (deterministic 60s-flow composite, graceful degraded path)"
```

---

### Task 5: Coherence analyzer (LLM extraction) + ChatCompleting seam

**Files:**
- Create: `Sources/LisperKit/Coach/CoherenceAnalyzer.swift`
- Modify: `Sources/LisperKit/Engines/GroqClient.swift` (add params + conform)
- Test: `Tests/LisperKitTests/CoherenceParseTests.swift`

**Interfaces:**
- Produces:
  - `protocol ChatCompleting: Sendable { func chat(system:user:model:maxTokens:temperature:jsonObject:) async throws -> String }`; `extension GroqClient: ChatCompleting {}`.
  - `protocol CoherenceAnalyzer: Sendable { func analyze(rawTranscript:durationSeconds:) async throws -> CoherenceAnalysis }`.
  - `LLMCoherenceAnalyzer(chat: ChatCompleting, model: String)`.
  - internal `parseCoherence(_ s: String) -> CoherenceAnalysis?` and `CoherencePrompt`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/LisperKitTests/CoherenceParseTests.swift
import Testing
@testable import LisperKit

@Suite struct CoherenceParseTests {
    @Test func parsesWellFormedJSON() {
        let json = """
        {"points":[{"summary":"plan","openedQuote":"first the plan","resolved":true,"closedQuote":"done"}],
         "restarts":[{"quote":"actually no"}],
         "transitions":[{"fromTopic":"plan","toTopic":"budget","signposted":false,"quote":"oh budget"}]}
        """
        let a = parseCoherence(json)
        #expect(a?.points.count == 1)
        #expect(a?.points.first?.resolved == true)
        #expect(a?.restarts.count == 1)
        #expect(a?.transitions.first?.signposted == false)
    }

    @Test func recoversJSONWrappedInProse() {
        let s = "Here is the analysis:\n{\"points\":[],\"restarts\":[],\"transitions\":[]}\nThanks!"
        #expect(parseCoherence(s) != nil)
    }

    @Test func missingArraysDefaultToEmpty() {
        let a = parseCoherence("{\"points\":[{\"summary\":\"x\",\"openedQuote\":\"x\",\"resolved\":false}]}")
        #expect(a?.points.count == 1)
        #expect(a?.restarts.isEmpty == true)
        #expect(a?.transitions.isEmpty == true)
    }

    @Test func nonJSONReturnsNil() {
        #expect(parseCoherence("the model refused to answer") == nil)
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `swift run LisperKitTests`
Expected: FAIL — `parseCoherence` not defined.

- [ ] **Step 3: Modify `GroqClient.chat` (additive) and add the conformance**

In `Sources/LisperKit/Engines/GroqClient.swift`, replace the `chat` signature and payload (lines 81–98) with:

```swift
    public func chat(system: String, user: String, model: String, maxTokens: Int = 4096,
                     temperature: Double = 0.2, jsonObject: Bool = false) async throws -> String {
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw EngineError.network("bad base URL")
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [
            "model": model,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if jsonObject { payload["response_format"] = ["type": "json_object"] }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
```

(The rest of `chat` — the `send`/decode — is unchanged. Existing callers `WeeklyTipGenerator` and `LLMCleanupEngine` keep compiling because the new params are defaulted.)

- [ ] **Step 4: Write the analyzer + parser**

```swift
// Sources/LisperKit/Coach/CoherenceAnalyzer.swift
import Foundation

public protocol ChatCompleting: Sendable {
    func chat(system: String, user: String, model: String,
              maxTokens: Int, temperature: Double, jsonObject: Bool) async throws -> String
}

extension GroqClient: ChatCompleting {}   // signature matches the new chat(...)

public protocol CoherenceAnalyzer: Sendable {
    func analyze(rawTranscript: String, durationSeconds: Double) async throws -> CoherenceAnalysis
}

public enum CoherencePrompt {
    public static let system = """
    You analyze a single raw, unedited dictation transcript of one person thinking out loud.
    Return ONLY a JSON object with this exact shape:
    {"points":[{"summary":string,"openedQuote":string,"resolved":bool,"closedQuote":string|null}],
     "restarts":[{"quote":string}],
     "transitions":[{"fromTopic":string,"toTopic":string,"signposted":bool,"quote":string}]}
    Rules:
    - "points" = distinct ideas the speaker STARTS to make. resolved=true only if they actually
      conclude it; closedQuote is the verbatim words where they close it (else null).
    - "restarts" = self-corrections / false starts ("actually no", "wait let me").
    - "transitions" = topic switches; signposted=true if explicitly marked ("moving on to…").
    - EVERY quote field MUST be copied verbatim from the transcript. Never invent text.
      If you cannot find a real quote, omit that item. Output JSON only, no prose.
    """
    public static func user(_ raw: String) -> String {
        "Transcript:\n\"\"\"\n\(raw)\n\"\"\""
    }
}

public struct LLMCoherenceAnalyzer: CoherenceAnalyzer {
    let chat: ChatCompleting
    let model: String
    public init(chat: ChatCompleting, model: String) { self.chat = chat; self.model = model }

    public func analyze(rawTranscript: String, durationSeconds: Double) async throws -> CoherenceAnalysis {
        let raw = try await chat.chat(system: CoherencePrompt.system,
                                      user: CoherencePrompt.user(rawTranscript),
                                      model: model, maxTokens: 1500, temperature: 0, jsonObject: true)
        guard let analysis = parseCoherence(raw) else {
            throw EngineError.badResponse(0, "coherence: unparseable response")
        }
        return analysis
    }
}

/// Tolerant parse: strips any prose around the JSON object, defaults missing
/// arrays to empty, never throws. Returns nil only when no JSON object is present.
func parseCoherence(_ s: String) -> CoherenceAnalysis? {
    guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end else { return nil }
    let slice = String(s[start...end])
    guard let data = slice.data(using: .utf8) else { return nil }

    struct Wire: Decodable {
        struct P: Decodable { let summary: String?; let openedQuote: String?; let resolved: Bool?; let closedQuote: String? }
        struct R: Decodable { let quote: String? }
        struct T: Decodable { let fromTopic: String?; let toTopic: String?; let signposted: Bool?; let quote: String? }
        let points: [P]?; let restarts: [R]?; let transitions: [T]?
    }
    guard let w = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
    let points = (w.points ?? []).compactMap { p -> CoherenceAnalysis.Point? in
        guard let q = p.openedQuote, !q.isEmpty else { return nil }
        return .init(summary: p.summary ?? "", openedQuote: q, resolved: p.resolved ?? false, closedQuote: p.closedQuote)
    }
    let restarts = (w.restarts ?? []).compactMap { $0.quote.flatMap { $0.isEmpty ? nil : CoherenceAnalysis.Restart(quote: $0) } }
    let transitions = (w.transitions ?? []).compactMap { t -> CoherenceAnalysis.Transition? in
        guard let q = t.quote, !q.isEmpty else { return nil }
        return .init(fromTopic: t.fromTopic ?? "", toTopic: t.toTopic ?? "", signposted: t.signposted ?? true, quote: q)
    }
    return CoherenceAnalysis(points: points, restarts: restarts, transitions: transitions)
}
```

- [ ] **Step 5: Run the suite to verify it passes**

Run: `swift run LisperKitTests`
Expected: PASS — including the 4 new parse tests; existing GroqClient callers still compile.

- [ ] **Step 6: Commit**

```bash
git add Sources/LisperKit/Coach/CoherenceAnalyzer.swift Sources/LisperKit/Engines/GroqClient.swift Tests/LisperKitTests/CoherenceParseTests.swift
git commit -m "feat: LLM coherence analyzer with evidence-anchored, tolerant JSON parse"
```

---

### Task 6: Persistence — analysis + daily-insight records, migration, queries

**Files:**
- Create: `Sources/LisperKit/Store/SessionAnalysis.swift`, `Sources/LisperKit/Store/DailyInsight.swift`
- Modify: `Sources/LisperKit/Store/LisperDatabase.swift`
- Test: `Tests/LisperKitTests/CoachPersistenceTests.swift`

**Interfaces:**
- Produces:
  - `SessionAnalysis { sessionId: Int64; coherenceJSON: String; flowOverall: Int; flowJSON: String; modelUsed: String; generatedAt: Date }` (GRDB record, table `session_analyses`).
  - `DailyInsight { day: String; digestMarkdown: String; metricsJSON: String; generatedAt: Date; modelUsed: String }` (GRDB record, table `daily_insights`).
  - `LisperDatabase` methods: `saveAnalysis(_:)`, `analysis(forSession:)`, `recentAnalyses(limit:)`, `sessionsMissingAnalysis(limit:)`, `saveDailyInsight(_:)`, `dailyInsight(day:)`, `dailyInsights(since:)`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/LisperKitTests/CoachPersistenceTests.swift
import Testing
import GRDB
@testable import LisperKit

@Suite struct CoachPersistenceTests {
    private func db() throws -> LisperDatabase { try LisperDatabase(queue: DatabaseQueue()) }

    private func session(words: Int) -> SessionRecord {
        SessionRecord(id: nil, startedAt: Date(), durationSeconds: 60, appBundleID: "x", appName: "X",
                      rawTranscript: String(repeating: "word ", count: words), cleanedText: "c",
                      wordCount: words, fillerCount: 0, fillersJSON: [:], wpm: 100,
                      engineUsed: "groq", cleanupUsed: "llm", inserted: true)
    }

    @Test func analysisRoundTrips() throws {
        let d = try db()
        let saved = try d.save(session: session(words: 50))
        let a = SessionAnalysis(sessionId: saved.id!, coherenceJSON: "{}", flowOverall: 72,
                                flowJSON: "{}", modelUsed: "m", generatedAt: Date())
        try d.saveAnalysis(a)
        #expect(try d.analysis(forSession: saved.id!)?.flowOverall == 72)
    }

    @Test func missingAnalysisQueryExcludesAnalyzed() throws {
        let d = try db()
        let s1 = try d.save(session: session(words: 50))
        let s2 = try d.save(session: session(words: 50))
        try d.saveAnalysis(SessionAnalysis(sessionId: s1.id!, coherenceJSON: "{}", flowOverall: 1,
                                           flowJSON: "{}", modelUsed: "m", generatedAt: Date()))
        let pending = try d.sessionsMissingAnalysis(limit: 10)
        #expect(pending.map { $0.id } == [s2.id])
    }

    @Test func dailyInsightRoundTrips() throws {
        let d = try db()
        try d.saveDailyInsight(DailyInsight(day: "2026-06-29", digestMarkdown: "hi", metricsJSON: "{}",
                                            generatedAt: Date(), modelUsed: "m"))
        #expect(try d.dailyInsight(day: "2026-06-29")?.digestMarkdown == "hi")
        #expect(try d.dailyInsights(since: "2026-06-01").count == 1)
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `swift run LisperKitTests`
Expected: FAIL — `SessionAnalysis` / methods not defined.

- [ ] **Step 3: Create the records**

```swift
// Sources/LisperKit/Store/SessionAnalysis.swift
import Foundation
import GRDB

public struct SessionAnalysis: Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "session_analyses"
    public var sessionId: Int64
    public var coherenceJSON: String
    public var flowOverall: Int
    public var flowJSON: String
    public var modelUsed: String
    public var generatedAt: Date
    public init(sessionId: Int64, coherenceJSON: String, flowOverall: Int,
                flowJSON: String, modelUsed: String, generatedAt: Date) {
        self.sessionId = sessionId; self.coherenceJSON = coherenceJSON; self.flowOverall = flowOverall
        self.flowJSON = flowJSON; self.modelUsed = modelUsed; self.generatedAt = generatedAt
    }
}
```

```swift
// Sources/LisperKit/Store/DailyInsight.swift
import Foundation
import GRDB

public struct DailyInsight: Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "daily_insights"
    public var day: String              // "YYYY-MM-DD", local Gregorian
    public var digestMarkdown: String
    public var metricsJSON: String
    public var generatedAt: Date
    public var modelUsed: String
    public init(day: String, digestMarkdown: String, metricsJSON: String, generatedAt: Date, modelUsed: String) {
        self.day = day; self.digestMarkdown = digestMarkdown; self.metricsJSON = metricsJSON
        self.generatedAt = generatedAt; self.modelUsed = modelUsed
    }
}
```

- [ ] **Step 4: Add the `v2` migration**

In `Sources/LisperKit/Store/LisperDatabase.swift`, inside `migrate()`, AFTER the existing `migrator.registerMigration("v1") { ... }` block and BEFORE `try migrator.migrate(queue)`, add:

```swift
        migrator.registerMigration("v2") { db in
            try db.create(table: "session_analyses") { t in
                t.primaryKey("sessionId", .integer)
                t.column("coherenceJSON", .text).notNull()
                t.column("flowOverall", .integer).notNull()
                t.column("flowJSON", .text).notNull()
                t.column("modelUsed", .text).notNull()
                t.column("generatedAt", .datetime).notNull()
            }
            try db.create(table: "daily_insights") { t in
                t.primaryKey("day", .text)
                t.column("digestMarkdown", .text).notNull()
                t.column("metricsJSON", .text).notNull()
                t.column("generatedAt", .datetime).notNull()
                t.column("modelUsed", .text).notNull()
            }
        }
```

- [ ] **Step 5: Add the query methods**

In `LisperDatabase`, after `tip(weekStart:)` (the last method), add:

```swift
    public func saveAnalysis(_ a: SessionAnalysis) throws {
        try queue.write { try a.save($0) }
    }
    public func analysis(forSession id: Int64) throws -> SessionAnalysis? {
        try queue.read { try SessionAnalysis.fetchOne($0, key: id) }
    }
    public func recentAnalyses(limit: Int) throws -> [SessionAnalysis] {
        try queue.read { try SessionAnalysis.order(Column("generatedAt").desc).limit(limit).fetchAll($0) }
    }
    public func sessionsMissingAnalysis(limit: Int) throws -> [SessionRecord] {
        try queue.read {
            try SessionRecord.fetchAll($0, sql: """
                SELECT * FROM sessions
                WHERE id NOT IN (SELECT sessionId FROM session_analyses)
                ORDER BY startedAt DESC LIMIT ?
                """, arguments: [limit])
        }
    }
    public func saveDailyInsight(_ d: DailyInsight) throws {
        try queue.write { try d.save($0) }
    }
    public func dailyInsight(day: String) throws -> DailyInsight? {
        try queue.read { try DailyInsight.fetchOne($0, key: day) }
    }
    public func dailyInsights(since: String) throws -> [DailyInsight] {
        try queue.read {
            try DailyInsight.filter(Column("day") >= since).order(Column("day").asc).fetchAll($0)
        }
    }
```

- [ ] **Step 6: Run the suite to verify it passes**

Run: `swift run LisperKitTests`
Expected: PASS — including existing `DatabaseTests` (migration is additive; v1 data untouched).

- [ ] **Step 7: Commit**

```bash
git add Sources/LisperKit/Store/SessionAnalysis.swift Sources/LisperKit/Store/DailyInsight.swift Sources/LisperKit/Store/LisperDatabase.swift Tests/LisperKitTests/CoachPersistenceTests.swift
git commit -m "feat: persist session analyses + daily insights (additive v2 migration)"
```

---

### Task 7: The science Playbook (model, parse, selection, seed corpus, bundling)

**Files:**
- Create: `Sources/LisperKit/Coach/Playbook.swift`, `Sources/LisperKit/Coach/Playbook/playbook.json`
- Modify: `Package.swift`
- Test: `Tests/LisperKitTests/PlaybookTests.swift`

**Interfaces:**
- Produces: `PlaybookCategory` (`filler|pace|vocabulary|coherence`), `PlaybookEntry { id, technique, evidence, howTo: String; category }`, `Playbook { entries: [PlaybookEntry]; parse(json:); entries(for:); loadBundled() }`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/LisperKitTests/PlaybookTests.swift
import Testing
@testable import LisperKit

@Suite struct PlaybookTests {
    @Test func parsesAndSelectsByCategory() {
        let json = """
        [{"id":"f1","category":"filler","technique":"pause","evidence":"Azrin & Nunn 1973","howTo":"breathe"},
         {"id":"c1","category":"coherence","technique":"PREP","evidence":"public-speaking framework","howTo":"point first"}]
        """.data(using: .utf8)!
        let pb = Playbook.parse(json: json)!
        #expect(pb.entries.count == 2)
        let filler = pb.entries(for: [.filler])
        #expect(filler.count == 1 && filler.first?.id == "f1")
    }

    @Test func bundledPlaybookLoadsAndIsCited() {
        let pb = Playbook.loadBundled()
        #expect(!pb.entries.isEmpty)
        #expect(pb.entries.allSatisfy { !$0.evidence.trimmingCharacters(in: .whitespaces).isEmpty })
        #expect(PlaybookCategory.allCases.allSatisfy { cat in pb.entries.contains { $0.category == cat } })
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `swift run LisperKitTests`
Expected: FAIL — `Playbook` not defined.

- [ ] **Step 3: Create the model**

```swift
// Sources/LisperKit/Coach/Playbook.swift
import Foundation

public enum PlaybookCategory: String, Codable, Sendable, CaseIterable {
    case filler, pace, vocabulary, coherence
}

public struct PlaybookEntry: Codable, Equatable, Sendable {
    public let id: String
    public let category: PlaybookCategory
    public let technique: String
    public let evidence: String     // citation / source — never empty
    public let howTo: String
    public init(id: String, category: PlaybookCategory, technique: String, evidence: String, howTo: String) {
        self.id = id; self.category = category; self.technique = technique
        self.evidence = evidence; self.howTo = howTo
    }
}

public struct Playbook: Equatable, Sendable {
    public let entries: [PlaybookEntry]
    public init(entries: [PlaybookEntry]) { self.entries = entries }

    public static func parse(json: Data) -> Playbook? {
        guard let entries = try? JSONDecoder().decode([PlaybookEntry].self, from: json) else { return nil }
        return Playbook(entries: entries)
    }

    public func entries(for categories: [PlaybookCategory]) -> [PlaybookEntry] {
        entries.filter { categories.contains($0.category) }
    }

    public static func loadBundled() -> Playbook {
        guard let url = Bundle.module.url(forResource: "playbook", withExtension: "json"),
              let data = try? Data(contentsOf: url), let pb = parse(json: data) else {
            return Playbook(entries: [])
        }
        return pb
    }
}
```

- [ ] **Step 4: Create the seed corpus** (`Sources/LisperKit/Coach/Playbook/playbook.json`)

```json
[
  {"id":"filler-pause","category":"filler","technique":"Replace fillers with a silent pause (habit reversal: awareness + a competing response).","evidence":"Azrin & Nunn (1973), Behaviour Research and Therapy — habit-reversal eliminates nervous verbal habits by substituting a competing response.","howTo":"When you feel an 'um' coming, close your mouth and pause for one beat instead. The pause buys the same thinking time without the filler."},
  {"id":"filler-floor","category":"filler","technique":"Slow down — fillers are floor-holders while you think.","evidence":"Clark & Fox Tree (2002), Cognition — 'uh'/'um' are signals speakers use to manage planning time.","howTo":"Lower your pace slightly so you finish planning a clause before you start saying it; the urge to fill silence drops."},
  {"id":"pace-rate","category":"pace","technique":"Aim for a conversational ~140–160 words/min; slow on key points.","evidence":"National Center for Voice and Speech — typical conversational rate ~150 wpm; comprehension drops when rate runs high.","howTo":"If your WPM trend is above ~170, deliberately slow your most important sentence and pause after it."},
  {"id":"pace-pause-power","category":"pace","technique":"Use deliberate pauses to mark structure.","evidence":"Public-speaking practice (e.g., Toastmasters) — strategic pauses aid retention and signal transitions.","howTo":"Pause for ~1s between your distinct points so the listener (and you) feel the boundary."},
  {"id":"vocab-spacing","category":"vocabulary","technique":"Consolidate new words with spaced, deliberate reuse.","evidence":"Cepeda et al. (2006), Psychological Bulletin — distributed practice (the spacing effect) strongly improves retention.","howTo":"Pick one new word and deliberately use it 2–3 times across the next few days in real context."},
  {"id":"vocab-leaned","category":"vocabulary","technique":"Diversify the words you lean on.","evidence":"Lexical-diversity research — higher type-token ratio correlates with perceived sophistication.","howTo":"Notice your top leaned-on words and swap one for a sharper synonym next time you reach for it."},
  {"id":"coherence-signpost","category":"coherence","technique":"Signpost transitions ('first… next… finally').","evidence":"Discourse-marker research on coherence — explicit markers help listeners track structure.","howTo":"Before switching topics, say the transition out loud: 'moving on to…'. It also forces you to notice the switch."},
  {"id":"coherence-prep","category":"coherence","technique":"PREP — Point, Reason, Example, Point.","evidence":"Established public-speaking framework for finishing what you open.","howTo":"State your point first, support it, then RETURN to it. Closing the loop is what 'finishing your point' means."}
]
```

- [ ] **Step 5: Bundle the resource** — in `Package.swift`, change the `LisperKit` target (lines 28–32) to:

```swift
        .target(
            name: "LisperKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            resources: [.process("Coach/Playbook")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
```

- [ ] **Step 6: Run the suite to verify it passes**

Run: `swift run LisperKitTests`
Expected: PASS — `bundledPlaybookLoads` confirms `Bundle.module` resolves the JSON.

- [ ] **Step 7: Commit**

```bash
git add Sources/LisperKit/Coach/Playbook.swift Sources/LisperKit/Coach/Playbook/playbook.json Package.swift Tests/LisperKitTests/PlaybookTests.swift
git commit -m "feat: cited science Playbook (model + seed corpus + bundling)"
```

---

### Task 8: CoachAnalysisService (gate → analyze → score → persist)

**Files:**
- Create: `Sources/LisperKit/Coach/CoachAnalysisService.swift`
- Test: `Tests/LisperKitTests/CoachAnalysisServiceTests.swift`

**Interfaces:**
- Consumes: `CoherenceAnalyzer` (Task 5), `CoherenceScore` (3), `FlowScore` (4), `DisfluencyStats` (1), `TranscriptStats` (existing), persistence (6).
- Produces: `CoachAnalysisService(analyzer: CoherenceAnalyzer, modelName: String, minWords: Int = 40)` with `@discardableResult analyzeIfNeeded(session:db:) async -> SessionAnalysis?` and `analyzePending(db:limit:) async`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/LisperKitTests/CoachAnalysisServiceTests.swift
import Testing
import GRDB
@testable import LisperKit

private struct StubAnalyzer: CoherenceAnalyzer {
    let result: CoherenceAnalysis
    func analyze(rawTranscript: String, durationSeconds: Double) async throws -> CoherenceAnalysis { result }
}

@Suite struct CoachAnalysisServiceTests {
    private func db() throws -> LisperDatabase { try LisperDatabase(queue: DatabaseQueue()) }
    private func session(words: Int) -> SessionRecord {
        SessionRecord(id: nil, startedAt: Date(), durationSeconds: 60, appBundleID: "x", appName: "X",
                      rawTranscript: (Array(repeating: "idea", count: words)).joined(separator: " "),
                      cleanedText: "c", wordCount: words, fillerCount: 0, fillersJSON: [:], wpm: 100,
                      engineUsed: "groq", cleanupUsed: "llm", inserted: true)
    }
    private func service() -> CoachAnalysisService {
        CoachAnalysisService(analyzer: StubAnalyzer(result: CoherenceAnalysis(points: [], restarts: [], transitions: [])),
                             modelName: "test-model", minWords: 40)
    }

    @Test func analyzesQualifyingSessionOnce() async throws {
        let d = try db(); let s = try d.save(session: session(words: 50))
        let a = await service().analyzeIfNeeded(session: s, db: d)
        #expect(a != nil)
        #expect(try d.analysis(forSession: s.id!) != nil)
        // idempotent
        #expect(await service().analyzeIfNeeded(session: s, db: d) == nil)
    }

    @Test func skipsShortSession() async throws {
        let d = try db(); let s = try d.save(session: session(words: 10))
        #expect(await service().analyzeIfNeeded(session: s, db: d) == nil)
        #expect(try d.analysis(forSession: s.id!) == nil)
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `swift run LisperKitTests`
Expected: FAIL — `CoachAnalysisService` not defined.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/LisperKit/Coach/CoachAnalysisService.swift
import Foundation

/// Orchestrates per-session coherence analysis: gate (min words) → idempotency
/// (skip if already analyzed) → extract → deterministic Flow Score → persist.
public struct CoachAnalysisService: Sendable {
    let analyzer: CoherenceAnalyzer
    let modelName: String
    let minWords: Int
    public init(analyzer: CoherenceAnalyzer, modelName: String, minWords: Int = 40) {
        self.analyzer = analyzer; self.modelName = modelName; self.minWords = minWords
    }

    private static func json<T: Encodable>(_ v: T) -> String {
        (try? JSONEncoder().encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    @discardableResult
    public func analyzeIfNeeded(session: SessionRecord, db: LisperDatabase) async -> SessionAnalysis? {
        guard let id = session.id else { return nil }
        guard session.wordCount >= minWords else { return nil }
        if (try? db.analysis(forSession: id)) != nil { return nil }          // idempotent
        guard let analysis = try? await analyzer.analyze(rawTranscript: session.rawTranscript,
                                                         durationSeconds: session.durationSeconds) else { return nil }
        let cscore = CoherenceScore.from(analysis, wordCount: session.wordCount, durationSeconds: session.durationSeconds)
        let stats = TranscriptStats.compute(raw: session.rawTranscript, durationSeconds: session.durationSeconds, customFillers: [])
        let dis = DisfluencyStats.compute(raw: session.rawTranscript)
        let flow = FlowScore.compute(stats: stats, disfluency: dis, coherence: cscore, durationSeconds: session.durationSeconds)
        let rec = SessionAnalysis(sessionId: id, coherenceJSON: Self.json(analysis),
                                  flowOverall: flow.overall, flowJSON: Self.json(flow),
                                  modelUsed: modelName, generatedAt: Date())
        try? db.saveAnalysis(rec)
        return rec
    }

    /// Catch-up pass for sessions saved while analysis was off/offline.
    public func analyzePending(db: LisperDatabase, limit: Int = 10) async {
        let pending = (try? db.sessionsMissingAnalysis(limit: limit)) ?? []
        for s in pending { _ = await analyzeIfNeeded(session: s, db: db) }
    }
}
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `swift run LisperKitTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LisperKit/Coach/CoachAnalysisService.swift Tests/LisperKitTests/CoachAnalysisServiceTests.swift
git commit -m "feat: CoachAnalysisService — gated, idempotent per-session analysis + Flow scoring"
```

---

### Task 9: DailyDigestGenerator (rollup → grounded note → cache)

**Files:**
- Create: `Sources/LisperKit/Coach/DailyDigestGenerator.swift`
- Test: `Tests/LisperKitTests/DailyDigestTests.swift`

**Interfaces:**
- Consumes: `ChatCompleting` (5), `Playbook` (7), persistence (6), metrics (1,2), `SessionAnalysis`/`FlowScore`.
- Produces:
  - `DayMetrics` (Codable) snapshot.
  - `DailyDigestGenerator(chat: ChatCompleting, model: String, playbook: Playbook)` with `digest(db:day:calendar:locale:) async throws -> DailyInsight`, and static helpers `dayKey(_:calendar:locale:)`, `dayMetrics(db:day:calendar:)`, `problems(from:)`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/LisperKitTests/DailyDigestTests.swift
import Testing
import GRDB
@testable import LisperKit

private struct StubChat: ChatCompleting {
    let reply: String
    func chat(system: String, user: String, model: String, maxTokens: Int,
              temperature: Double, jsonObject: Bool) async throws -> String { reply }
}

@Suite struct DailyDigestTests {
    private func db() throws -> LisperDatabase { try LisperDatabase(queue: DatabaseQueue()) }
    private func session(words: Int, at: Date) -> SessionRecord {
        SessionRecord(id: nil, startedAt: at, durationSeconds: 60, appBundleID: "x", appName: "X",
                      rawTranscript: Array(repeating: "the plan is good", count: words / 4).joined(separator: " "),
                      cleanedText: "c", wordCount: words, fillerCount: 0, fillersJSON: [:], wpm: 100,
                      engineUsed: "groq", cleanupUsed: "llm", inserted: true)
    }
    private func gen(_ reply: String) -> DailyDigestGenerator {
        DailyDigestGenerator(chat: StubChat(reply: reply), model: "m",
                             playbook: Playbook(entries: [PlaybookEntry(id: "f", category: .filler,
                                 technique: "pause", evidence: "Azrin & Nunn 1973", howTo: "breathe")]))
    }

    @Test func generatesAndCachesDigest() async throws {
        let d = try db()
        _ = try d.save(session: session(words: 100, at: Date()))
        let insight = try await gen("Today you spoke clearly.").digest(db: d, day: Date())
        #expect(insight.digestMarkdown == "Today you spoke clearly.")
        // cached: second call returns the stored row (would differ if regenerated).
        let again = try await gen("DIFFERENT").digest(db: d, day: Date())
        #expect(again.digestMarkdown == "Today you spoke clearly.")
    }

    @Test func gatesOnMinimumSpeech() async throws {
        let d = try db()
        _ = try d.save(session: session(words: 8, at: Date()))
        await #expect(throws: EngineError.self) { _ = try await self.gen("x").digest(db: d, day: Date()) }
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `swift run LisperKitTests`
Expected: FAIL — `DailyDigestGenerator` not defined.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/LisperKit/Coach/DailyDigestGenerator.swift
import Foundation

public struct DayMetrics: Codable, Equatable, Sendable {
    public let day: String
    public let sessionCount: Int
    public let totalWords: Int
    public let fillersPer100Words: Double
    public let avgWPM: Double
    public let avgFlow: Double
    public let avgClosureRate: Double
    public let restartsPer100Words: Double
    public let vocabularyDiversity: Double
    public let topRepeatedPhrases: [String]
    public let leanedOnWords: [String]
}

public struct DailyDigestGenerator: Sendable {
    let chat: ChatCompleting
    let model: String
    let playbook: Playbook
    public init(chat: ChatCompleting, model: String, playbook: Playbook) {
        self.chat = chat; self.model = model; self.playbook = playbook
    }

    static let gregorian = Calendar(identifier: .gregorian)
    static let enUS = Locale(identifier: "en_US")

    public static func dayKey(_ date: Date, calendar: Calendar = gregorian, locale: Locale = enUS) -> String {
        let f = DateFormatter()
        f.calendar = calendar; f.locale = locale; f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    public static func dayMetrics(db: LisperDatabase, day: Date, calendar: Calendar = gregorian) throws -> DayMetrics {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let sessions = try db.sessions(since: start).filter { $0.startedAt < end }
        let words = sessions.reduce(0) { $0 + $1.wordCount }
        let fillers = sessions.reduce(0) { $0 + $1.fillerCount }
        let minutes = sessions.reduce(0.0) { $0 + $1.durationSeconds } / 60.0
        let raw = sessions.map { $0.rawTranscript }.joined(separator: " ")
        let analyses = sessions.compactMap { $0.id.flatMap { try? db.analysis(forSession: $0) } }
        let flows = analyses.compactMap { try? JSONDecoder().decode(FlowScore.self, from: Data($0.flowJSON.utf8)) }
        let cohs = analyses.compactMap { try? JSONDecoder().decode(CoherenceAnalysis.self, from: Data($0.coherenceJSON.utf8)) }
        let avgFlow = flows.isEmpty ? 0 : Double(flows.map { $0.overall }.reduce(0, +)) / Double(flows.count)
        let closures = zip(cohs, sessions).map { CoherenceScore.from($0.0, wordCount: $0.1.wordCount, durationSeconds: $0.1.durationSeconds) }
        let avgClosure = closures.isEmpty ? 0 : closures.map { $0.closureRate }.reduce(0, +) / Double(closures.count)
        let restarts100 = words == 0 ? 0 : Double(closures.map { $0.restartCount }.reduce(0, +)) / Double(words) * 100
        let vocab = VocabularyStats.compute(raw: raw)
        let phrases = RepeatedPhraseDetector.detect(raw: raw).prefix(5).map { "\($0.phrase) ×\($0.count)" }
        return DayMetrics(day: dayKey(day, calendar: calendar),
                          sessionCount: sessions.count, totalWords: words,
                          fillersPer100Words: words == 0 ? 0 : Double(fillers) / Double(words) * 100,
                          avgWPM: minutes > 0 ? Double(words) / minutes : 0,
                          avgFlow: avgFlow, avgClosureRate: avgClosure, restartsPer100Words: restarts100,
                          vocabularyDiversity: vocab.typeTokenRatio,
                          topRepeatedPhrases: Array(phrases),
                          leanedOnWords: vocab.leanedOnWords.prefix(5).map { $0.phrase })
    }

    public static func problems(from m: DayMetrics) -> [PlaybookCategory] {
        var p: [PlaybookCategory] = []
        if m.fillersPer100Words >= 3 { p.append(.filler) }
        if m.restartsPer100Words >= 2 || m.avgClosureRate < 0.7 { p.append(.coherence) }
        if m.vocabularyDiversity < 0.45 && m.totalWords > 50 { p.append(.vocabulary) }
        if m.avgWPM > 170 || (m.avgWPM > 0 && m.avgWPM < 110) { p.append(.pace) }
        return p.isEmpty ? [.coherence] : p
    }

    public func digest(db: LisperDatabase, day: Date,
                       calendar: Calendar = gregorian, locale: Locale = enUS) async throws -> DailyInsight {
        let key = Self.dayKey(day, calendar: calendar, locale: locale)
        if let cached = try db.dailyInsight(day: key) { return cached }
        let metrics = try Self.dayMetrics(db: db, day: day, calendar: calendar)
        guard metrics.totalWords >= 30 else { throw EngineError.unavailable("not enough speech today yet") }
        let entries = playbook.entries(for: Self.problems(from: metrics))
        let techniques = entries.map { "- \($0.technique) [\($0.evidence)] → \($0.howTo)" }.joined(separator: "\n")
        let system = """
        You are a concise speaking coach. Use ONLY the evidence-based techniques below — do not invent
        advice. Write 2–4 short markdown bullets: what went well, the single most useful thing to work on
        tomorrow, and the specific technique to try (name it). Friendly, direct, no fluff.

        Techniques you may reference:
        \(techniques)
        """
        let user = """
        Today: \(metrics.sessionCount) dictations, \(metrics.totalWords) words, \
        flow score avg \(Int(metrics.avgFlow))/100, \(String(format: "%.1f", metrics.fillersPer100Words)) fillers/100w, \
        \(String(format: "%.1f", metrics.restartsPer100Words)) restarts/100w, \
        closure rate \(Int(metrics.avgClosureRate * 100))%, avg \(Int(metrics.avgWPM)) wpm, \
        vocabulary diversity \(String(format: "%.2f", metrics.vocabularyDiversity)). \
        Over-used phrases: \(metrics.topRepeatedPhrases.isEmpty ? "none" : metrics.topRepeatedPhrases.joined(separator: ", ")). \
        Leaned-on words: \(metrics.leanedOnWords.isEmpty ? "none" : metrics.leanedOnWords.joined(separator: ", ")).
        """
        let text = try await chat.chat(system: system, user: user, model: model,
                                       maxTokens: 600, temperature: 0.3, jsonObject: false)
        let metricsJSON = (try? JSONEncoder().encode(metrics)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let insight = DailyInsight(day: key, digestMarkdown: text, metricsJSON: metricsJSON,
                                   generatedAt: Date(), modelUsed: model)
        try db.saveDailyInsight(insight)
        return insight
    }
}
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `swift run LisperKitTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LisperKit/Coach/DailyDigestGenerator.swift Tests/LisperKitTests/DailyDigestTests.swift
git commit -m "feat: DailyDigestGenerator — Playbook-grounded daily note, cached by day"
```

---

### Task 10: Settings — `coachAnalysisEnabled`

**Files:**
- Modify: `Sources/LisperKit/Settings/AppSettings.swift`
- Test: `Tests/LisperKitTests/CoachSettingsTests.swift`

**Interfaces:**
- Produces: `AppSettings.coachAnalysisEnabled: Bool` (default `true`).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/LisperKitTests/CoachSettingsTests.swift
import Testing
import Foundation
@testable import LisperKit

@Suite struct CoachSettingsTests {
    @Test func defaultsOn() { #expect(AppSettings().coachAnalysisEnabled == true) }

    @Test func tolerantDecodeKeepsDefaultWhenAbsent() throws {
        let legacy = "{\"hotkey\":\"fn\"}".data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: legacy)
        #expect(s.coachAnalysisEnabled == true)
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `swift run LisperKitTests`
Expected: FAIL — `coachAnalysisEnabled` not a member.

- [ ] **Step 3: Add the field** in `AppSettings`:

1. After `public var onboardingComplete: Bool = false` add:
   `public var coachAnalysisEnabled: Bool = true`
2. In `CodingKeys`, add `coachAnalysisEnabled` to the last case line:
   `case retention, launchAtLogin, onboardingComplete, coachAnalysisEnabled`
3. In `init(from:)`, after the `onboardingComplete` line add:
   `coachAnalysisEnabled = try c.decodeIfPresent(Bool.self, forKey: .coachAnalysisEnabled) ?? d.coachAnalysisEnabled`

- [ ] **Step 4: Run the suite to verify it passes**

Run: `swift run LisperKitTests`
Expected: PASS — including existing `SettingsTests`.

- [ ] **Step 5: Commit**

```bash
git add Sources/LisperKit/Settings/AppSettings.swift Tests/LisperKitTests/CoachSettingsTests.swift
git commit -m "feat: coachAnalysisEnabled setting (default on, tolerant decode)"
```

---

### Task 11: App wiring — trigger analysis on save + launch catch-up + settings toggle

> Thin AppKit/SwiftUI shell — not unit-tested (consistent with `Sources/Lisper`). Verified by building + the live smoke test in Task 13.

**Files:**
- Modify: `Sources/Lisper/AppEnvironment.swift`, `Sources/Lisper/AppDelegate.swift`, `Sources/Lisper/UI/Main/MainViewModel.swift`, `Sources/Lisper/UI/Main/SettingsView.swift`

**Interfaces:**
- Consumes: `CoachAnalysisService` (8), `LLMCoherenceAnalyzer` (5), `DailyDigestGenerator` (9), `Playbook` (7), `GroqClient`/`KeychainStore` (existing).
- Produces: `AppEnvironment.coachService()`, `AppEnvironment.digestGenerator()`, `.lisperAnalysisUpdated` notification.

- [ ] **Step 1: Add builders to `AppEnvironment`** (after `cleanupContext()`):

```swift
    /// Coach analyzer/service from current settings; nil when disabled or no API key.
    func coachService() -> CoachAnalysisService? {
        let s = settingsStore.settings
        guard s.coachAnalysisEnabled, let key = KeychainStore.loadAPIKey(), !key.isEmpty else { return nil }
        let client = GroqClient(baseURL: s.groqBaseURL, apiKey: key)
        let analyzer = LLMCoherenceAnalyzer(chat: client, model: s.groqChatModel)
        return CoachAnalysisService(analyzer: analyzer, modelName: s.groqChatModel)
    }

    func digestGenerator() -> DailyDigestGenerator? {
        let s = settingsStore.settings
        guard s.coachAnalysisEnabled, let key = KeychainStore.loadAPIKey(), !key.isEmpty else { return nil }
        let client = GroqClient(baseURL: s.groqBaseURL, apiKey: key)
        return DailyDigestGenerator(chat: client, model: s.groqChatModel, playbook: Playbook.loadBundled())
    }
```

- [ ] **Step 2: Add the notification** in `Sources/Lisper/UI/Main/MainViewModel.swift` (alongside `lisperSessionSaved` at line ~9):

```swift
    static let lisperAnalysisUpdated = Notification.Name("lisper.analysisUpdated")
```

- [ ] **Step 3: Trigger per-session analysis** in `Sources/Lisper/AppDelegate.swift`. Immediately AFTER the existing `NotificationCenter.default.post(name: .lisperSessionSaved, object: nil)` (line ~205), the surrounding code has the saved `SessionRecord` (the value returned from the pipeline run; locate the `let` it was bound to — e.g. `saved`/`record`). Add:

```swift
            if let svc = self.env.coachService() {
                let session = saved   // ← use the saved SessionRecord in scope here
                Task.detached(priority: .utility) {
                    _ = await svc.analyzeIfNeeded(session: session, db: self.env.database)
                    NotificationCenter.default.post(name: .lisperAnalysisUpdated, object: nil)
                }
            }
```

(If the saved record isn't currently bound to a local, capture it from `try database.save(session:)`'s return in `DictationPipeline` via the existing result the app already receives. The app already knows the session id because History refreshes on `.lisperSessionSaved` — reuse the same value.)

- [ ] **Step 4: Launch catch-up** — in `AppDelegate.applicationDidFinishLaunching` (end of the method), add:

```swift
        if let svc = env.coachService() {
            Task.detached(priority: .background) {
                await svc.analyzePending(db: self.env.database, limit: 10)
                NotificationCenter.default.post(name: .lisperAnalysisUpdated, object: nil)
            }
        }
```

- [ ] **Step 5: Settings toggle** — in `Sources/Lisper/UI/Main/SettingsView.swift`, near the existing `saveAudioForDebugging` toggle, add a bound toggle for `coachAnalysisEnabled` (follow the exact binding pattern already used for other `AppSettings` bools in that view), labeled **"Coach analysis (sends transcripts to Groq for clarity scoring)"**.

- [ ] **Step 6: Build**

Run: `swift build`
Expected: `Build complete!` with no errors.

- [ ] **Step 7: Commit**

```bash
git add Sources/Lisper/AppEnvironment.swift Sources/Lisper/AppDelegate.swift Sources/Lisper/UI/Main/MainViewModel.swift Sources/Lisper/UI/Main/SettingsView.swift
git commit -m "feat: wire coach analysis (per-session trigger, launch catch-up, settings toggle)"
```

---

### Task 12: Dashboard — Flow Score hero, panels, daily digest

> Thin SwiftUI shell — not unit-tested. Use `Theme` tokens only; match the existing `InsightsView` styling (hairline lists, stat bands, glass cards). Exact layout is an implementation detail; the data wiring below is the contract.

**Files:**
- Modify: `Sources/Lisper/UI/Main/CoachView.swift` (the `InsightsView`), `Sources/Lisper/UI/Main/MainViewModel.swift`

**Interfaces:**
- Consumes: `db.recentAnalyses`, `db.dailyInsight`, `db.dailyInsights`, `DailyDigestGenerator` (via `env.digestGenerator()`), `FlowScore`, `CoherenceAnalysis`, `RepeatedPhraseDetector`, `VocabularyStats`.

- [ ] **Step 1: Add load helpers to `MainViewModel`**

```swift
    // Today's flow + recent analyses, decoded for the dashboard.
    func recentFlowScores(limit: Int = 30) -> [(date: Date, flow: FlowScore)] {
        let analyses = (try? env.database.recentAnalyses(limit: limit)) ?? []
        return analyses.compactMap { a in
            guard let f = try? JSONDecoder().decode(FlowScore.self, from: Data(a.flowJSON.utf8)) else { return nil }
            return (a.generatedAt, f)
        }
    }

    func todaysInsight() -> DailyInsight? {
        try? env.database.dailyInsight(day: DailyDigestGenerator.dayKey(Date()))
    }

    func generateTodaysDigest() async -> DailyInsight? {
        guard let gen = env.digestGenerator() else { return nil }
        return try? await gen.digest(db: env.database, day: Date())
    }

    func recentCoherence(limit: Int = 5) -> [(SessionAnalysis, CoherenceAnalysis)] {
        let analyses = (try? env.database.recentAnalyses(limit: limit)) ?? []
        return analyses.compactMap { a in
            (try? JSONDecoder().decode(CoherenceAnalysis.self, from: Data(a.coherenceJSON.utf8))).map { (a, $0) }
        }
    }
```

- [ ] **Step 2: Add the Flow hero + panels to `InsightsView`** (in `CoachView.swift`). At the top of the existing scroll content, above the current filler stat band, add:

- A **hero**: today's flow (most recent `recentFlowScores().first?.flow.overall`, or "—" if none) rendered large (poster-weight numeral via `Theme`), with the four sub-scores (`fillerFree`, `continuity`, `singleThread` shown as "—" when `-1`, `sustain`) as a small breakdown row, and a sparkline of `recentFlowScores().reversed().map { $0.flow.overall }` (reuse the existing chart pattern used for the filler trend).
- A **daily digest card** (glass card, matching the existing weekly-tip card): shows `todaysInsight()?.digestMarkdown` as markdown; a "Generate today's insight" button calls `await model.generateTodaysDigest()` then reloads (mirror the existing `loadTip()`/"Generate weekly tips" button).
- A **coherence panel**: `model.recentCoherence()` → for each, list opened points (✓ closed / ◦ left open) and restarts, each showing the quoted evidence text (`openedQuote` / `restart.quote`) in a hairline row.
- A **repeated-phrase panel**: compute over recent raw transcripts — `RepeatedPhraseDetector.detect(raw: recentRawJoined)` (build `recentRawJoined` from `model.env.database.recentSessions(limit: 50)`); list top phrases as "phrase ×N".
- A **vocabulary panel**: `VocabularyStats.compute(raw: recentRawJoined)` → show `typeTokenRatio` (as a "diversity" %) and `leanedOnWords`.

- [ ] **Step 3: Refresh on analysis updates** — in `InsightsView`, add an `.onReceive(NotificationCenter.default.publisher(for: .lisperAnalysisUpdated))` that re-runs the view's load function (the same one currently triggered on appear).

- [ ] **Step 4: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/Lisper/UI/Main/CoachView.swift Sources/Lisper/UI/Main/MainViewModel.swift
git commit -m "feat: Insights dashboard — Flow Score hero, coherence/vocab/phrase panels, daily digest"
```

---

### Task 13: Playbook research pass + live integration smoke test

**Files:**
- Modify: `Sources/LisperKit/Coach/Playbook/playbook.json` (expand/verify)
- Verify: full app round-trip on the real Groq key.

- [ ] **Step 1: Harden the Playbook citations**

Use the `deep-research` skill (or equivalent web research) to verify each seed entry's citation and expand to ~3–4 entries per category. Keep the JSON shape from Task 7. **Every entry must keep a real, checkable `evidence` string.** Re-run `swift run LisperKitTests` (the `bundledPlaybookLoadsAndIsCited` test still guards non-empty citations + all categories present).

```bash
git add Sources/LisperKit/Coach/Playbook/playbook.json
git commit -m "docs: expand + verify Playbook citations (research pass)"
```

- [ ] **Step 2: Build + launch the real app**

Run: `./scripts/run.sh`
Expected: `dist/Lisper.app` rebuilds and launches.

- [ ] **Step 3: Live smoke test** (requires a Groq API key set in Settings and `coachAnalysisEnabled` on)

1. Dictate a ~60–90s rambling, multi-topic stretch (think out loud, backtrack on purpose).
2. Confirm the paste happens instantly (analysis must NOT block it).
3. Within a few seconds, open **Insights**: a Flow Score appears for the session; the coherence panel shows real quoted evidence; the repeated-phrase + vocabulary panels populate.
4. Click **Generate today's insight**: a grounded daily note appears, referencing a Playbook technique by name.
5. Toggle `coachAnalysisEnabled` OFF, dictate again → no analysis call is made (Flow shows the partial/`—` state); toggle back ON.
6. Quit + relaunch → the launch catch-up analyzes any session that was missed.

- [ ] **Step 4: Record the result** — note any score-calibration tweaks needed (the `FlowScore` ceilings / `DailyDigestGenerator.problems` thresholds) and adjust constants if the live scores feel off. Commit any tuning:

```bash
git add -A
git commit -m "tune: calibrate Flow Score ceilings against real sessions"
```

---

## Self-Review

**Spec coverage:** Flow Score → Task 4; metrics layer (repeated phrases, vocab, pace/disfluency) → Tasks 1–2; coherence extract→score→advise → Tasks 3 (score), 5 (extract), 7+9 (advise); reliability via evidence-anchored parse → Task 5; runs after paste → Task 11; Playbook (cited, bundled) → Task 7; daily digest + rollups → Task 9; persistence (two additive tables) → Task 6; dashboard → Task 12; `coachAnalysisEnabled` privacy toggle → Tasks 10–11; graceful degradation → Tasks 4 (partial Flow) + 5 (tolerant parse) + 11 (nil service); Gregorian/en_US date handling → Task 9. v2 (Flow Challenge mode) and v3 (local-first) remain out of scope per the spec.

**Type consistency:** `FlowScore.compute(stats:disfluency:coherence:durationSeconds:)` is used identically in Tasks 4, 8, and 9. `CoherenceScore.from(_:wordCount:durationSeconds:)` consistent across 3, 8, 9. `ChatCompleting.chat(system:user:model:maxTokens:temperature:jsonObject:)` matches the Task 5 `GroqClient` change and the stubs in Tasks 9. `SessionAnalysis`/`DailyInsight` fields match between Task 6 records, the migration columns, and the consumers in 8/9/12.

**Notes for the implementer:** Task 11 Step 3 depends on the exact local variable holding the saved `SessionRecord` in `AppDelegate` — grep around `AppDelegate.swift:205` for the value passed to History/the `.lisperSessionSaved` post and reuse it. Everything else is fully specified.
