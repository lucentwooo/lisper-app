# Lisper Debugging & Continuous-Improvement Loop — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every bad dictation explainable (a local log), reproducible (saved audio + a one-click report), and permanently fixable (a regression-test corpus that only grows).

**Architecture:** Three layers. (1) A JSONL **observability log** of every dictation — loudness, raw/cleaned text, which guards fired. (2) **Per-session audio** persisted to disk (7-day purge) with History **Extract audio** / **Report bad dictation** actions that bundle audio + context + a user note. (3) A **regression ratchet** — offline guard tests (the workhorse) plus an opt-in live WAV-replay harness — driven by Claude from reports. Logic lives in `LisperKit` (unit-tested); filesystem-location wiring and UI live in the `Lisper` app target, matching the existing testability boundary.

**Tech Stack:** Swift 5 language mode, SPM (`LisperKit` library + `Lisper` executable), Swift Testing, GRDB/SQLite, AVFoundation. Spec: `docs/superpowers/specs/2026-06-13-lisper-debug-loop-design.md`.

**Test note:** Run the full LisperKit suite with `swift run LisperKitTests` (NOT `swift test` — it executes nothing on this CLT-only machine). `--filter` is unsupported; always run the whole suite. App-target code (`Sources/Lisper/`) is not unit-tested — those tasks are verified with `swift build` + a manual smoke step.

---

## File structure

**New (LisperKit — tested):**
- `Sources/LisperKit/Debug/DictationDebugRecord.swift` — Codable record = one log line / technical half of a report.
- `Sources/LisperKit/Debug/GuardLog.swift` — thread-safe collector of guard-event names fired during one dictation.
- `Sources/LisperKit/Debug/DebugLog.swift` — appends records as JSONL to an injected file URL; rotates at a size cap.
- `Sources/LisperKit/Debug/ReportWriter.swift` — assembles a report bundle directory.
- `Sources/LisperKit/Debug/AudioRetention.swift` — pure "which audio files have expired" decision.

**New (Lisper app — build+smoke):**
- `Sources/Lisper/Audio/AudioStore.swift` — writes/reads/purges `audio/<id>.wav`.

**New (tests):**
- `Tests/LisperKitTests/DictationDebugRecordTests.swift`
- `Tests/LisperKitTests/GuardLogTests.swift`
- `Tests/LisperKitTests/DebugLogTests.swift`
- `Tests/LisperKitTests/ReportWriterTests.swift`
- `Tests/LisperKitTests/AudioRetentionTests.swift`
- `Tests/LisperKitTests/PipelineDebugTests.swift`
- `Tests/LisperKitTests/LiveReplayTests.swift` (env-gated; offline = skip)

**Modified:**
- `Sources/LisperKit/Pipeline/DictationPipeline.swift` — emit a record; add `rms`/`guardsFired` to `DictationOutcome`; optional `debugLog`/`guardLog` init params.
- `Sources/LisperKit/Engines/GroqEngines.swift` — `GroqWhisperEngine` records guard events to an optional `GuardLog`.
- `Sources/LisperKit/Settings/AppSettings.swift` — add `saveAudioForDebugging` toggle.
- `Sources/Lisper/AppEnvironment.swift` — build `DebugLog`/`GuardLog`, expose debug dirs, wire into pipeline + engine, purge on launch.
- `Sources/Lisper/AppDelegate.swift` — save session audio after the outcome.
- `Sources/Lisper/UI/Main/HistoryView.swift` — Extract audio / Report bad dictation buttons + note sheet.
- `Sources/Lisper/UI/Main/MainViewModel.swift` — actions backing those buttons.
- `Sources/Lisper/UI/Main/SettingsView.swift` — the debugging toggle.
- `CLAUDE.md` and `docs/superpowers/specs/2026-06-12-lisper-design.md` — record the audio-on-disk deviation.

---

## Task 1: DictationDebugRecord

**Files:**
- Create: `Sources/LisperKit/Debug/DictationDebugRecord.swift`
- Test: `Tests/LisperKitTests/DictationDebugRecordTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import LisperKit

@Suite struct DictationDebugRecordTests {
    @Test func testCodableRoundTrip() throws {
        let r = DictationDebugRecord(
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            sessionId: 42, durationSeconds: 3.5, rms: 0.12,
            engineUsed: "groq", cleanupUsed: "llm",
            rawTranscript: "um hello", cleanedText: "Hello.",
            guardsFired: ["silence"], latencyMs: 850, error: nil)
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(DictationDebugRecord.self, from: data)
        #expect(back == r)
    }

    @Test func testJSONLineHasNoNewlines() throws {
        let r = DictationDebugRecord(
            timestamp: Date(timeIntervalSince1970: 0), sessionId: nil,
            durationSeconds: 1, rms: 0, engineUsed: "apple", cleanupUsed: "rules",
            rawTranscript: "line one\nline two", cleanedText: "x",
            guardsFired: [], latencyMs: 1, error: "boom")
        let line = try r.jsonLine()
        #expect(!line.dropLast().contains("\n")) // exactly one trailing newline
        #expect(line.hasSuffix("\n"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift run LisperKitTests`
Expected: FAIL — `cannot find 'DictationDebugRecord' in scope`.

- [ ] **Step 3: Implement**

```swift
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

    public init(timestamp: Date, sessionId: Int64?, durationSeconds: Double, rms: Double,
                engineUsed: String, cleanupUsed: String, rawTranscript: String,
                cleanedText: String, guardsFired: [String], latencyMs: Int, error: String?) {
        self.timestamp = timestamp; self.sessionId = sessionId
        self.durationSeconds = durationSeconds; self.rms = rms
        self.engineUsed = engineUsed; self.cleanupUsed = cleanupUsed
        self.rawTranscript = rawTranscript; self.cleanedText = cleanedText
        self.guardsFired = guardsFired; self.latencyMs = latencyMs; self.error = error
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
```

> Note: `jsonLine()` produces compact JSON (no `.prettyPrinted`), so embedded newlines in transcripts are escaped as `\n` inside the string — the line itself has exactly one trailing newline. That is what the second test asserts.

- [ ] **Step 4: Run to verify it passes**

Run: `swift run LisperKitTests`
Expected: PASS (all suites).

- [ ] **Step 5: Commit**

```bash
git add Sources/LisperKit/Debug/DictationDebugRecord.swift Tests/LisperKitTests/DictationDebugRecordTests.swift
git commit -m "feat: DictationDebugRecord (JSONL debug record)"
```

---

## Task 2: GuardLog

**Files:**
- Create: `Sources/LisperKit/Debug/GuardLog.swift`
- Test: `Tests/LisperKitTests/GuardLogTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import LisperKit

@Suite struct GuardLogTests {
    @Test func testRecordsInOrderAndDeduplicates() {
        let log = GuardLog()
        log.record("hallucination")
        log.record("retry")
        log.record("hallucination") // duplicate ignored
        #expect(log.all() == ["hallucination", "retry"])
    }

    @Test func testEmptyByDefault() {
        #expect(GuardLog().all() == [])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift run LisperKitTests`
Expected: FAIL — `cannot find 'GuardLog' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Thread-safe, per-dictation collector of guard-event names (e.g. "silence",
/// "hallucination", "retry", "vocabEcho"). Shared between the pipeline and the
/// engine for one dictation, then read once to build the debug record.
public final class GuardLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    public init() {}

    public func record(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        if !events.contains(name) { events.append(name) }
    }

    public func all() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift run LisperKitTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LisperKit/Debug/GuardLog.swift Tests/LisperKitTests/GuardLogTests.swift
git commit -m "feat: GuardLog collector for guard events"
```

---

## Task 3: DebugLog (JSONL appender + rotation)

**Files:**
- Create: `Sources/LisperKit/Debug/DebugLog.swift`
- Test: `Tests/LisperKitTests/DebugLogTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import LisperKit

@Suite struct DebugLogTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lisper-debuglog-\(UUID().uuidString)")
            .appendingPathComponent("dictations.jsonl")
    }

    private func record(_ raw: String) -> DictationDebugRecord {
        DictationDebugRecord(timestamp: Date(timeIntervalSince1970: 0), sessionId: 1,
            durationSeconds: 1, rms: 0.1, engineUsed: "groq", cleanupUsed: "llm",
            rawTranscript: raw, cleanedText: raw, guardsFired: [], latencyMs: 1, error: nil)
    }

    @Test func testAppendCreatesDirAndWritesOneLinePerRecord() throws {
        let url = tempURL()
        let log = DebugLog(fileURL: url, maxBytes: 1_000_000)
        try log.append(record("one"))
        try log.append(record("two"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2)
        #expect(text.contains("\"rawTranscript\":\"one\""))
    }

    @Test func testRotationCapsFileSize() throws {
        let url = tempURL()
        let log = DebugLog(fileURL: url, maxBytes: 300) // tiny cap forces rotation
        for i in 0..<20 { try log.append(record("entry-\(i)")) }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        #expect(size <= 300 * 2) // current file stays bounded (cap + one over)
        // rotated file exists
        let rotated = url.deletingLastPathComponent().appendingPathComponent("dictations.jsonl.1")
        #expect(FileManager.default.fileExists(atPath: rotated.path))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift run LisperKitTests`
Expected: FAIL — `cannot find 'DebugLog' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Appends DictationDebugRecords as JSONL to an injected file URL. When the file
/// would exceed `maxBytes`, the current file is rotated to `<name>.1` (overwriting
/// any previous rotation) and a fresh file is started. Location-agnostic: the app
/// passes the real App Support path; tests pass a temp file.
public final class DebugLog: @unchecked Sendable {
    private let fileURL: URL
    private let maxBytes: Int
    private let lock = NSLock()

    public init(fileURL: URL, maxBytes: Int = 5_000_000) {
        self.fileURL = fileURL; self.maxBytes = maxBytes
    }

    public func append(_ record: DictationDebugRecord) throws {
        let line = try record.jsonLine()
        let data = Data(line.utf8)
        lock.lock(); defer { lock.unlock() }

        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        let currentSize = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        if let size = currentSize, size + data.count > maxBytes, size > 0 {
            let rotated = fileURL.deletingLastPathComponent()
                .appendingPathComponent(fileURL.lastPathComponent + ".1")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: fileURL, to: rotated)
        }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL)
        }
    }
}
```

> Note: `currentSize` is an `Int?` because `attributesOfItem(...)[.size] as? Int` is optional; the `if let size = currentSize` unwraps it before comparing.

- [ ] **Step 4: Run to verify it passes**

Run: `swift run LisperKitTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LisperKit/Debug/DebugLog.swift Tests/LisperKitTests/DebugLogTests.swift
git commit -m "feat: DebugLog JSONL appender with rotation"
```

---

## Task 4: Pipeline emits a debug record (rms + guardsFired)

**Files:**
- Modify: `Sources/LisperKit/Pipeline/DictationPipeline.swift`
- Test: `Tests/LisperKitTests/PipelineDebugTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import GRDB
@testable import LisperKit

private struct GuardMockSTT: TranscriptionEngine {
    let name: String
    let result: Result<String, EngineError>
    let log: GuardLog
    let signal: String?
    func transcribe(audio: CapturedAudio, dictionaryTerms: [String]) async throws -> String {
        if let signal { log.record(signal) }
        return try result.get()
    }
}

private struct OKCleanup: CleanupEngine {
    let name = "llm"
    func clean(raw: String, context: CleanupContext) async throws -> String { "Clean." }
}

@Suite struct PipelineDebugTests {
    private func ctx() -> CleanupContext {
        CleanupContext(appName: "TextEdit", bundleID: "com.apple.TextEdit", style: .casual, dictionaryTerms: [])
    }
    private func speech() -> CapturedAudio { CapturedAudio(samples: Array(repeating: 0.1, count: 16_000)) }
    private func silent() -> CapturedAudio { CapturedAudio(samples: Array(repeating: 0, count: 16_000)) }

    @Test func testSuccessWritesRecordWithRmsAndGuards() async throws {
        let db = try LisperDatabase(queue: DatabaseQueue())
        let gl = GuardLog()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lisper-pdbg-\(UUID().uuidString)/d.jsonl")
        let dl = DebugLog(fileURL: url)
        let p = DictationPipeline(
            primarySTT: GuardMockSTT(name: "groq", result: .success("raw words here"), log: gl, signal: "retry"),
            fallbackSTT: nil, llmCleanup: OKCleanup(), ruleCleanup: RuleCleanupEngine(),
            database: db, debugLog: dl, guardLog: gl)
        let outcome = try await p.process(audio: speech(), context: ctx(), customFillers: [])
        #expect(outcome.rms > 0.05)
        #expect(outcome.guardsFired.contains("retry"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"rawTranscript\":\"raw words here\""))
        #expect(text.contains("\"retry\""))
    }

    @Test func testSilenceRecordsGuardAndStillThrows() async throws {
        let db = try LisperDatabase(queue: DatabaseQueue())
        let gl = GuardLog()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lisper-pdbg-\(UUID().uuidString)/d.jsonl")
        let dl = DebugLog(fileURL: url)
        let p = DictationPipeline(
            primarySTT: GuardMockSTT(name: "groq", result: .success("x"), log: gl, signal: nil),
            fallbackSTT: nil, llmCleanup: nil, ruleCleanup: RuleCleanupEngine(),
            database: db, debugLog: dl, guardLog: gl)
        await #expect(throws: PipelineError.tooShort) {
            _ = try await p.process(audio: silent(), context: ctx(), customFillers: [])
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"silence\""))
        #expect(text.contains("\"error\":\"tooShort\""))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift run LisperKitTests`
Expected: FAIL — `DictationPipeline` has no `debugLog:`/`guardLog:` params; `DictationOutcome` has no `rms`/`guardsFired`.

- [ ] **Step 3: Implement — update `DictationOutcome` and `DictationPipeline`**

Replace the `DictationOutcome` struct with:

```swift
public struct DictationOutcome: Sendable {
    public let rawTranscript: String
    public let cleanedText: String
    public let engineUsed: String
    public let cleanupUsed: String
    public let stats: TranscriptStats
    public let session: SessionRecord
    public let rms: Double
    public let guardsFired: [String]
}
```

Replace the `DictationPipeline` stored properties + init with:

```swift
public final class DictationPipeline: @unchecked Sendable {
    private let primarySTT: TranscriptionEngine?
    private let fallbackSTT: TranscriptionEngine?
    private let llmCleanup: CleanupEngine?
    private let ruleCleanup: CleanupEngine
    private let database: LisperDatabase
    private let debugLog: DebugLog?
    private let guardLog: GuardLog?

    public init(primarySTT: TranscriptionEngine?, fallbackSTT: TranscriptionEngine?,
                llmCleanup: CleanupEngine?, ruleCleanup: CleanupEngine, database: LisperDatabase,
                debugLog: DebugLog? = nil, guardLog: GuardLog? = nil) {
        self.primarySTT = primarySTT; self.fallbackSTT = fallbackSTT
        self.llmCleanup = llmCleanup; self.ruleCleanup = ruleCleanup; self.database = database
        self.debugLog = debugLog; self.guardLog = guardLog
    }
```

Replace the body of `process(...)` with a version that always emits a record. Full method:

```swift
    public func process(audio: CapturedAudio, context: CleanupContext,
                        customFillers: [String]) async throws -> DictationOutcome {
        let startedAt = Date()
        let rms = Double(AudioGate.rms(audio.samples))

        // Helper: write one debug record (best-effort) then return/throw.
        func emit(sessionId: Int64?, engine: String, cleanup: String,
                  raw: String, cleaned: String, error: String?) {
            let rec = DictationDebugRecord(
                timestamp: startedAt, sessionId: sessionId,
                durationSeconds: audio.durationSeconds, rms: rms,
                engineUsed: engine, cleanupUsed: cleanup,
                rawTranscript: raw, cleanedText: cleaned,
                guardsFired: guardLog?.all() ?? [],
                latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                error: error)
            try? debugLog?.append(rec)
        }

        guard audio.durationSeconds >= 0.4 else {
            emit(sessionId: nil, engine: "", cleanup: "", raw: "", cleaned: "", error: "tooShort")
            throw PipelineError.tooShort
        }
        guard !AudioGate.isLikelySilent(audio) else {
            guardLog?.record("silence")
            emit(sessionId: nil, engine: "", cleanup: "", raw: "", cleaned: "", error: "tooShort")
            throw PipelineError.tooShort
        }

        // 1) Transcribe with fallback
        var raw: String? = nil
        var engineUsed = ""
        var lastError = "no engines configured"
        let engines = [primarySTT, fallbackSTT].compactMap { $0 }
        for (idx, engine) in engines.enumerated() {
            do {
                raw = try await engine.transcribe(audio: audio, dictionaryTerms: context.dictionaryTerms)
                engineUsed = engine.name
                if idx > 0 { guardLog?.record("sttFallback") }
                break
            } catch {
                lastError = "\(engine.name): \(error)"
            }
        }
        guard let rawTranscript = raw, !rawTranscript.isEmpty else {
            emit(sessionId: nil, engine: "", cleanup: "", raw: "", cleaned: "", error: lastError)
            throw PipelineError.allEnginesFailed(lastError)
        }

        // 2) Clean with fallback
        var cleaned: String
        var cleanupUsed: String
        if let llm = llmCleanup {
            do {
                cleaned = try await llm.clean(raw: rawTranscript, context: context)
                cleanupUsed = llm.name
            } catch {
                cleaned = try await ruleCleanup.clean(raw: rawTranscript, context: context)
                cleanupUsed = ruleCleanup.name
                guardLog?.record("cleanupFallback")
            }
        } else {
            cleaned = try await ruleCleanup.clean(raw: rawTranscript, context: context)
            cleanupUsed = ruleCleanup.name
        }

        // 3) Stats on RAW speech (the coach's source of truth)
        let stats = TranscriptStats.compute(raw: rawTranscript,
                                            durationSeconds: audio.durationSeconds,
                                            customFillers: customFillers)

        // 4) Persist
        let session = SessionRecord(
            id: nil, startedAt: startedAt, durationSeconds: audio.durationSeconds,
            appBundleID: context.bundleID, appName: context.appName,
            rawTranscript: rawTranscript, cleanedText: cleaned,
            wordCount: stats.wordCount, fillerCount: stats.fillerCount,
            fillersJSON: stats.fillerCounts, wpm: stats.wordsPerMinute,
            engineUsed: engineUsed, cleanupUsed: cleanupUsed, inserted: true)
        let saved = try database.save(session: session)

        emit(sessionId: saved.id, engine: engineUsed, cleanup: cleanupUsed,
             raw: rawTranscript, cleaned: cleaned, error: nil)

        return DictationOutcome(rawTranscript: rawTranscript, cleanedText: cleaned,
                                engineUsed: engineUsed, cleanupUsed: cleanupUsed,
                                stats: stats, session: saved,
                                rms: rms, guardsFired: guardLog?.all() ?? [])
    }
```

> The earlier `let startedAt = Date()` line that followed the duration guard is now folded into the top of the method — make sure it appears only once.

- [ ] **Step 4: Run to verify it passes**

Run: `swift run LisperKitTests`
Expected: PASS — including the existing `PipelineFallbackTests` (the `DictationOutcome` additions are populated by the pipeline; those tests only read `.cleanedText`/`.engineUsed`/`.cleanupUsed`, so they still compile and pass).

- [ ] **Step 5: Commit**

```bash
git add Sources/LisperKit/Pipeline/DictationPipeline.swift Tests/LisperKitTests/PipelineDebugTests.swift
git commit -m "feat: pipeline emits debug record with rms and guardsFired"
```

---

## Task 5: GroqWhisperEngine records its guard events

**Files:**
- Modify: `Sources/LisperKit/Engines/GroqEngines.swift`

This is glue around already-tested guard functions (`HallucinationGuard`, `isVocabularyEcho`); the engine's network path is not unit-tested (consistent with the existing code, which has no `GroqWhisperEngine` network tests). Verified by build + the live-replay harness (Task 11).

- [ ] **Step 1: Add an optional `guardLog` and record events**

In `GroqWhisperEngine`, add the stored property and update the init:

```swift
    let language: String
    let guardLog: GuardLog?

    public init(client: GroqClient, model: String, language: String = "en", guardLog: GuardLog? = nil) {
        self.client = client; self.model = model; self.language = language; self.guardLog = guardLog
    }
```

Update `transcribe(...)` so each guard branch records to `guardLog`:

```swift
        var text = try await client.transcribe(wav: wav, model: model, prompt: prompt,
                                                language: lang, temperature: 0)
        if HallucinationGuard.isLikelyHallucination(text) {
            guardLog?.record("hallucination")
            text = try await client.transcribe(wav: wav, model: model, prompt: prompt,
                                                language: lang, temperature: 0.4)
            guardLog?.record("retry")
            if HallucinationGuard.isLikelyHallucination(text) {
                throw EngineError.emptyTranscript
            }
        }
        if Self.isVocabularyEcho(text, terms: dictionaryTerms) {
            guardLog?.record("vocabEcho")
            throw EngineError.emptyTranscript
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Run the suite (no regressions)**

Run: `swift run LisperKitTests`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/LisperKit/Engines/GroqEngines.swift
git commit -m "feat: GroqWhisperEngine records guard events to GuardLog"
```

---

## Task 6: AudioRetention (pure expiry decision) + AudioStore (app)

**Files:**
- Create: `Sources/LisperKit/Debug/AudioRetention.swift`
- Test: `Tests/LisperKitTests/AudioRetentionTests.swift`
- Create: `Sources/Lisper/Audio/AudioStore.swift`

- [ ] **Step 1: Write the failing test (pure expiry)**

```swift
import Testing
import Foundation
@testable import LisperKit

@Suite struct AudioRetentionTests {
    @Test func testExpiredOlderThanTTL() {
        let now = Date(timeIntervalSince1970: 10 * 86_400) // day 10
        let files: [(name: String, modified: Date)] = [
            ("1.wav", Date(timeIntervalSince1970: 2 * 86_400)),  // 8 days old -> expired
            ("2.wav", Date(timeIntervalSince1970: 5 * 86_400)),  // 5 days old -> keep
            ("3.wav", Date(timeIntervalSince1970: 9.5 * 86_400)),// ~12h old  -> keep
        ]
        let expired = AudioRetention.expired(files: files, now: now, ttlDays: 7)
        #expect(expired == ["1.wav"])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift run LisperKitTests`
Expected: FAIL — `cannot find 'AudioRetention' in scope`.

- [ ] **Step 3: Implement the pure decision**

```swift
import Foundation

/// Pure policy: which saved-audio files have aged out. The app side supplies
/// (filename, modified-date) pairs; this returns the names to delete.
public enum AudioRetention {
    public static func expired(files: [(name: String, modified: Date)],
                               now: Date, ttlDays: Int) -> [String] {
        let cutoff = now.addingTimeInterval(-Double(ttlDays) * 86_400)
        return files.filter { $0.modified < cutoff }.map { $0.name }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift run LisperKitTests`
Expected: PASS.

- [ ] **Step 5: Implement `AudioStore` (app side; uses WavEncoder + AudioRetention)**

```swift
// Sources/Lisper/Audio/AudioStore.swift
import Foundation
import LisperKit

/// Persists per-session audio as WAV under Application Support/Lisper/audio,
/// and purges files older than the retention window. Best-effort: every method
/// swallows errors — audio is a debugging aid, never the dictation contract.
enum AudioStore {
    static let ttlDays = 7

    static func dir() -> URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lisper/audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func url(for sessionId: Int64) -> URL {
        dir().appendingPathComponent("\(sessionId).wav")
    }

    static func save(_ audio: CapturedAudio, sessionId: Int64) {
        let wav = WavEncoder.encode(audio)
        try? wav.write(to: url(for: sessionId))
    }

    static func exists(sessionId: Int64) -> Bool {
        FileManager.default.fileExists(atPath: url(for: sessionId).path)
    }

    static func purgeExpired(now: Date = Date()) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir().path) else { return }
        let files: [(name: String, modified: Date)] = names.compactMap { name in
            let p = dir().appendingPathComponent(name).path
            guard let m = try? fm.attributesOfItem(atPath: p)[.modificationDate] as? Date,
                  let mod = m else { return nil }
            return (name, mod)
        }
        for name in AudioRetention.expired(files: files, now: now, ttlDays: ttlDays) {
            try? fm.removeItem(at: dir().appendingPathComponent(name))
        }
    }
}
```

- [ ] **Step 6: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 7: Commit**

```bash
git add Sources/LisperKit/Debug/AudioRetention.swift Tests/LisperKitTests/AudioRetentionTests.swift Sources/Lisper/Audio/AudioStore.swift
git commit -m "feat: AudioRetention policy + AudioStore (save/purge per-session WAV)"
```

---

## Task 7: ReportWriter (bundle assembler)

**Files:**
- Create: `Sources/LisperKit/Debug/ReportWriter.swift`
- Test: `Tests/LisperKitTests/ReportWriterTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import LisperKit

@Suite struct ReportWriterTests {
    @Test func testWritesBundleWithJSONAndAudio() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("lisper-reports-\(UUID().uuidString)")
        let rec = DictationDebugRecord(
            timestamp: Date(timeIntervalSince1970: 0), sessionId: 7, durationSeconds: 2,
            rms: 0.2, engineUsed: "groq", cleanupUsed: "llm",
            rawTranscript: "VHL VAR GEMETSUI", cleanedText: "VHL VAR GEMETSUI",
            guardsFired: [], latencyMs: 100, error: nil)
        let settings = ["dictionaryTerms": "Groq, Lisper", "transcriptionLanguage": "en"]
        let folder = try ReportWriter.write(
            into: base, sessionId: 7, record: rec,
            settingsSnapshot: settings, note: "I said hello, it typed gibberish",
            audio: Data([0x52, 0x49, 0x46, 0x46])) // "RIFF"

        let json = try String(contentsOf: folder.appendingPathComponent("report.json"), encoding: .utf8)
        #expect(json.contains("\"note\":\"I said hello, it typed gibberish\""))
        #expect(json.contains("\"transcriptionLanguage\":\"en\""))
        #expect(!json.lowercased().contains("apikey"))
        #expect(!json.lowercased().contains("api_key"))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("audio.wav").path))
    }

    @Test func testWritesWithoutAudioWhenPurged() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("lisper-reports-\(UUID().uuidString)")
        let rec = DictationDebugRecord(
            timestamp: Date(timeIntervalSince1970: 0), sessionId: 8, durationSeconds: 1,
            rms: 0, engineUsed: "", cleanupUsed: "", rawTranscript: "", cleanedText: "",
            guardsFired: ["silence"], latencyMs: 1, error: "tooShort")
        let folder = try ReportWriter.write(into: base, sessionId: 8, record: rec,
            settingsSnapshot: [:], note: "nothing was said", audio: nil)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("report.json").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("audio.wav").path))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift run LisperKitTests`
Expected: FAIL — `cannot find 'ReportWriter' in scope`.

- [ ] **Step 3: Implement**

```swift
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
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(report).write(to: folder.appendingPathComponent("report.json"))

        if let audio { try audio.write(to: folder.appendingPathComponent("audio.wav")) }
        return folder
    }
}
```

> Note: the `apikey`/`api_key` assertions pass because the caller never puts the key in `settingsSnapshot` (enforced in Task 9). `.sortedKeys` keeps `report.json` diff-friendly.

- [ ] **Step 4: Run to verify it passes**

Run: `swift run LisperKitTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LisperKit/Debug/ReportWriter.swift Tests/LisperKitTests/ReportWriterTests.swift
git commit -m "feat: ReportWriter assembles a debug report bundle"
```

---

## Task 8: Settings toggle — saveAudioForDebugging

**Files:**
- Modify: `Sources/LisperKit/Settings/AppSettings.swift`
- Modify: `Tests/LisperKitTests/SettingsTests.swift`
- Modify: `Sources/Lisper/UI/Main/SettingsView.swift`

- [ ] **Step 1: Add a failing settings test**

Append to `SettingsTests` (inside the existing `@Suite struct`):

```swift
    @Test func testSaveAudioForDebuggingDefaultsOnAndRoundTrips() {
        let defaults = UserDefaults(suiteName: "lisper.test.\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        #expect(store.settings.saveAudioForDebugging == true)
        store.update { $0.saveAudioForDebugging = false }
        let reopened = SettingsStore(defaults: defaults)
        #expect(reopened.settings.saveAudioForDebugging == false)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift run LisperKitTests`
Expected: FAIL — `value of type 'AppSettings' has no member 'saveAudioForDebugging'`.

- [ ] **Step 3: Implement — add the property, coding key, and tolerant decode**

In `AppSettings`, add the stored property (near `transcriptionLanguage`):

```swift
    public var saveAudioForDebugging: Bool = true
```

Add it to `CodingKeys`:

```swift
        case groqWhisperModel, groqChatModel, groqBaseURL, transcriptionLanguage, saveAudioForDebugging
```

Add the tolerant decode line in `init(from:)`:

```swift
        saveAudioForDebugging = try c.decodeIfPresent(Bool.self, forKey: .saveAudioForDebugging) ?? d.saveAudioForDebugging
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift run LisperKitTests`
Expected: PASS.

- [ ] **Step 5: Add the UI control**

In `Sources/Lisper/UI/Main/SettingsView.swift`, add a toggle bound to the setting near the other privacy/engine controls (match the file's existing `Toggle`/row styling):

```swift
Toggle("Save audio for debugging (kept 7 days, never leaves this Mac)",
       isOn: $model.settings.saveAudioForDebugging)
```

> If `SettingsView` uses a custom row wrapper rather than bare `Toggle`, follow that local pattern; the binding `$model.settings.saveAudioForDebugging` is the key part (writing `model.settings` auto-persists via the `didSet` in `MainViewModel`).

- [ ] **Step 6: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 7: Commit**

```bash
git add Sources/LisperKit/Settings/AppSettings.swift Tests/LisperKitTests/SettingsTests.swift Sources/Lisper/UI/Main/SettingsView.swift
git commit -m "feat: 'Save audio for debugging' setting (default on)"
```

---

## Task 9: Wire debug log + audio into the app (AppEnvironment, AppDelegate)

**Files:**
- Modify: `Sources/Lisper/AppEnvironment.swift`
- Modify: `Sources/Lisper/AppDelegate.swift`

App-target glue; verified by build + the manual smoke in Task 10.

- [ ] **Step 1: AppEnvironment — debug dirs, shared GuardLog/DebugLog, purge, wiring**

Add to `AppEnvironment` a debug directory helper and a `DebugLog`, and make `makePipeline()` build a fresh `GuardLog` per dictation, wiring it into both the engine and the pipeline. Replace `makePipeline()` and add helpers:

```swift
    /// ~/Library/Application Support/Lisper/debug
    func debugDir() -> URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lisper/debug", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func reportsDir() -> URL { debugDir().appendingPathComponent("reports", isDirectory: true) }

    private lazy var debugLog = DebugLog(fileURL: debugDir().appendingPathComponent("dictations.jsonl"))

    func makePipeline() -> DictationPipeline {
        let s = settingsStore.settings
        let apiKey = KeychainStore.loadAPIKey()
        let guardLog = GuardLog()

        var groqSTT: TranscriptionEngine? = nil
        var llm: CleanupEngine? = nil
        if let apiKey, !apiKey.isEmpty {
            let client = GroqClient(baseURL: s.groqBaseURL, apiKey: apiKey)
            groqSTT = GroqWhisperEngine(client: client, model: s.groqWhisperModel,
                                        language: s.transcriptionLanguage, guardLog: guardLog)
            if s.llmCleanupEnabled {
                llm = LLMCleanupEngine(client: client, model: s.groqChatModel)
            }
        }
        let apple = AppleSpeechEngine()
        let primary: TranscriptionEngine? = (s.sttEngine == .groq && groqSTT != nil) ? groqSTT : apple
        let fallback: TranscriptionEngine? = (s.sttEngine == .groq && groqSTT != nil) ? apple : nil
        return DictationPipeline(primarySTT: primary, fallbackSTT: fallback,
                                 llmCleanup: llm, ruleCleanup: RuleCleanupEngine(),
                                 database: database, debugLog: debugLog, guardLog: guardLog)
    }
```

Add the audio purge alongside the existing DB prune in `init()`:

```swift
        try? database.prune(retention: settingsStore.settings.retention)
        AudioStore.purgeExpired()
```

- [ ] **Step 2: AppDelegate — save audio after a successful outcome**

In `finishRecording()`, inside the `do` block right after `let outcome = try await pipeline.process(...)` and the `NotificationCenter` post, add (gated on the setting):

```swift
                if self.env.settingsStore.settings.saveAudioForDebugging, let sid = outcome.session.id {
                    AudioStore.save(audio, sessionId: sid)
                }
```

> `audio` is the `CapturedAudio` already in scope (captured by `recorder.stop()` earlier in the method). Saving happens off the paste path, so a write failure cannot affect insertion.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/Lisper/AppEnvironment.swift Sources/Lisper/AppDelegate.swift
git commit -m "feat: wire DebugLog + per-session audio capture into the app"
```

---

## Task 10: History UI — Extract audio + Report bad dictation

**Files:**
- Modify: `Sources/Lisper/UI/Main/MainViewModel.swift`
- Modify: `Sources/Lisper/UI/Main/HistoryView.swift`

App-target UI; verified by build + manual smoke.

- [ ] **Step 1: MainViewModel — backing actions**

Add to `MainViewModel`:

```swift
    /// Export a session's saved WAV via a save panel. Returns false if no audio.
    func extractAudio(_ s: SessionRecord) {
        guard let id = s.id, AudioStore.exists(sessionId: id) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "lisper-\(id).wav"
        panel.allowedContentTypes = [.wav]
        if panel.runModal() == .OK, let dest = panel.url {
            try? FileManager.default.copyItem(at: AudioStore.url(for: id), to: dest)
        }
    }

    func hasAudio(_ s: SessionRecord) -> Bool {
        guard let id = s.id else { return false }
        return AudioStore.exists(sessionId: id)
    }

    /// Build a report bundle from a session + the user's note. Returns the folder.
    @discardableResult
    func reportBadDictation(_ s: SessionRecord, note: String) -> URL? {
        guard let id = s.id else { return nil }
        let rec = DictationDebugRecord(
            timestamp: s.startedAt, sessionId: id, durationSeconds: s.durationSeconds,
            rms: 0, engineUsed: s.engineUsed, cleanupUsed: s.cleanupUsed,
            rawTranscript: s.rawTranscript, cleanedText: s.cleanedText,
            guardsFired: [], latencyMs: 0, error: nil)
        let st = env.settingsStore.settings
        let snapshot: [String: String] = [   // NEVER include the API key
            "dictionaryTerms": st.dictionaryTerms.joined(separator: ", "),
            "transcriptionLanguage": st.transcriptionLanguage,
            "groqWhisperModel": st.groqWhisperModel,
            "groqChatModel": st.groqChatModel,
            "styleMode": st.styleMode.rawValue,
            "sttEngine": st.sttEngine.rawValue,
        ]
        let audio = AudioStore.exists(sessionId: id) ? try? Data(contentsOf: AudioStore.url(for: id)) : nil
        return try? ReportWriter.write(into: env.reportsDir(), sessionId: id, record: rec,
                                       settingsSnapshot: snapshot, note: note, audio: audio ?? nil)
    }
```

> The record's `rms`/`guardsFired`/`latencyMs` aren't on `SessionRecord`; the richer values already live in `dictations.jsonl` keyed by `sessionId`. The report carries the durable session fields plus the note — enough for Claude to reproduce; the log fills in the rest. (Reading them back from the JSONL is a possible future refinement, out of scope here.)

Add `import AppKit` and `import UniformTypeIdentifiers` at the top of `MainViewModel.swift` if not already present (needed for `NSSavePanel` / `.wav`).

- [ ] **Step 2: HistoryView — buttons + note sheet**

Add state to `HomeView`:

```swift
    @State private var reporting: SessionRecord?
    @State private var noteText = ""
```

In `expandedDetails(_:)`, in the trailing `HStack` next to the copy/trash buttons, add:

```swift
                if model.hasAudio(session) {
                    Button { model.extractAudio(session) } label: { Image(systemName: "waveform") }
                        .buttonStyle(.plain).foregroundColor(Theme.textSecondary)
                        .help("Extract audio (.wav)")
                }
                Button { reporting = session; noteText = "" } label: { Image(systemName: "exclamationmark.bubble") }
                    .buttonStyle(.plain).foregroundColor(Theme.textSecondary)
                    .help("Report bad dictation")
```

Attach a sheet to the top-level view (e.g. on the outer `HStack` in `body`):

```swift
        .sheet(item: $reporting) { session in
            VStack(alignment: .leading, spacing: 14) {
                Text("Report bad dictation").font(.headline).foregroundColor(Theme.textPrimary)
                Text("What did you say, and what did it type?").sectionLabel()
                TextEditor(text: $noteText)
                    .frame(height: 90).font(.system(size: 13))
                HStack {
                    Spacer()
                    Button("Cancel") { reporting = nil }
                    Button("Save report") {
                        _ = model.reportBadDictation(session, note: noteText)
                        reporting = nil
                    }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20).frame(width: 420).background(Theme.canvas)
        }
```

> `SessionRecord` is already `Identifiable` (it has `id`), so `.sheet(item:)` works directly.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Manual smoke**

Run: `./scripts/run.sh`
- Dictate something real → confirm it pastes.
- Open the app → Home → expand the row → click the waveform icon → a save panel offers `lisper-<id>.wav`; save it and confirm the file plays.
- Click the report icon → type a note → Save report.
- Confirm `~/Library/Application Support/Lisper/debug/reports/<id>/report.json` exists and contains the note, and `audio.wav` is present.
- Confirm `~/Library/Application Support/Lisper/debug/dictations.jsonl` has a line for the dictation with `rms` and `guardsFired`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Lisper/UI/Main/MainViewModel.swift Sources/Lisper/UI/Main/HistoryView.swift
git commit -m "feat: History 'Extract audio' + 'Report bad dictation' actions"
```

---

## Task 11: Live replay harness (opt-in, env-gated)

**Files:**
- Create: `Tests/LisperKitTests/LiveReplayTests.swift`

A manual tool, not part of the offline suite. Default (no env) = skip instantly. To run for real:
`LISPER_LIVE=1 GROQ_API_KEY=gsk_... LISPER_REPLAY_DIR=/path/to/wavs swift run LisperKitTests`
It reads every `*.wav` in `LISPER_REPLAY_DIR`, sends each to Groq, and prints raw transcripts plus which guards fired — so a config change can be judged on real recordings.

- [ ] **Step 1: Implement the env-gated test**

```swift
import Testing
import Foundation
@testable import LisperKit

@Suite struct LiveReplayTests {
    @Test func testReplaySavedWavsThroughGroq() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LISPER_LIVE"] == "1",
              let key = env["GROQ_API_KEY"], !key.isEmpty,
              let dirPath = env["LISPER_REPLAY_DIR"] else {
            return // offline / not requested — skip silently
        }
        let dir = URL(fileURLWithPath: dirPath)
        let wavs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "wav" } ?? []
        #expect(!wavs.isEmpty, "no .wav files in LISPER_REPLAY_DIR")

        let client = GroqClient(baseURL: "https://api.groq.com/openai/v1", apiKey: key)
        for wav in wavs {
            let data = try Data(contentsOf: wav)
            let guardLog = GuardLog()
            let engine = GroqWhisperEngine(client: client, model: "whisper-large-v3-turbo",
                                           language: "en", guardLog: guardLog)
            let samples = WavEncoder.decodeToSamples(data) // see Step 2
            let audio = CapturedAudio(samples: samples)
            let text = (try? await engine.transcribe(audio: audio, dictionaryTerms: [])) ?? "<rejected>"
            print("REPLAY \(wav.lastPathComponent): guards=\(guardLog.all()) -> \(text)")
        }
    }
}
```

- [ ] **Step 2: Add a WAV→samples decoder to WavEncoder (needed by replay)**

In `Sources/LisperKit/Engines/WavEncoder.swift`, add a minimal inverse of `encode` (16-bit PCM mono → `[Float]`). Add tests in `WavEncoderTests` for an encode→decode round trip:

```swift
// In WavEncoder:
public static func decodeToSamples(_ wav: Data) -> [Float] {
    // Skip the 44-byte canonical header written by `encode`; interpret the rest
    // as little-endian Int16 and scale to -1...1.
    guard wav.count > 44 else { return [] }
    let body = wav.subdata(in: 44..<wav.count)
    var out = [Float](); out.reserveCapacity(body.count / 2)
    body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let count = raw.count / 2
        for i in 0..<count {
            let lo = UInt16(raw[i*2]); let hi = UInt16(raw[i*2 + 1])
            let s = Int16(bitPattern: lo | (hi << 8))
            out.append(Float(s) / 32_767.0)
        }
    }
    return out
}
```

```swift
// In WavEncoderTests:
@Test func testEncodeDecodeRoundTrip() {
    let samples: [Float] = [0, 0.5, -0.5, 0.25, -0.25]
    let wav = WavEncoder.encode(CapturedAudio(samples: samples))
    let back = WavEncoder.decodeToSamples(wav)
    #expect(back.count == samples.count)
    for (a, b) in zip(samples, back) { #expect(abs(a - b) < 0.001) }
}
```

> If `WavEncoder.encode` writes a header of a different size than 44 bytes, adjust the skip offset to match `encode`'s actual header length (read the file first).

- [ ] **Step 3: Run the suite (replay skips, round-trip passes)**

Run: `swift run LisperKitTests`
Expected: PASS — `LiveReplayTests` returns immediately (no `LISPER_LIVE`); `testEncodeDecodeRoundTrip` passes.

- [ ] **Step 4: Commit**

```bash
git add Tests/LisperKitTests/LiveReplayTests.swift Sources/LisperKit/Engines/WavEncoder.swift Tests/LisperKitTests/WavEncoderTests.swift
git commit -m "feat: opt-in live WAV-replay harness + WAV decoder"
```

---

## Task 12: Record the audio-on-disk deviation in docs

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/superpowers/specs/2026-06-12-lisper-design.md`

- [ ] **Step 1: Update CLAUDE.md**

In the "What this is" / pipeline description, change the "audio never touches disk" claim. Replace the relevant clause with:

```
audio is captured to memory; a copy is also persisted locally for debugging
(Application Support/Lisper/audio/<id>.wav, auto-purged after 7 days, never
leaves the machine, toggleable via Settings → "Save audio for debugging").
```

Also add a one-line pointer under the spec/plan list:
```
- **Debug loop:** `docs/superpowers/specs/2026-06-13-lisper-debug-loop-design.md`
```

- [ ] **Step 2: Update the original design doc**

In `docs/superpowers/specs/2026-06-12-lisper-design.md`, find the "audio never touches disk" statement and append a dated note:

```
> **Amended 2026-06-13:** audio is now persisted locally for debugging (7-day
> purge, never leaves the machine, toggleable). See the debug-loop design doc.
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md docs/superpowers/specs/2026-06-12-lisper-design.md
git commit -m "docs: record audio-on-disk deviation for the debug loop"
```

---

## Self-review notes (addressed)

- **Spec coverage:** Layer 1 → Tasks 1–5, 9. Layer 2 (audio + History actions + report) → Tasks 6, 7, 9, 10. Layer 3 → Task 11 (live replay) + the offline guard suites that already exist and grow per report. Settings toggle → Task 8. Privacy (no API key in reports) → Task 7 test + Task 10 snapshot. Deviation note → Task 12. 7-day purge → Tasks 6/9.
- **Type consistency:** `DictationDebugRecord`, `GuardLog`, `DebugLog`, `ReportWriter`, `AudioRetention`, `AudioStore`, and the `DictationOutcome` additions (`rms`, `guardsFired`) and `DictationPipeline` init params (`debugLog`, `guardLog`) are used identically across tasks. Guard-event names (`silence`, `sttFallback`, `cleanupFallback`, `hallucination`, `retry`, `vocabEcho`) are consistent between pipeline (Task 4) and engine (Task 5).
- **Known small gap (intentional, YAGNI):** the report built from a History row (Task 10) carries `rms=0`/`guardsFired=[]`/`latency=0` because those live in the JSONL keyed by `sessionId`; Claude reads the log alongside the report. Reading them back into the bundle is a noted future refinement.
```
