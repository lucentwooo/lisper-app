# Lisper Debugging Log

Operational memory for debugging Lisper. This is **not** a changelog — git already records what
changed and why. This captures the things a diff *doesn't*: which symptoms mislead, the wrong turns,
and the fast path to the real cause. The goal is that the next weird bug takes minutes, not hours.

## How to use this (for Claude / future me)

- **Before debugging:** scan **Symptom → first suspects** and **Landmines** below. Several Lisper bugs
  masquerade as something else (a dead hotkey that looks exactly like a permissions problem). Check
  here before you start guessing.
- **After fixing a non-trivial bug:** add a dated entry using the **template** at the bottom. Keep a
  high bar — only bugs that were non-obvious, misleading, or time-consuming. Trivial one-line fixes
  belong in git, not here.
- Claude also mirrors the Claude-specific lessons into its private memory; this file is the shared,
  in-repo, human-readable copy.

## Symptom → first suspects

| Symptom | Check first |
|---|---|
| **Hotkey (Fn) does nothing**, app otherwise fine | **First: are you even running the build you just compiled?** `swift build` / `build.sh` rewrite `dist/` but **don't relaunch** — the old instance keeps running, so a fix you just made isn't live (`ps -o pid,lstart -p $(pgrep -x Lisper)` vs the binary's mtime; a process older than the binary = stale). Use `./scripts/run.sh` (pkill+rebuild+open). → [2026-06-14b](#2026-06-14--press-fn-nothing-happens-again--the-fix-wasnt-running). Then: did `applicationDidFinishLaunching` *finish* and `hotkey.configure()` actually run? A throw earlier in launch (audio-engine setup, etc.) silently aborts it **with no crash**. Instrument launch with a **file** log and confirm "monitors registered" *before* suspecting Accessibility. → [2026-06-14](#2026-06-14--press-fn-nothing-happens) |
| **Pill flashes for a split second** then vanishes; nothing recorded/in history | A **phantom release** fired right after the press → a ~0s recording discarded as `tooShort` → silent `pill.hide()`. For the **Fn** key the `.function` modifier flag is unreliable (clears mid-hold; unrelated modifier `flagsChanged` events also intrude). Trust `CGEventSource.keyState(key:63)`, and guard the keyCode. → [2026-06-14c](#2026-06-14--press-fn-pill-flashes-for-a-split-second-then-nothing) |
| **Recording "disappeared"** — spoke, nothing in the app, no error | Check `dictations.jsonl` FIRST (it logs **every** attempt incl. `tooShort`, with `durationSeconds`/`rms`). **duration 0.0 / rms 0 = empty capture**, not a transcription drop → look at start/stop *timing*, not Whisper. Prime suspect: the **Fn+Space lock race** — mic cold-start blocks the main thread ~100–300 ms, the Space-lock (CGEventTap) and Fn-release (NSEvent) queue and drain out of order; release-first ⇒ 0-sample take ⇒ silent `tooShort`. Fixed by `RecordingGesture`. → [2026-06-29](#2026-06-29--recordings-disappeared-spoke-a-minute-nothing-saved) |
| **Locked take "lost" — pressed Fn to confirm, NOTHING happened, and it's NOT in `dictations.jsonl` at all** | Distinct from the row above: **zero** log entry (not even `tooShort`) ⇒ `finishRecording()` never ran its pipeline (every pipeline path calls `emit()`). The stop press fell through `AppDelegate.onPress` to a **blocked `beginRecording()`** (`guard !recorder.isRecording`). Root cause: the stop test used the *derived* `recordingLocked` flag, which can desync from the *authoritative* `recorder.isRecording`. Fix: a press while `recorder.isRecording` ALWAYS finishes. → [2026-06-30](#2026-06-30--locked-take-lost-pressed-fn-to-confirm-nothing-no-log) |
| **Long take (10–90 s) discarded as "too short / silent"** after a thinking-pause (`error:tooShort`, `guardsFired:["silence"]`, `rms` ≈ 0.004–0.008) | `AudioGate.isLikelySilent` tested the **whole-clip MEAN** rms vs `silenceRMS` — a real sentence surrounded by a long pause averages *under* the floor and got dropped before the (peak-relative) VAD trimmer could isolate it. Fixed 2026-06-30 → window-count gate. → [2026-06-30b](#2026-06-30--too-short-on-a-real-sentence-after-a-thinking-pause). (NOT to be confused with a genuinely-dead input route — AVAudioEngine still has no config-change handler; if the *whole* take is truly near-silent incl. the speech, suspect that.) |
| **Transcript truncated / ends mid-sentence**, and/or real takes rejected as "too short" — both getting worse over weeks | Check **median `rms` by day** in `dictations.jsonl`. A steady decay (e.g. 0.023 → 0.004) = the **macOS input-volume slider** dropped, not an ASR problem. Any **absolute** RMS threshold then silently over-trims: the "peak-relative" VAD floor `max(silenceRMS, peak*0.1)` collapses to the constant and shears seconds of quiet speech off the edges. Confirm by **replaying the trimmer over the saved WAV** in `audio/<id>.wav`. → [2026-08-02](#2026-08-02--too-short-on-real-takes--transcripts-cut-off-mid-sentence) |
| **Chart spikes** shooting out of the plot area | Duplicate x values. Plotting one point per SESSION on a `unit: .day` axis puts several points on the same x, and `.catmullRom` interpolation through them overshoots violently. Aggregate to one point per day and use `.monotone` (which cannot overshoot). → [2026-08-02b](#2026-08-02--flow-score-trend-chart-spikes-out-of-the-plot-area) |
| **A take I cancelled (Esc) got transcribed and pasted anyway**, or one press produced two takes | A phantom **press** (not a release): the key was still physically held when ownership was dropped mid-hold (`noteSessionEnded()` → `clearOwner()`), so the next event read as a fresh press. `isARepeat` covers F13–F15 only — `flagsChanged` (Fn / right-⌘ / right-⌥) has no equivalent and needs `HotkeySetDecision.heldKeys`. Conversely, if a hotkey goes **permanently** dead, suspect a key stranded in `heldKeys` — the watchdog un-strands it from `CGEventSource.keyState`. → [2026-08-03](#2026-08-03--a-take-i-cancelled-with-esc-got-transcribed-and-pasted-anyway) |
| **Every take dies after ~0.5 s as "too short"** — but only on a hotkey you just switched to | The **watchdog** killed it, not a phantom release. `CGEventSource.keyState` does **not** report **Right ⌘ (54) / Right ⌥ (61)** as physically down at all, so a physical-state-only watchdog synthesises a release half a second in, every time. Look for `phys=false` on the **press** line in `/tmp/lisper-hotkey.log` — that's the tell. A watchdog must poll every down-signal `isDown` accepts (flag OR physical), not just one. → [2026-08-03b](#2026-08-03b--right--recordings-only-last-a-second-then-say-too-short) |
| **Hotkey does nothing AND Space stops typing anywhere** — only a relaunch fixes it; often right after AirPods/headphones connect or the mic changes | The input device switched while idle and the reused `AVAudioEngine` kept the old device's format → `installTap` raised an **Objective-C exception** (uncatchable in Swift) mid-`beginRecording`; AppKit swallowed it, leaving the Space/Esc tap armed with no take. Tell: `log show --last 7d --predicate 'process == "Lisper" AND eventMessage CONTAINS "Failed to create tap"'`. Repro: `scripts/repro/mic-device-switch/run.sh`. → [2026-10-10](#2026-10-10--hotkey-does-nothing-and-my-spacebar-stops-working-until-i-restart) |
| **Cleanup got dumb** — fillers like "you know" mangle sentences, dictionary/proper nouns ignored, no punctuation smarts — but nothing errors | The **LLM cleanup is failing and silently falling back to rules**. Check `cleanupUsed` by day: `sqlite3 ~/Library/Application\ Support/Lisper/lisper.sqlite "select substr(startedAt,1,10), cleanupUsed, count(*) from sessions group by 1,2"`. All `rules` = the LLM is dead; `cleanupError` in `dictations.jsonl` (since 2026-10-10) says why. First suspect: **Groq retired the chat model** (console.groq.com/docs/deprecations). → [2026-10-10b](#2026-10-10b--you-know-what-i-mean-comes-out-as-what-and-the-dictionary-does-nothing) |
| **Last phrase (or first words) missing**, clean room, no click — often a sentence that trails off after a loud start | The trimmer's `peak * 0.1` term: plosive bursts set the peak at ~0.22, so the bar (0.022) sat above a trailing-off sentence at ~0.008 that was still 16x the room tone. Fixed 2026-10-12 with a noise-floor-relative quiet-speech tier + 1.0 s trailing pad. **Prove it first:** cut the region the trimmer discards out of `audio/<id>.wav` and transcribe it locally (`whisper-cli`, model in `~/.cache/hyperframes/whisper/models/`) — words in the cut = trimmer bug. Words present in what was SENT but not in `rawTranscript` = large-v3 stopping early (`guardsFired` has `endingRecovered` when the turbo ending-check put them back; `endingCheckFailed` / `endingCheckTimedOut` when the check errored or was too slow; nothing when it was skipped — takes > 60 s, no check model, or the primary failed). → [2026-10-12](#2026-10-12--it-doesnt-pick-up-the-last-phrase-i-say) |
| **End of a take missing** (or a quiet take called "too short") and the clip had a **click / bump / pop** in it | The speech threshold was 10% of the clip's single loudest frame, so one 50 ms transient lifted it above real speech and the trimmer cut everything after the last frame that cleared it. Fixed 2026-10-10: `AudioGate.robustPeak` sets the loudest ~150 ms aside. Replay `audio/<id>.wav` frame RMS to confirm (a top frame 5-10x the next ones = transient). Commit `5addff0`. |
| Recording works but **text never pastes** | Accessibility (`AXIsProcessTrusted`) for the *current signed* binary; `TextInserter` synthetic ⌘V path; saved/restored pasteboard. |
| **Fn does nothing at all** (no pill, no sound) | `AXIsProcessTrusted()` is **false** — global monitors install but receive nothing. The System Settings toggle can read ON but be stale. Confirm at runtime (instrument launch); `tccutil reset Accessibility com.lucent.lisper`, relaunch, re-grant. Grants **do** survive rebuilds with the stable `Lisper Dev` cert. |
| **"All tests pass"** but nothing seems exercised | `swift test` executes **nothing** here (CLT-only, no XCTest). Use `swift run LisperKitTests` (full suite; no `--filter`). |
| **Mic / Accessibility lost after a rebuild** | Re-signed bundle → TCC grant goes stale even if the toggle still *looks* on. `tccutil reset <service> com.lucent.lisper`, relaunch, re-grant. |
| **Dates off by ~543 years**, or `log show` returns nothing | System calendar is Buddhist; pin `.gregorian`. `log show --last` + Swift `NSLog` are unreliable — use a file log (see Landmines). |
| Offline / no API key behaves wrong | Fallback chain must degrade, never error: Groq → Apple on-device → rule-based cleanup. |
| **Garbage / repeated junk at the END of an otherwise-good transcript** (e.g. "…futuristic FowlerAds, Lisper, Crap, Lid, Mace, Crap, Lid, Mace…") | A *localized trailing* Whisper hallucination on low-SNR audio — NOT caught by whole-clip guards. Check the report's `rms` (low = quiet tail) and whether the junk contains your **dictionary terms** (prompt echo). Fixed by `HallucinationGuard.exciseTrailingHallucination`. → [2026-06-14](#2026-06-14--random-crap-at-the-end-of-the-transcript) |
| **A take starts but nothing is ever saved, no error, no `dictations.jsonl` row** | Combo abort: a keyDown from a key other than the hotkey/Space/Esc silently abandons the take (`AppDelegate.abortRecording`, `RecordingAbortDecision`). Intended when the hotkey is a shortcut modifier like Left ⌃ — but it also means a stray keypress mid-dictation kills the take. **Only armed for an unlocked hold-mode take**: `lockRecording()` clears `onOtherKey` when a take goes hands-free, and toggle mode never arms it, so a vanished locked/toggle take is NOT this — look elsewhere. `/tmp/lisper-hotkey.log` logs `abortRecording` every time. |
| **Hotkey completely dead, and `/tmp/lisper-hotkey.log` shows NOTHING at all** (not even a `flags`/`transition` line — unlike every other "hotkey dead" cause above) | A Settings key-capture was left armed (`HotkeyCaptureController.isArmed`), which sets `HotkeyMonitor.isCapturing = true` and `handleFlags`/`handleKey` return before their trace line. Recovery: return to Settings → Hotkey — the "+ Add key" button still reads "Press a key… (Esc to cancel)" — and press **Esc**. Since finding #4 (2026-08-03 final review) this now also ends itself automatically when the app deactivates or the main window closes, so it should no longer strand the hotkey in practice. |

## Landmines (environment + codebase)

- **Audio-engine setup on the launch path can abort `didFinishLaunching`.** `AVAudioEngine.prepare()`
  on a bare engine threw and unwound the delegate method — AppKit swallowed the exception, so the app
  looked alive while everything after the throw (incl. hotkey registration) silently never ran. The
  main window still opened via `applicationDidBecomeActive`, masking it. Keep risky setup *after* the
  critical wiring, or off the launch path entirely.
- **`swift test` is a no-op** on this CLT-only machine — exits 0, runs nothing. Always
  `swift run LisperKitTests`.
- **Re-signed / rebuilt bundle drops TCC grants** (self-signed "Lisper Dev", `TeamIdentifier=not set`).
  The Accessibility/Mic row can read ON but be stale for the new code-hash.
- **Unified logging is unreliable for app diagnostics here:** Buddhist calendar breaks `log show --last`
  time windows, and Swift `NSLog("...\(x)...")` is stored as `<private>` (so `eventMessage CONTAINS`
  misses it). For ad-hoc debug logging, write to `/tmp/*.log` via `FileHandle` and `cat` it.
- **Run as `dist/Lisper.app`, never the bare `.build` binary** — TCC and Info.plist
  (`LSUIElement`, usage strings) only apply to the signed bundle.
- **Coach stats use raw (pre-cleanup) transcripts**; cleanup must preserve meaning verbatim. Don't
  "fix" a stats bug by reading cleaned text, or a cleanup bug by letting it add/answer content.

## Fix log

### 2026-06-14 — "press Fn, nothing happens"

- **Symptom:** Holding Fn did nothing — no recording pill, no error. App was running the latest build
  and had not crashed.
- **Root cause:** Perf commits `14eb22a` / `b588feb` added `recorder.prewarm()` (→ `AVAudioEngine.prepare()`
  on the bare engine) into `applicationDidFinishLaunching`, **before** `hotkey.configure()`. With the mic
  authorized, the `if microphoneGranted` guard fired, `prepare()` aborted the method, and the global Fn
  `NSEvent` monitors were never registered. No crash (AppKit caught the exception); the main window still
  opened via `applicationDidBecomeActive`, so the app looked healthy.
- **Red herring (wasted a cycle):** The symptom is identical to missing Accessibility — global monitors
  "silently receive nothing" without AX trust. I reset and re-granted TCC. Pointless: `AXIsProcessTrusted`
  *and* mic were both already granted. The masked launch-abort just looked like a permissions issue.
- **Diagnosis that worked:** File-logged `AXIsProcessTrusted()` + mic state at launch, a "monitors
  registered" line, and bracketed the suspect call (`before prewarm` / `after prewarm`). The log showed
  `before prewarm` with no `after prewarm` → fault localized to that single line.
- **Fix:** Removed the `prewarm()` optimization entirely (the `AudioRecorder.prewarm()` method and all four
  call sites). Back to AVAudioEngine cold-start — the ~100–300 ms leading clip returns, but dictation works.
  121 tests pass. (Reviving the optimization later requires runtime verification *and* keeping it off the
  pre-hotkey-registration launch path.)
- **Lesson:** When a hotkey is dead, **first confirm the listener was actually installed** (instrument
  launch completion) before blaming permissions. A throwing call early in `didFinishLaunching` is
  invisible: no crash, and the window still appears.

### 2026-06-14 — "press Fn, nothing happens" (again — the fix wasn't running)

- **Symptom:** Same as the entry above — holding Fn did nothing — reported as a **recurrence** ("we
  already had this issue, why is it recurring") *after* the prewarm launch-abort had been fixed.
- **Root cause:** Not a code regression. The fix was committed (`cead101` + prewarm removal, 10:36) and
  even rebuilt into `dist/` (binary mtime 11:51), but the **running process had been launched at 10:18**
  — i.e. from pre-fix code (`≤ b588feb`, which still had the prewarm-on-launch abort). `swift build` /
  `build.sh` recompile the bundle in place but **do not kill+relaunch**; only `run.sh` does. So the user
  kept holding Fn against the stale, still-buggy instance while the fixed binary sat unused on disk.
- **Red herring:** "It's recurring" → assume the bug came back / the fix was wrong / chase prewarm or
  Accessibility again. The code was already correct (`grep -r prewarm Sources` = empty; `hotkey.configure()`
  unconditional at `AppDelegate:46`, before any throwing call). The defect was purely *which binary is live*.
- **Diagnosis that worked:** `ps -o pid,lstart,etime -p $(pgrep -x Lisper)` → process **start time
  (10:18) was older than the on-disk binary's mtime (11:51)**. A process can't be running a binary that
  was written after it started ⇒ the fix was never launched. (`git log --date=format:%H:%M` then placed
  the fix commit at 10:36, between the two.) No source instrumentation needed.
- **Fix:** `./scripts/run.sh` — pkill the stale instance, rebuild, `open dist/Lisper.app`. Verified a
  single fresh instance whose start time matches the new binary mtime.
- **Caveat (next link in the chain):** relaunching a **re-signed** self-signed bundle ("Lisper Dev",
  `TeamIdentifier=not set`) can drop the Accessibility TCC grant (Landmine #3). If Fn is *still* dead on
  the fresh instance, that's the genuine-permissions case — re-grant Accessibility (`tccutil reset
  Accessibility com.lucent.lisper`, relaunch, re-grant). The stable `make-cert.sh` cert exists to make
  grants survive rebuilds, so this should be rare.
- **Lesson:** When a *fixed* bug "comes back," **prove which binary is live before re-debugging the code**
  — compare process `lstart` to the binary mtime. On this project, "I rebuilt" ≠ "it's running": `swift
  build`/`build.sh` don't relaunch. Reach for `run.sh`.

### 2026-06-14 — "press Fn, pill flashes for a split second, then nothing"

- **Symptom:** Holding Fn briefly flashed the pill (sometimes too fast to see), then it vanished —
  no audio recorded, nothing in history. Reported as *still* "Fn not working" after the stale-instance
  and Accessibility causes above were already fixed.
- **Root cause:** `HotkeyMonitor.handleFlags` `.fn` case trusted the `.function` modifier flag and —
  unlike the `.rightCommand`/`.rightOption` cases — had **no `keyCode == 63` guard**. The Globe/Fn key
  emits unreliable `flagsChanged` events: unrelated modifier changes (other keyCodes) and spurious
  `.function` clears *while the key is still physically held*. Each produced a phantom
  `transition(down: false)` immediately after the press → a 0.0s recording → `PipelineError.tooShort`
  → silent `pill.hide()`. The physical key state (`CGEventSource.keyState(.combinedSessionState, key: 63)`)
  read `true` throughout the hold — that was the tell.
- **Red herring:** Identical symptom to the two *other* "Fn dead" causes already fixed this day (stale
  running build; `AXIsProcessTrusted=false`). Easy to assume "the fix regressed." It didn't — this was a
  **third, independent** cause. Also: `tooShort` hides the pill *silently* (correct for a real <0.4s tap,
  invisible for a phantom), so the failure left no UI trace.
- **Diagnosis that worked:** file-logged the whole press→record→release lifecycle — `transition` down-state,
  and per fn `flagsChanged` the `keyCode/flag/physical` triple, plus recording duration and `tooShort`.
  The log showed `down=true` immediately followed by `down=false` while `watchdog … physicalKeyState=true`
  (phantom release while physically held). Real holds showed only watchdog ticks between press and a
  genuine `flag=false physical=false` release (durations 2.99s / 3.79s).
- **Fix:** extracted the decision into pure, testable `LisperKit/Input/FnKeyDecision` — *ignore any event
  whose keyCode isn't the Fn key*, and treat the key as down on `functionFlagSet || physicallyDown`; the
  watchdog backstops a missed release. `FnKeyDecisionTests` locks the invariants (unrelated modifier →
  ignored; flag-clear-while-held → still down; real release → up). Wired into `HotkeyMonitor.handleFlags`.
  133 tests pass.
- **Lesson:** **"Fn does nothing" is one symptom with ≥4 independent root causes** seen so far —
  (1) launch-abort before `hotkey.configure()`, (2) stale running build, (3) `AXIsProcessTrusted=false`,
  (4) phantom Fn flag release. A "recurrence" is usually a *different* cause; re-diagnose, don't assume.
  For the Fn key specifically the `.function` flag lies — `CGEventSource.keyState(key:63)` is authoritative,
  and guard the keyCode like the other modifier hotkeys already do.

### 2026-06-14 — "random crap at the end of the transcript"

- **Symptom:** A long dictation transcribed correctly, then the **end** was wrong: the real closing
  sentence was missing and replaced by junk — `…but also futuristic FowlerAds, Lisper, Crap, Lid, Mace,
  Crap, Lid, Mace, Crap, Lid, Mace.` (reported in-app via "Report bad dictation", session 205). User:
  "this has happened on multiple occasions."
- **Root cause:** On low-SNR audio (report `rms` ≈ 0.018, a quiet trailing-off voice) Whisper lost the
  real tail and emitted a **localized trailing hallucination burst** = a **vocabulary-prompt echo**
  (`BetterYourAds`→"FowlerAds", `Lisper` — both dictionary terms passed as Whisper's `prompt`, which it
  regurgitates on low confidence) **followed by a degenerate repetition loop** (`Crap, Lid, Mace`×). All
  three existing guards missed it: `isLikelyHallucination` keys on *whole-clip* coverage (good speech
  dominated → stayed false → no temperature retry, no discard); `collapseRepetitionLoops` only trimmed
  the loop to **one copy**, so `FowlerAds, Lisper, Crap, Lid, Mace` was still pasted; `isVocabularyEcho`
  requires the *entire* transcript to be vocab. **No guard existed for a localized garbage clause
  appended to good speech.**
- **Red herring:** The in-app dialog is named "Report bad **dictation**" — easy to mistake the bug for a
  defect in the *reporting feature*. It's not; the report is the evidence. Also: the loop *looked* like a
  `collapseRepetitionLoops` bug (the guard fired yet ×3 survived), but empirically that function collapses
  a clean ×3 correctly — collapsing-to-one was simply never sufficient for this failure mode.
- **Diagnosis that worked:** Read the saved report at
  `~/Library/Application Support/Lisper/debug/reports/<sessionId>/report.json` (has `rawTranscript`,
  `rms`, `guardsFired`, settings incl. dictionary). Then **reproduced in a unit test** by running
  `HallucinationGuard.collapseRepetitionLoops` / `isLikelyHallucination` on the verbatim transcript via
  `swift run LisperKitTests` — output proved the loop collapsed to one copy and the vocab-echo lead-in
  survived, i.e. the gap was a *missing* guard, not a broken one.
- **Fix:** Added `HallucinationGuard.exciseTrailingHallucination(_:dictionaryTerms:)` — excises a
  trailing back-to-back loop (any period, anchored at the end) **entirely** when it carries a
  hallucination signature (≥4 reps, OR a dictionary-term echo inside it, OR all fragments are capitalised
  single words), then walks back over the burst lead-in (capitalised single-word fragments / dict-term
  echoes). Conservative by design: real lowercase emphasis ("ship it ship it ship it", ≤3×) and
  proper-noun endings are left to the gentler collapse pass, and it never deletes the whole transcript.
  Wired into `DictationPipeline` **before** `collapseRepetitionLoops` (collapse would erase the
  repetition signature first). Also dropped the vocabulary `prompt` on the engine's temperature-retry
  (re-sending it just feeds the same echo). Commits touch `HallucinationGuard.swift`,
  `DictationPipeline.swift`, `GroqEngines.swift`; 128 tests pass.
- **Lesson:** Whisper hallucinations aren't only *whole-clip* — a good long take can have a garbage
  **tail** that every coverage-based guard ignores. When junk appears only at the **end**, suspect a
  localized trailing burst and check whether it echoes the **dictionary** (the `prompt` is the fuel).
  Coverage thresholds protect long rambles (sessions 157/165/171) but are blind to localized bursts;
  you need a separate end-anchored excision.

### 2026-06-29 — recordings "disappeared" (spoke a minute, nothing saved)

- **Symptom:** Two takes vanished — never appeared in the app, no error. User: "I spoke for like a whole minute and it just disappeared."
- **Root cause:** NOT Fn-hold reliability. The user's primary flow is press Fn → tap **Space to LOCK** (hands-free) → release Fn → speak. Pressing Fn cold-starts `AVAudioEngine`, which blocks the main thread ~100–300 ms (`isRecording` flips true only *after* `engine.start()` returns). The Space-lock (a `RecordingKeyTap` CGEventTap event) and the Fn-release (an `NSEvent` flagsChanged) both **queue** during that freeze and are drained in **nondeterministic order**. Release-first ⇒ `finishRecording()` stops the barely-started engine (0 samples) ⇒ `PipelineError.tooShort` ⇒ `pill.hide()` **silently**; the later Space-lock no-ops (`guard recorder.isRecording` is false). The two lost takes were in `dictations.jsonl` at **duration 0.0 s / rms 0** — the tell (engine never captured a frame).
- **Red herring (cost a full investigation cycle):** the hotkey log showed **73% of Fn presses < 0.4 s**, which looked like an Fn-hold phantom-release bug; the obvious "fix" was to rewrite Fn detection onto a CGEventTap reading `maskSecondaryFn`. An **adversarial review of the real log refuted it**: every release had `flag=false` AND `keyState(63)=false` (a genuine-release signature), `keyState` was reliable across 18–44 s holds, and `maskSecondaryFn` **is the same bit** as `.function` — the swap changes nothing. The 73% was just the user **not holding** (they lock with Space). Extends the 2026-06-14 lesson: confirm **which gesture the user actually performs** before theorizing about the key.
- **Diagnosis that worked:** (1) read `dictations.jsonl` — lost takes were duration 0.0 / rms 0, i.e. captured no audio (not a transcription drop); (2) an on-machine firm-hold test produced clean 18–26 s holds → Fn detection is fine; (3) the user clarified the Fn+Space-lock workflow → the AppDelegate cold-start ordering race became obvious in the code.
- **Fix:** `RecordingGesture` (pure, unit-tested, `Sources/LisperKit/Input/`) resolves the race order-independently — a release within a 0.5 s lock window after the press **defers** ~0.3 s so a racing Space-lock wins; a genuine hold finishes immediately. Wired into `AppDelegate` with a cancellable deferred-finish; `lockRecording()` cancels it. The `tooShort` path now shows a pill cue instead of `pill.hide()` — **no take ever vanishes silently again**. Also fixed a latent landmine surfaced en route: `swift run LisperKitTests` had silently broken when Xcode became the active toolchain (empty CLT `Testing.framework`) — `Package.swift` now resolves the framework dynamically. (commits `1469784`, `6512dde`; PR #1)
- **Lesson:** "It disappeared" from a dictation app ⇒ check `dictations.jsonl` FIRST — **duration 0.0 / rms 0 means an empty capture**, so look UPSTREAM at start/stop timing, never at transcription. And when a fix touches a key with a long bug history (Fn), **adversarially refute the obvious theory against real logs before coding** — it killed a wrong 5th Fn patch here.

### 2026-06-30 — locked take "lost": pressed Fn to confirm, nothing, no log

- **Symptom:** Hands-free flow (Fn → Space-lock → release → speak). Spoke a full take, pressed **Fn to
  confirm/stop** — **nothing happened**, the whole transcription was lost, and **it never appeared in
  `dictations.jsonl`** (not even a `tooShort`). "This should NEVER happen." Intermittent; the app was
  recording fine before and after (long 62 s / 79 s locked takes logged minutes later).
- **Root cause:** `AppDelegate.onPress` decided whether to *stop* a take with
  `if recordingLocked, recorder.isRecording { finish } else { beginRecording() }`. The stop hinged on
  the **derived** `recordingLocked` flag instead of the **authoritative** `recorder.isRecording`. There
  are *three* sources of truth for "is a hands-free take in flight" — `recorder.isRecording`,
  AppDelegate's `recordingLocked`, and `RecordingGesture.locked` — and under the Fn/Space cold-start
  event races (the same class `RecordingGesture` was built for) they can diverge. In the state
  `isRecording == true` **but** `recordingLocked == false`, the confirming press skipped the finish
  branch, fell through to `beginRecording()`, hit `guard !recorder.isRecording`, and **silently
  returned** — so the take was never stopped, transcribed, saved, *or* logged. Because **every**
  `DictationPipeline.process` path (incl. all guards) calls `emit()`, a finished take is impossible to
  lose silently; "no log at all" is the fingerprint that `finishRecording()` never ran.
- **Red herring:** "Fn did nothing" ⇒ the usual Fn-hotkey suspects (stale build / AX-trust / phantom
  Fn-flag release / `keyIsDown` stuck). All refuted here: (1) `ps lstart` == binary mtime (fresh build);
  (2) a **week** of leftover `/tmp/lisper-hotkey.log` Fn traces showed the `keyIsDown` machine
  *recovering from flag-flicker every time* — releases always registered, no stuck-down. The defect was
  one layer up, in the AppDelegate press/stop decision, not in key detection.
- **Diagnosis that worked:** `dictations.jsonl` had the prior takes but **nothing** for the lost one →
  `finishRecording` never reached the pipeline. Code-reading `onPress` against that constraint left
  exactly one reachable no-log path: `isRecording == true && recordingLocked == false` →
  `beginRecording()` blocked by its own guard. (The week-old HotkeyMonitor trace ruled out the
  key-detection layer; the exact race that *sets* the desync is still being captured by fresh
  AppDelegate-side instrumentation in `HotkeyTrace`.)
- **Fix:** `onPress` now finishes on the authoritative signal — `if recorder.isRecording { finish }` —
  so a press during **any** active take always stops + transcribes + saves + logs it, regardless of how
  `recordingLocked`/`gesture.locked` ended up. Safe in both modes: in hold mode `HotkeyMonitor` dedups a
  held key, so `onPress` can only fire mid-recording when the key was released and pressed again — which
  is unambiguously a "stop". 184 tests pass. Temporary `HotkeyTrace` instrumentation
  (`/tmp/lisper-hotkey.log`) left in to confirm the trigger in the wild, then remove.
- **Lesson:** For a *don't-lose-the-user's-data* decision, branch on the **authoritative** state
  (`recorder.isRecording`), never a **derived** mirror flag that a race can desync. And "no entry in
  `dictations.jsonl` at all" (vs a `tooShort` entry) is the precise tell that the **pipeline never
  ran** — look at the press/stop dispatch in `AppDelegate`, not at capture or transcription.

### 2026-06-30 — "too short, try again" on a real sentence after a thinking-pause

- **Symptom:** Thought for ~19 s, then said one sentence; pill showed **"Too short — try again"** and the
  take was dropped. "These issues should never happen."
- **Root cause:** `AudioGate.isLikelySilent` gated on the **whole-clip MEAN** RMS (`rms(samples) <
  silenceRMS=0.008`). A short utterance diluted by a long leading/trailing pause has a mean dragged
  *under* the floor (the failed take: 20.4 s, mean rms **0.007**, `guardsFired:["silence"]`) even though
  the speech itself is plainly loud. Worse, this whole-clip gate runs in `DictationPipeline` **before**
  the `EnergyVoiceActivityTrimmer` — which is peak-relative and would have isolated the sentence — so the
  smart trimmer never got the chance. The mean conflates "quiet" with "short relative to total duration".
- **Red herring:** looks identical to a genuinely-silent capture / dead input route. It isn't — the take
  *was* logged (silence-gate discards log a `tooShort` with `rms`+`guardsFired`), and `rms 0.007` with a
  real sentence is the dilution signature, not a dead mic. (A truly dead route shows the *speech portion*
  near-zero too.)
- **Diagnosis that worked:** the discard **is** in `dictations.jsonl` (unlike the stop-path bug) →
  read the failing record directly: `guardsFired:["silence"]` named the exact guard; `durationSeconds
  20.4 / rms 0.007` showed mean-below-floor on a long clip = dilution. Cross-checked against 12 prior
  identical discards (one a **94 s** take) — same low-mean band.
- **Fix:** `AudioGate.isLikelySilent` now counts **speech-level ~30 ms windows** and gates only if fewer
  than `minSpeechWindows` (3, ~90 ms) reach `silenceRMS` — a window-energy test, not a whole-clip mean.
  Speech windows stay above the floor no matter how much silence surrounds them, and requiring several
  also keeps a lone transient (keyboard click) from passing (a single loud pop reads high in one window
  but can't make three). New `AudioGateTests`: leading-silence, trailing-silence, and isolated-click
  cases; the leading-silence test also asserts the mean really is sub-floor (so it's a true regression
  catch). 187 tests pass.
- **Lesson:** For "is there speech here?", measure the **loudest sustained segment**, never the
  whole-clip average — averages punish exactly the pause-then-speak rhythm dictation invites. And put the
  cheap gate and the smart trimmer in the right order, or the gate vetoes the take before the trimmer can
  save it.

### 2026-08-02 — "too short" on real takes + transcripts cut off mid-sentence

- **Symptom:** Two bugs reported together: real speech rejected as "too short — try again", and
  transcripts truncated / ending mid-phrase. Intermittent, not reproducible on demand.
- **Root cause (ONE cause, two symptoms):** every speech/silence decision thresholded on the
  **absolute** constant `AudioGate.silenceRMS = 0.008`, which silently encoded the input gain the app
  was calibrated at (median capture RMS ~0.023). The **macOS input-volume slider had drifted to 39%**,
  so speech now lands at RMS ~0.005 — *at or below the constant*. Both symptoms follow:
  1. `AudioGate.isLikelySilent` needs 3 windows ≥ 0.008; quiet takes clear none → false `tooShort`.
  2. `EnergyVoiceActivityTrimmer` used `max(silenceRMS, peak * 0.1)`. At peak 0.0162 the peak-relative
     term is only **0.0016**, so the absolute floor **dominated** and the "peak-relative" trimmer became
     a fixed gate at *half the speech level* — shearing quiet speech off both edges.
- **Diagnosis that worked:** `dictations.jsonl` median RMS **by day** showed a clean 5x decay
  (0.023 late June → 0.004 by Aug), and the `tooShort` clusters landed exactly on the lowest days
  (07-17: median 0.0036, 6 fails; 08-01: median 0.0036, 3 fails). Then the decisive step: **replaying the
  real trimmer algorithm in Python over the saved WAVs**. On session 1216 (64.7 s) only **4.4% of frames**
  cleared the threshold and it discarded **3.59 s of trailing speech** (73 frames of real speech in the cut
  tail, peaking 0.0077 — just under 0.008) — which is precisely why that transcript ends mid-phrase
  ("…you're you're doing"). The audio itself was complete to 64.0 s, proving the loss was downstream of
  capture. Measuring peak/noise-floor across 12 real takes gave **11x–1180x** separation even for 1.1 s
  single-word clips, proving an SNR-relative threshold is safe with wide margin.
- **Red herring:** looks like a dead input route or a Whisper/ASR quality problem. It is neither — the
  WAVs contain full-level speech end to end, and Whisper only ever received the *pre-truncated* clip.
- **Fix:** threshold is now derived from **each clip's own noise floor**, shared by the gate and the
  trimmer via `AudioGate.speechThreshold`:
  `max(peak*0.1, min(noiseFloor(p10)*3, peak*0.5))`, with `nil` (→ silence) when `peak < 0.004`.
  The cap keeps a *uniformly*-speech clip from thresholding itself out of existence; the `minSpeechPeak`
  backstop is load-bearing for pure room tone, where noise ≈ peak makes SNR alone indecisive.
  Replayed over the 12 most recent real takes, **every one recovers speech** (+0.17 s to +3.38 s); short
  takes (1211/1212) had been losing over *half* their audio. 189 tests pass.
- **Also fixed en route (build landmine, 3rd variant):** `swift run LisperKitTests` failed to compile with
  `no such module '_Testing_Foundation'`. Xcode has since been **uninstalled** (CLT-only again), and this
  CLT's `Testing.framework` declares a **cross-import overlay** (`Testing.swiftcrossimport`) auto-loaded
  whenever a file imports both `Testing` and `Foundation` — but `_Testing_Foundation.framework` ships with
  **no `Modules/` dir**, so it cannot be loaded. Fixed with `-Xfrontend -disable-cross-import-overlays`
  on the test target. (Note: `Package.swift`'s framework resolver was already correct — it fell through to
  CLT — so the usual "wrong toolchain" theory was wrong here.)
- **Lesson:** An **absolute** audio threshold is a latent time bomb — it hard-codes one input gain, and a
  slider the app doesn't control invalidates it silently, months later, as *two unrelated-looking* bugs.
  Gate on **ratios to the signal's own noise floor**, never on absolute levels. And when logs suggest a
  threshold bug, **replay the real algorithm over the saved WAVs** — it converts a plausible theory into a
  measured "3.59 s of speech deleted here".

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

### 2026-08-03 — a take I cancelled with Esc got transcribed and pasted anyway

- **Symptom:** hold the hotkey, speak, hit **Esc to cancel**, keep the key down a beat longer — the
  cancelled audio is transcribed and pasted at the cursor. A milder variant on the hands-free flow:
  the confirming stop press ends the locked take, and a lingering finger immediately starts another.
  Found by review on `feat/simplify-and-multikey`, before it reached the user.
- **Root cause:** the mirror image of every previous hotkey bug — a phantom **press**, not a phantom
  release. The multi-key rewrite replaced `HotkeyMonitor`'s `keyIsDown` flag with
  `HotkeySetDecision`'s *ownership*, and made `noteSessionEnded()` call `clearOwner()`. But the two
  answer different questions. The old flag answered "is this key already down?" and stayed `true`
  through a cancel, swallowing every subsequent event from the same physical hold. Ownership answers
  "whose take is this?" and is deliberately dropped mid-hold by an Esc cancel — so with `owner == nil`
  and the key still physically held, the very next event read as a brand-new press: `beginRecording()`
  succeeded (nothing blocks it — `processing` is false after a cancel) and the real release finished
  and pasted the take the user had just thrown away. Same hole cost toggle mode its key-repeat dedup
  (the old branch had an explicit `guard !keyIsDown`).
- **Red herring:** `guard !event.isARepeat else { return }` (commit `a6fdc0f`) looks like the whole fix,
  and for **F13–F15** it is. But `flagsChanged` has no `isARepeat` equivalent, so it does nothing for
  **Fn / right-⌘ / right-⌥** — and those are the default hotkeys. Worse, Fn is precisely the key
  documented (2026-06-14c) to emit spurious `.function` events *while still physically held*, which
  `HotkeySetDecision.isDown` correctly maps to `down` — so the modifier path was not just uncovered,
  it was the one actively generating the extra edges.
- **Diagnosis that worked:** reading the state machine against the *cancel* path rather than the happy
  path. Ownership is cleared at three sites (`noteSessionEnded`, `stop`, toggle's press edge); at each,
  ask "can the key still be physically down here?" — for two of the three the answer is yes, and
  `press()` had nothing left to dedup with.
- **Fix:** split the two concepts back apart in `LisperKit/Input/HotkeySetDecision.swift`. `heldKeys:
  Set<UInt16>` tracks physical down-state independently of `owner`; `press()` returns no edge for a key
  already in it (checked *before* the ownership guard), `release()` removes it *unconditionally* (even
  for a non-owner), and `clearOwner()` deliberately leaves it alone. The `isARepeat` guard stays as the
  cheap F-key filter. **Counter-risk, and the load-bearing half of the fix:** a key stranded in
  `heldKeys` would blockade that hotkey permanently — strictly worse than the bug. So `stop()` calls a
  new `reset()` (monitors are gone, key-ups can be missed, held-state is untrustworthy), and
  `HotkeyMonitor`'s watchdog now runs whenever **any** key is held rather than only while a take is
  owned, synthesising a release for any held key that `CGEventSource.keyState` reports up. 189 tests.
- **Lesson:** **dedup state and ownership state answer different questions** — "is this key already
  down?" vs "whose take is this?" — and they have different lifetimes: the first ends when the user's
  finger lifts, the second when the take ends, and a cancel separates them. Collapsing them into one
  flag is what opened the hole. Also: this app's hotkey bugs are not all phantom *releases* any more —
  when auditing key state, walk the cancel path, and check whether a guard that fixes the F-keys
  (`isARepeat`) has any counterpart on the `flagsChanged` path. And any "ignore this key" state needs a
  physical-state backstop, or you have traded a wrong take for a dead hotkey.

### 2026-08-03b — Right ⌘ recordings only last a second, then say "too short"

- **Symptom:** after switching the hotkey away from Fn, holding it records for about a second, the
  pill vanishes and the take is discarded as `tooShort`. Fn itself still worked fine.
- **Root cause:** **`CGEventSource.keyState(.combinedSessionState, key: 54)` never returns true for
  Right ⌘ on this hardware** — not while it is held, not ever. The watchdog added the same day
  (2026-08-03) polls exactly that signal for every key in `heldKeys` and synthesises a release when
  it reads up, so 0.5 s into every Right-⌘ take it manufactured the release itself. `recorder.stop`
  duly returned `duration=0.489s` — the watchdog interval, which is why the number was *identical*
  on every attempt. Fn is unaffected because its physical state does read correctly (it is the
  `.function` *flag* that lies for Fn — the exact opposite failure).
- **Red herring:** everything about it looks like the phantom-release family (pill flashes,
  `tooShort`), which points at `flagsChanged` and `HotkeySetDecision.isDown`. Both were innocent:
  the trace shows the genuine release arriving ~0.7 s *after* the take had already been ended, and
  the press/release edge logic was correct throughout. The killer was the *recovery* mechanism.
  Also worth noting the previous entry's fix caused this one — widening the watchdog from
  "while a take is owned" to "while any key is held" is what let it fire mid-take.
- **Diagnosis that worked:** `/tmp/lisper-hotkey.log` alone, no new instrumentation. The press line
  already prints both signals: `flags key=rightCommand code=54 flag=true phys=false -> down=true`.
  A key that is `phys=false` *at the moment the user presses it* can never be watchdog-polled — and
  the very next line is the synthetic release. Comparing against the Fn lines (`phys=true`) isolated
  it to the key, not the code path.
- **Fix:** `HotkeySetDecision.shouldSynthesizeRelease(physicallyDown:flagSet:)` — the exact negation
  of `isDown`, so the watchdog and the event path share one definition of "held". `HotkeyMonitor`'s
  watchdog now also samples the live modifier flag (`NSEvent.modifierFlags`, via
  `currentFlagSet(forKeyCode:)`) and only synthesises a release when **neither** signal says down.
  `NSEvent.modifierFlags` is device-independent, so Right ⌘ can only be read as the generic
  `.command` bit — holding Left ⌘ reads as "still down", which errs toward keeping the take alive
  (the real release event still ends it). 193 tests.
- **Lesson:** **a backstop that polls one signal can only be as trustworthy as that signal** — and
  `CGEventSource.keyState` is not uniformly implemented across modifier keys. Whenever the event
  path accepts "down" from *either* of two signals, the watchdog must reject "up" unless *both*
  agree; anything else silently vetoes the take. Practical tell: a duration that is suspiciously
  *constant* across attempts (0.489 s ≈ the 0.5 s timer) means a timer ended the take, not a key.

### 2026-10-10 — "hotkey does nothing, and my spacebar stops working until I restart"

- **Symptom:** "sometimes" pressing the hotkey did nothing — no pill, no sound — and from then on
  **Space stopped typing in every app**. Quitting and relaunching Lisper fixed both.
- **Root cause:** `AudioRecorder` reused one `AVAudioEngine` for the app's lifetime. When the
  default input device changed while idle (AirPods connecting = 16 kHz, another mic at 44.1 kHz),
  `inputNode.outputFormat(forBus: 0)` kept reporting the OLD 48 kHz, and `installTap` with that
  format raised an **Objective-C** `NSException` ("Failed to create tap due to format mismatch").
  Swift `do/catch` can't catch it; it unwound straight out of `beginRecording()` into AppKit, which
  logged it and kept running. By then `beginRecording()` had already armed the `RecordingKeyTap`
  (deliberately before the engine — see the lock race), so the tap stayed live with `onSpace` set and
  no take behind it: every Space went to `lockRecording()`, failed its `isRecording` guard, and was
  **swallowed anyway**. Every later hotkey press re-raised the same exception — "does nothing".
  A relaunch built a fresh engine with the current format.
- **Red herring:** this is a fifth "hotkey dead" cause and looks like the others, but the
  `/tmp/lisper-hotkey.log` trace shows a normal `PRESS edge → beginRecording branch` and then just
  stops. The relaunch that "fixes" it also truncates that trace, destroying the evidence. Also: a
  sample-rate change on the SAME device does NOT reproduce it (the engine adapts); it takes a
  default-device **switch**.
- **Diagnosis that worked:** the unified log still had it after the relaunch: `log show --last 30d
  --predicate 'process == "Lisper" AND (eventMessage CONTAINS "Failed to create tap" OR eventMessage
  CONTAINS "Format mismatch")'` showed `Format mismatch: input hw 16000 Hz / 44100 Hz, client format
  48000 Hz` + `An uncaught exception was raised`, once per press, on two separate runs (2026-10-09).
  Then `scripts/repro/mic-device-switch/run.sh` drove the real `AudioRecorder.swift` through a switch
  to a temporary 44.1 kHz aggregate device and went RED with the identical exception. The same harness
  found a second defect: a switch **mid-take** silently ended capture at the switch (0.79 s kept of
  2.3 s), because nothing handled `AVAudioEngineConfigurationChange`.
- **Fix:** `AudioRecorder` builds a **fresh engine per take** (fresh format, so no mismatch), and on
  `AVAudioEngineConfigurationChange` mid-take it re-opens capture on the new device and keeps
  appending. Defence in depth: `RecordingKeyTap` handlers now return whether they consumed the key,
  and `lockRecording()`/`cancelRecording()` disarm the tap and let Space/Esc through when no take is
  live, so a start that dies halfway can never eat the keyboard again. Cost: ~45 ms more mic
  cold-start per take (≈140 ms vs ≈95 ms), still inside the 200 ms before the start chime.
  Commits `0004539` (fix), `3b20311` (harness hardening).
- **Lesson:** **an Objective-C exception inside an AppKit event handler is a silent partial
  execution, not a crash.** Anything armed before the throwing call stays armed. AVFoundation
  (`installTap`, `connect`, `prepare`) throws ObjC exceptions for state errors, so (1) don't cache
  AVAudioEngine formats across device changes, and (2) design side-effects armed before a risky call
  to self-heal when they find nothing behind them. When "only a relaunch fixes it", search the
  unified log for `uncaught exception` before reading code.

### 2026-10-10b — "'you know what I mean' comes out as 'what', and the dictionary does nothing"

- **Symptom:** saying "you know what I mean" pasted "What."; "Claude" came out "clawed"/"cloud",
  "ChatGPT" as "ChatGBT", a friend's name "Jeriq" as "Jerry" — "the dictionary feature doesn't work".
- **Root cause:** two layers. (1) Groq **shut down `llama-3.3-70b-versatile` on 2026-08-16**; the
  stored setting kept sending it, every LLM cleanup failed, and `DictationPipeline` swallowed the
  error and fell back to `RuleBasedCleanup` — 1,234 takes in a row (last `llm` take: 2026-08-17
  08:37 local), with no visible sign. With the LLM dead, dictionary spelling was applied **nowhere**:
  the vocabulary is deliberately withheld from Whisper when an LLM is configured (prompt-echo
  hallucinations), so the LLM was its only consumer. (2) The rule fallback stripped "you know" and
  "I mean" **everywhere**, so "You know what I mean." → "What." and "Do you know what I mean?" →
  "Do what?" — a meaning-destroying cleanup the golden tests had locked in as expected output.
- **Red herring:** the dictionary UI. It saves fine; the settings blob simply had no terms, and even
  if it had, nothing downstream was alive to apply them. Also "the LLM is mangling fillers" — it
  wasn't running at all.
- **Diagnosis that worked:** `cleanupUsed` per day from `lisper.sqlite` (a cliff from mixed
  `llm`/`rules` to 100% `rules` overnight), `guardsFired: cleanupFallback` on every line of
  `dictations.jsonl`, then the deprecations page — whose shutdown date matched the cliff exactly.
  Whisper on the same key kept working, which ruled out the key.
- **Fix:** default chat model → `openai/gpt-oss-120b`, and `AppSettings` migrates any stored
  **retired** model on load (`retiredChatModels`). `GroqClient` sends gpt-oss `reasoning_effort: low`
  + `include_reasoning: false` and throws on `finish_reason: length` (never paste a truncated take).
  The pipeline records `cleanupError` in the debug log and returns a `cleanupNotice` the pill shows
  for user-fixable failures (model, key, rate limit); offline stays silent. Rule cleanup only strips
  "you know"/"I mean"/"sort of"/"kind of" when commas set them off as an aside. `BuiltInVocabulary`
  gives the LLM ~100 tech/business terms out of the box, applied only when context means them.
  Live eval (real prompt + client): 17/17, p50 ≈ 480 ms. Commits `3f4524d` (rules), `1a67690`
  (model + notices), `23b5b44` (built-in vocabulary).
- **Watch:** Groq's free tier allows **8,000 tokens/min** on gpt-oss-120b and a take costs ~1.1k
  (mostly the system prompt), so ~7 takes/min before 429s; the pill now says "Groq rate limit".
- **Follow-up, same day — gpt-oss prompt behaviour (measured with the live eval, not guessed):**
  (1) dictionary terms were applied only to "obvious" mis-hearings, so "Jerry"/"Cherry" stayed for
  a friend named "Jeriq" — the dictionary section now says Whisper mis-hears the speaker's own
  terms as common look-alikes (even a different first sound) and to prefer the term when it is
  used the same way ("cherry pie" stays). (2) gpt-oss **deletes clauses**: "let's chat tomorrow,
  to be honest I'm tired" → "Let's chat tomorrow." 3/4 runs — but only when the prompt did NOT end
  on a meaning reminder (the dictionary section ends on one); a closing "Final check… every clause
  is still there" line, kept LAST, fixed it 8/8. (3) It deletes a phrase the speaker is talking
  ABOUT ("when I say, you know what I mean, it…") as filler; an explicit "talking about a phrase =
  content" rule took it from 1/4 to 4/4. Rate-limited takes now retry on `groqBackupChatModel`
  (gpt-oss-20b, its own rate bucket) before dropping to rules. Commits `5ef38c6`, `75c8a3c`.
- **Lesson:** **a fallback that never reports is a silent outage.** "Degrade gracefully" must still
  leave a trace a human sees — log the error and surface anything the user can fix. And hosted model
  IDs are perishable: when a default model is a provider's, plan its retirement (migration list).

### 2026-10-12 — "it doesn't pick up the last phrase I say"

- **Symptom:** "a lot of the times it doesn't fully transcribe… it cuts off. Probably the last
  phrase I say." E.g. session 3384 ended "…so it's fattest at the top and then", 3381 "…it says
  select the persona which". Nothing errored; `guardsFired` just said `vadTrimmed`.
- **Root cause:** `EnergyVoiceActivityTrimmer` kept only frames above `AudioGate.speechThreshold`,
  whose floor is `peak * 0.1`. One take spans more than 20 dB: plosive / close-mic bursts (longer
  than the 150 ms `robustPeak` sets aside) put the peak at ~0.22, so the bar was 0.022, while the
  closing sentence trailed off at ~0.005–0.015, still **10–30x the 0.0005 room tone**. Everything
  after the last loud syllable was cut: 6.0 s in 3384, 5.0 s in 3381, 0.85 s in 3308. Same
  mechanism at the start (3384 lost "Also, sometimes"; 3224 lost "I mean"). A second, smaller
  group was noisy-room takes (Oct 8–10, noise floor 0.003–0.01) where the trailing-off words sit
  AT the noise floor and the 0.1 s trailing pad cut them ("…not us **internally testing**",
  "…please do not **do that**").
- **Red herring:** the 2026-08-02 fix is literally "threshold relative to the noise floor", so
  it looked done. It kept `max(peak * 0.1, …)` "to preserve behaviour on loud clips", and on a
  loud clip that peak term is the whole threshold. Also: not every lost ending is the trimmer.
  ~9 of 341 takes lost a phrase that WAS in the clip Groq received (3340 "…visually check
  them", 3185 "…so I can test it out", 3123's whole second clause). That one IS the model:
  Lisper's default is `whisper-large-v3`, and local large-v3 (`ggml-large-v3-q5_0.bin` from
  huggingface.co/ggerganov/whisper.cpp — download it; it isn't kept anywhere) reproduces it (3340, 3194) where turbo doesn't — the first offline check used turbo and
  wrongly concluded "Groq-side, can't reproduce". Check `groqWhisperModel` in the stored
  settings before picking a local model.
- **Diagnosis that worked:** cut the discarded region out of `audio/<id>.wav` and transcribe it
  locally with `whisper-cli` (model in `~/.cache/hyperframes/whisper/models/`): it said "…at the
  bottom. There's no need to say…", which turned a plausible theory into proof. Then for
  all 341 saved takes: transcribe the FULL wav locally, align with `rawTranscript` (difflib) to
  find endings present in the audio but missing from the paste (17 takes), and transcribe
  exactly what the trimmer would send. That splits "trimmer cut it" from "Groq dropped it". The
  candidate settings were scored by how many confirmed-lost words each recovered, and the Swift
  trimmer was replayed over every saved wav to confirm it matches the tuned model (0/346
  mismatches).
- **Fix:** a second, quiet-speech tier. `AudioGate.quietSpeechThreshold` =
  `min(speechThreshold, max(roomTone * 4, peak * 0.01))`. It only counts for **stretches of
  ≥ 150 ms** (runs of ≥ 2 frames, joined across dips ≤ 100 ms), so the mic's start-up blip and
  clicks don't keep dead air: a first version accepted any 50 ms run, and a review found 3314's
  blip decaying over 4 frames kept 1.9 s of dead air ahead of the first word. `roomTone` leaves
  out digital silence (frames < 1e-5): 44 takes open with the mic's warm-up zeros, and when
  they were 10% of the frames the floor read 0 and every second of trailing room tone was kept.
  The trailing pad went from 0.1 s
  to **1.0 s** (`trailingPaddingSeconds`): the trimmer usually removes almost nothing (median
  0.05 s), and Whisper hallucinates over long silences, not one second of room tone. Recovers
  10/10 trimmer-caused losses. Safety check: the 97 saved takes whose clip grows by ≥ 0.5 s,
  old vs new clip through local whisper-large-v3-turbo. Real words came back in 17 of them, and
  no new junk ending appeared. Re-checked with local large-v3, the production model, on 171 new
  clips: one invents a trailing "Thank you." (3137). Also fixed: `AudioGate.levels` used `>=`
  against a 0 noise floor, so a short word in exact digital silence was called silent (a
  robust peak of 0 now falls back to the raw max; everything else still compares with `>=`).
- **Clicks (found in the final review):** a single loud frame counts as speech, so a click
  anchored the span and kept the whole pause next to it. At the START it was the mic's
  start-up pop (3462: 12.7 s of silence before the first word — true before this fix too): a
  burst shorter than 200 ms, more than 250 ms from other speech, wholly within the first 0.5 s,
  is now ignored (never when it is the only burst). At the END, once the stop tail existed, it
  was the stop key's click (3455: a 4 s pause kept): evidence that only starts after the press
  (`CapturedAudio.heldSeconds`) is ignored. **Not** an end-zone click rule: one was tried and
  deleted 3098's quiet "Please. Thanks." and 3169's quick "yeah", which look exactly like clicks.
  Verified: Swift = model on all 426 takes; before/after transcripts of the 168 changed starts
  and the 11 changed stop-tail takes lose no word; pre-tail endings never change. The silence
  gate also judges the held take only — speech said after the press can't make a silent take
  (a lone start-up click) worth sending to Whisper.
- **Second fix (large-v3 stopping early):** `GroqWhisperEngine` sends the same clip to
  `groqEndingCheckModel` (default `whisper-large-v3-turbo`, cheaper and faster) alongside the
  primary (takes ≤ 60 s; two uploads of a longer one could starve the primary on a slow
  uplink) and waits at most 1.5 s more for it (a hard deadline). Only turbo's segments that
  START before the trimmer's last detected speech count (`CapturedAudio.speechEndSeconds`;
  with trimming off, `speechEndSeconds(in:)` on the raw clip — not a trimmed copy's offset):
  after it is the trailing pad, where Whisper invents sign-offs — two reviews found text lists
  can't catch them all ("Okay.", "Thanks." are also real endings). No segment times = no
  recovery. `EndingRecovery` appends whatever turbo heard after large-v3's last words, but only
  at an unambiguous splice: the last 3–8 words must occur once in each transcript, ending
  between 1 word early and max(4, 5%) words late of where large-v3's do (landing early pastes
  words twice). Refused: endings made only of silence hallucinations or sound annotations
  ("Thank you. Thank you.", "bye-bye", "[Music]" — annotations get an empty match key but are
  never cut from the pasted text, which once ate "(415)" from a phone number), echoes of the
  last words ("right? Right.",
  3188), and endings that start with a phrase the primary already has (a repeated sentence). Replayed over
  every saved take (Groq's `rawTranscript` vs local turbo on the clip now sent): 28 of 358
  get an ending back, all checked against the audio ("…what's going **on**", "…good luck on
  your **trip**", 7 of the 10 known drops); 0 wrong splices. Not recoverable: 3194 (both
  models miss the mumbled "I'll try again in a bit"). Also: zero-padding the clip changes
  nothing (Whisper pads to 30 s with zeros itself).
- **Third fix (the stop press clipped the last word):** `AudioRecorder.stop()` tore the engine
  down the instant the take finished, which also discards the tap buffer in flight (~100 ms),
  and the press itself often lands on the last syllable: 80 of 389 saved takes had speech in
  their final 50 ms, and some lost a word ("…a list of several", 3440). `stop(keepingTail:)`
  ends the take at once (`isRecording` false, so the hotkey state machine is unchanged) but keeps
  the mic open 0.3 s more; the stop cue plays after, so it isn't recorded. Esc/abort still stop
  at once. The pipeline gets `heldSeconds` (time before the tail) for the 0.4 s "too short"
  gate, stats, `rms` and saved duration (so "0.0 s, rms 0" still marks an empty capture) —
  otherwise the tail would push a 0.29 s accidental tap (a missed Fn→Space lock) past the gate
  and paste a fragment. The tail records the stop key's click: see "Edge clicks" above.
  **Check:** the share of new takes with speech in the final 50 ms should fall.
- **Commits:** PR #6 (merge `d583a9c`): `24a5cf8`, `bf07256` trimmer; `4d2db83`, `e255809`,
  `a44edf0` ending check; `2af9230` stop tail. Final-review hardening: PR #8 (`4fc460c`).
- **Lesson:** **a peak-relative threshold assumes a take's dynamic range is under 20 dB, and
  dictation's isn't.** Loud bursts and a voice that trails off at the end of a thought are
  normal. Judge speech against the noise floor. And "transcript ends early" has two separable
  causes. Transcribe the audio the trimmer **sent** as well as the **full** wav: words in full
  but not in sent = trimmer, words in sent but not in `rawTranscript` = the ASR.

## Entry template

```
### YYYY-MM-DD — <short symptom, in the user's words>

- **Symptom:** what was observed.
- **Root cause:** the actual mechanism (not the symptom).
- **Red herring:** what looked like the cause but wasn't — the real time-saver for next time.
- **Diagnosis that worked:** the evidence / instrumentation that localized it.
- **Fix:** what changed (files / commit).
- **Lesson:** the reusable shortcut for similar future bugs.
```
