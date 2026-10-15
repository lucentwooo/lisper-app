# Lisper Debugging & Continuous-Improvement Loop — Design

**Date:** 2026-06-13
**Status:** Approved (brainstorm), pending spec review

## Problem

Bad dictations (Whisper hallucination loops, prompt echoes, silence garbage)
will keep happening. Today they are invisible and unreproducible: audio lives
only in memory and is discarded, so by the time the user notices garbage there
is nothing left to debug. We want a system where every failure can be (a)
explained, (b) reproduced, and (c) permanently locked out by a regression test —
so the app gets monotonically better over time. This is *not* machine learning:
it is a growing corpus of real failures plus a test suite that ratchets.

## Decisions (from brainstorm)

1. **Audio is persisted to disk** per session so it can be extracted/replayed
   after the fact. This deliberately overrides the original spec rule "audio
   never touches disk" (`CLAUDE.md`, `docs/superpowers/specs/2026-06-12-lisper-design.md`).
   The user explicitly approved this; Wispr Flow does the same ("Extract audio").
2. **Audio retention: rolling 7-day purge.** Text history keeps its existing
   retention setting (forever / 90 / 30 days); audio is always purged after 7
   days regardless, to bound disk usage (~2 MB/min of 16 kHz mono WAV).
3. **Loop ownership = Option A.** The "Report bad dictation" action only
   *captures* a bundle. The user hands it to Claude, who turns it into a failing
   test and a fix. No in-app replay/corpus UI (that is a possible future
   Option B, explicitly out of scope here).

## Terminology

- **Whisper** — the OpenAI speech-to-text model called via Groq (transcription
  stage). Produces the *raw transcript*.
- **Lisper** — this app. Owns recording, the cleanup LLM step, the guards, and
  the paste. The *cleaned text* is Lisper's final output.

Pipeline:
```
voice → [Lisper records] → [Whisper → raw transcript] → [Lisper LLM cleanup → cleaned text] → [Lisper pastes]
```
A failure originates in exactly one stage; the debugging artifacts must reveal
which one.

## Architecture — three independent layers

### Layer 1 — Observability log

Every completed (or failed) dictation appends one JSON line to:
```
~/Library/Application Support/Lisper/debug/dictations.jsonl
```

One record per dictation:

| field | meaning |
|-------|---------|
| `timestamp` | ISO-8601 start time |
| `durationSeconds` | clip length |
| `rms` | mean loudness of the capture (0…1); distinguishes silence from speech |
| `engineUsed` | `groq` / `apple` |
| `cleanupUsed` | `llm` / `rules` |
| `rawTranscript` | Whisper output, pre-cleanup |
| `cleanedText` | what Lisper pasted |
| `guardsFired` | array of guard names that triggered, e.g. `["silence"]`, `["hallucination","retry"]`, `["vocabEcho"]` |
| `latencyMs` | end-to-end pipeline time |
| `error` | the thrown error description, if the dictation failed |
| `sessionId` | DB row id, links to the saved audio file |

**Purpose:** when something slips through, the log says *why* (e.g. "rms 0.03
cleared the silence gate; Whisper returned a loop; hallucination guard did not
fire — repeat count was 3, threshold is 4"). It is the diagnostic map that says
which knob to turn. The log is capped (rotate at ~5 MB / keep last N lines) so
it never grows unbounded.

This layer is purely additive and contains no audio.

### Layer 2 — Audio persistence + History actions

**Capture.** When the pipeline persists a `SessionRecord`, Lisper also writes
the captured audio as a WAV to:
```
~/Library/Application Support/Lisper/audio/<sessionId>.wav
```
Encoded with the existing `WavEncoder`. Failure to write audio must never fail
the dictation — paste-at-cursor is the contract; audio is best-effort.

**Purge.** On launch (and alongside the existing DB prune), delete any
`audio/*.wav` older than 7 days. Orphaned WAVs (no matching session) are also
removed.

**History UI.** Each History row gains a **⋯** menu with:
- **Extract audio** — export/save the WAV via a save panel (disabled/greyed if
  the audio has been purged).
- **Report bad dictation** — opens a tiny note prompt ("What did you say, and
  what did it type?"), then writes a *report bundle* (below).

**Report bundle.** Written to:
```
~/Library/Application Support/Lisper/debug/reports/<sessionId>/
    audio.wav        (copy of the session audio, if still present)
    report.json      (raw transcript, cleaned text, rms, duration, engine,
                      cleanup, guardsFired, full settings snapshot —
                      dictionaryTerms, language, models, styleMode — and the
                      user's note)
```
The settings snapshot must exclude the API key. The user's free-text note is
the one artifact the system cannot derive automatically and is the most
valuable input ("I said X, it typed Y" / "I said nothing but a video was
playing").

### Layer 3 — The regression ratchet (Claude-driven)

Two tiers of test, both living under `Tests/LisperKitTests/`:

- **Offline (the workhorse).** From a report's `rawTranscript`, add a
  deterministic, no-network test asserting Lisper's guards now handle it
  (e.g. `HallucinationGuard.isLikelyHallucination(thatText) == true`, or the
  cleanup produces the expected text). Runs in `swift run LisperKitTests`. Every
  reported bug adds at least one. This is what makes the suite ratchet.
- **Live replay (occasional, manual).** A harness that re-runs saved WAVs
  through the real Groq pipeline to verify a *config* change (language /
  temperature / prompt) genuinely improves real recordings. Requires network +
  API key, so it is opt-in and never part of the default test run. Shape: a
  small executable or a test gated behind an env var (e.g. `LISPER_LIVE=1`) that
  reads WAVs from a fixtures directory and prints before/after transcripts.

### The loop

```
bad dictation → ⋯ → Report bad dictation (+ one sentence)
   → user: "fix the latest report"
   → Claude: read bundle → write failing offline test → fix guard/config
            → (optionally) live-replay the WAV to confirm on real audio
            → commit
```
The suite only ever grows; fixed bugs cannot silently return.

## Component boundaries

- **`DebugLog` (LisperKit)** — pure-ish appender: initialised with an injected
  file URL (the app passes the real App Support path; tests pass a temp file),
  takes a record struct, writes a JSONL line, handles rotation. Depends only on
  Foundation. No hardcoded paths, no audio, no UI.
- **`DictationDebugRecord` (LisperKit)** — Codable struct = one log line / the
  technical half of a report. Built by the pipeline.
- **`AudioStore` (Lisper app side)** — writes/reads/purges `audio/<id>.wav`.
  Lives app-side because it touches the real filesystem location; thin wrapper
  over `WavEncoder`.
- **`ReportWriter` (LisperKit)** — given a record + note + (optional) wav bytes,
  assembles the report bundle directory. Testable against a temp dir.
- **History `⋯` menu (Lisper app side)** — SwiftUI; calls `AudioStore` and
  `ReportWriter`.
- **`DictationPipeline`** — extended to emit a `DictationDebugRecord` (it already
  computes raw, cleaned, engine, stats; add `rms` and `guardsFired`). The guard
  signals (`silence`, `hallucination`, `retry`, `vocabEcho`) must surface from
  the engine/pipeline rather than being inferred after the fact.

Logic (`DebugLog`, `ReportWriter`, record shapes, guard-signal plumbing) lives
in **LisperKit** and is unit-tested. Filesystem-location wiring and UI live in
**Lisper** (the app), matching the existing testability boundary.

## Data flow

```
DictationPipeline.process
  ├─ compute rms (AudioGate.rms), run guards, transcribe, clean, stats
  ├─ build DictationDebugRecord (incl. guardsFired, latency)
  ├─ DebugLog.append(record)            ← Layer 1
  ├─ database.save(session)             ← existing
  └─ AudioStore.save(audio, sessionId)  ← Layer 2 (best-effort, app side)

History ⋯ → Report:
  read session + AudioStore.load(id) + DebugLog/DB fields + user note
    → ReportWriter.write(bundle)        ← Layer 2
```

## Error handling

- Audio write / log write / report write are all **best-effort**: any failure is
  swallowed (optionally noted to the log) and never breaks dictation or paste.
- "Extract audio" / "Report" on a session whose WAV was purged: the action is
  disabled with a tooltip ("audio expired after 7 days"); a report can still be
  filed with text-only context.
- The settings snapshot in a report must never include the Groq API key.

## Testing

- `DebugLogTests` — append produces valid JSONL; rotation caps size; survives a
  missing directory (creates it).
- `ReportWriterTests` — bundle has expected files; `report.json` round-trips;
  API key is absent from the snapshot.
- `DictationDebugRecordTests` — Codable round-trip; `guardsFired` reflects the
  guard that ran (drive the pipeline with mocks that trigger silence /
  hallucination / vocab-echo and assert the recorded signal).
- Audio purge — given temp WAVs with old/new mtimes, only >7-day files are
  removed; orphans removed.
- Existing guard suites (`HallucinationGuardTests`, `AudioGateTests`,
  `VocabularyPromptTests`) are the seed of the offline corpus and keep growing.
- Live replay is **excluded** from `swift run LisperKitTests` (env-gated).

## Out of scope (YAGNI)

- In-app report browser / replay UI (Option B) — revisit only if the hand-off
  workflow proves too slow.
- Any automated parameter search / "self-tuning" — fixes are human/Claude
  decisions informed by the log and replay.
- Uploading reports anywhere. Everything stays on the user's machine.

## Spec deviation note

This feature intentionally amends the v0.1 rule "audio never touches disk."
`CLAUDE.md` and the original design doc should be updated to read: *audio is
persisted locally for debugging, purged after 7 days, never leaves the machine,
and can be disabled.* (A master "Save audio for debugging" toggle in Settings,
default on, is a reasonable addition during implementation.)
