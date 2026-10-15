# Lisper — Dictation Quality Fixes Design

**Date:** 2026-06-29
**Status:** Approved (user approved design 2026-06-29)
**Goal:** Fix three user-reported defects — silently-lost recordings, an ineffective custom dictionary, and under-cleaned repetitive speech — and adopt an expert solo-founder git workflow. Each fix is grounded in on-disk evidence, not guesswork.

## Background / evidence

All three defects were diagnosed from the real on-disk logs (`~/Library/Application Support/Lisper/debug/dictations.jsonl`, `/tmp/lisper-hotkey.log`), not assumed. A research + adversarial-verification pass **refuted** an initial hypothesis (rewriting Fn detection to a CGEventTap), which the log evidence showed would not have helped — see §1.

## 1. Lost recordings — the Fn→Space "lock race"

### Symptom
"My 2 latest recordings just got canceled — I spoke for a whole minute and it disappeared, never showed up in the app."

### Root cause (confirmed)
The user's primary workflow is **press Fn → tap Space to lock (hands-free) → release Fn → speak**, not hold-to-talk. The two lost takes are in `dictations.jsonl` as `tooShort` with **0.0s duration / rms 0** — zero audio frames captured.

`AudioRecorder.start()` calls `engine.start()`, which **blocks the main thread ~100–300 ms** (AVAudioEngine cold start) and only sets `isRecording = true` after it returns. During that freeze the user's **Space-lock** (a `RecordingKeyTap` CGEventTap event) and **Fn-release** (an `NSEvent` flagsChanged) both queue on the main run loop, then run in **non-deterministic order**:

- Space-lock first → `lockRecording()` sets `recordingLocked = true` → the Fn-release is ignored → recording continues. ✓
- Fn-release first → `finishRecording()` stops the barely-started engine (≈0 samples) → `PipelineError.tooShort` → `pill.hide()` **silently**. The later Space-lock no-ops (`guard recorder.isRecording` fails). ✗ — the take vanishes.

### What was ruled out
- **Fn-hold detection is NOT broken.** An on-machine test produced four clean holds of 24.4s / 23.1s / 25.7s / 18.2s. The "73% of presses < 0.4s" in the historical log is the user *not holding* (they lock with Space).
- The earlier "phantom Fn release" family (foreign-modifier events, `.function` flicker) is fully handled by the existing `FnKeyDecision` OR-rule and is not the cause here.

### Fix
1. **Resolve the race in a pure, unit-tested LisperKit type** (same pattern as `FnKeyDecision`). A new `RecordingGesture`/lock-race resolver makes the outcome **order-independent**: a Fn-release that lands within a short *lock window* after the press is **deferred ~250 ms** instead of finishing immediately, giving a racing Space-lock time to win. A genuine long hold (release far from press) finishes immediately — no added latency. The lock registers even if its event arrives mid-cold-start.
2. **Never silently discard a take again.** A too-short / lost take shows a clear pill cue (e.g. *"Too short — tap Space to lock"*) instead of `pill.hide()` with no trace.
3. **Prove the diagnosis first:** a failing unit test reproduces the race deterministically (release-before-lock during start → take lost) before any fix lands.

### Testability boundary
The lock-race decision and the too-short-feedback decision are pure logic → live in `LisperKit`, unit-tested. `AppDelegate` only wires events/effects (an injected clock for the deferral timer).

### Out of scope (noted, not fixed now)
The ~100–300 ms cold-start also clips leading audio. A prewarm previously caused a launch-abort (see DEBUGGING-LOG); not revisited here.

## 2. Custom dictionary — "Jeriq" → "Jerry", "Claude" unknown

### Root cause (confirmed)
Dictionary terms DO reach the LLM cleanup (`AppEnvironment.cleanupContext()` → `CleanupContext.dictionaryTerms` → `CleanupPromptBuilder`). But the prompt only says *"always spell these exactly: …"* — which governs how to render a term the model **already chose to write**; it gives **no mandate** to replace a mis-heard homophone ("Jerry") with the intended term ("Jeriq"). Whisper no longer receives the vocabulary prompt (withheld in commit 97309fc to stop hallucinations), so neither layer corrects the homophone. Additionally, takes ≤ 4 words hit the **rule fast-path that skips the LLM entirely** (`CleanupRouter`), so a one-word "Jeriq" is never corrected.

### Fix (smart phonetic correction)
1. **Strengthen the dictionary section of the cleanup prompt** so the model *replaces* a transcript word that is phonetically close to a dictionary term with the dictionary spelling (e.g. "Jerry" → "Jeriq", "cloud/clawed" → "Claude"), in addition to spelling listed terms exactly. Keep meaning otherwise verbatim.
2. **Run the LLM cleanup even on short takes when the dictionary is non-empty.** Pipeline-level gate: `fastPath && context.dictionaryTerms.isEmpty`. `CleanupRouter.shouldUseRuleFastPath(raw:)` is unchanged (its tests stay green).
   - Trade-off (accepted by user): short takes incur ~1 extra LLM round-trip whenever a dictionary exists — correctness over latency.
3. No new data model or UI (explicit "misheard → correct" mappings were considered and deferred).

### Constraints preserved
`PromptBuilderTests` substrings must remain: `"Custom vocabulary"` section still gated on non-empty terms; the joined-terms assertion still holds; the verbatim-contract phrases untouched.

## 3. Repetition / redundancy not cleaned

### Symptom
Live example dictated by the user: *"I typically mainly, I don't really hold it, the FN key"* survived cleanup unchanged; the user wants it cleaned to *"I don't really hold the Fn key."*

### Root cause
The cleanup prompt is deliberately conservative (*"light cleanup, not a rewrite … Do not add, summarize, or embellish"*), recently tightened (commit 21d7946) to only delete listed fillers. It removes "um/uh" and false starts but leaves **repeated phrasing and restated clauses** intact.

### Fix
Widen the prompt to treat **repeated/restated phrasing and false-start redundancy as removable noise** (like fillers): when the speaker says the same thing twice or restarts a sentence, keep one clean instance — **without changing the surviving words, reordering, merging distinct ideas, or summarizing.** This stays inside the verbatim contract.

### Constraints preserved
`PromptBuilderTests` requires `"light cleanup, not a rewrite"`, `"Do not reorganize"`, `"never answer"`, `"original order"` to remain — the repetition instruction slots in alongside them, framed as noise-removal, not rewriting. New golden case added (the live example above). Coach stats remain computed on **raw** transcripts, so de-duplication never affects filler/WPM metrics.

## 4. Expert git workflow

### Decision: GitHub Flow (not a long-lived `dev` branch)
For a solo founder shipping a personal app with Claude Code, a `dev` branch is pure overhead (every change merged twice, no reviewer to justify it). Research-backed: short-lived topic branches → PR → `main`, squash/merge, tag releases.

### Concrete setup
- **`main`** is the only long-lived branch: always builds, always green. Protected (PR required, 0 required approvals so solo isn't locked out, required CI check, block force-push/deletion).
- **Short-lived branches** per concern: `feat/…`, `fix/…`, `docs/…`, `ci/…` → PR → squash or clean merge → delete.
- **CI** (`.github/workflows/ci.yml`, `runs-on: macos-15`): `swift build` + **`swift run LisperKitTests`** (NOT `swift test` — parity with local). Runs on every PR and on push to `main`.
- **Untangle current state:** fast-forward `main` to the 7 done commits on `feat/whisper-confidence-filtering`; land this session's work via its own branch/PR; give the unrelated transcript-export spec its own commit; delete the stale `fix/hotkey-prewarm-launch-abort`.
- Conventional Commits (already in use) → clean one-line-per-task history on `main` after squash.

All outward-facing steps (push, PR, merge, branch protection, deletion) are executed only with explicit user confirmation.

## Implementation order

1. Git base: properly-named work branch (done), CI workflow file.
2. Issue 1 — failing lock-race test → pure resolver → wire into `AppDelegate` → too-short feedback.
3. Issue 2 — phonetic-correction prompt + pipeline fast-path gate (tests first).
4. Issue 3 — repetition prompt widening + golden test.
5. Verify: full suite (`swift run LisperKitTests`) green; live verify the lock workflow.
6. Git reorg: un-stale `main`, PR(s), CI-on-PR, branch protection, cleanup — confirmed with user.
7. Remove temporary `/tmp` hotkey instrumentation once the fix is verified.

## Testing strategy

- `LisperKit` developed test-first per the project convention.
- New/updated suites: lock-race resolver tests; too-short-feedback decision; `PromptBuilderTests` (phonetic + repetition substrings); `CleanupRouter`/pipeline fast-path-with-dictionary; golden cleanup case for the live repetition example.
- Run the **full** suite via `swift run LisperKitTests` (no `--filter`; `swift test` is a no-op on this machine).
