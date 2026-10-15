# Simplify Lisper + multi-key hotkey — design

**Date:** 2026-08-02
**Status:** approved (decisions captured below)

Two independent pieces of work, specced together because both touch Settings:

1. **Multi-key hotkey** — several trigger keys live at once, so dictation works across a laptop
   and an external keyboard without changing a setting.
2. **Simplification** — remove the coach/coherence machinery the user never visits, keep a
   reduced Flow Score, fix the broken trend graph, and drop the Formal style mode.

---

## Part 1 — Multi-key hotkey

### Motivation

The user moves between the laptop keyboard (where **Fn** exists) and a full-size external
keyboard (where **F13–F15** exist). Today `AppSettings.hotkey` holds exactly one
`HotkeyChoice`, so swapping keyboards means changing a setting.

**Chosen approach: "any-of-a-set."** The user ticks several keys and all of them are live. A key
that does not exist on the currently-attached keyboard simply never fires. No device detection,
no profiles, nothing to go stale. (Per-keyboard auto-detection was considered and rejected as
disproportionate machinery for the benefit.)

### Settings model

`AppSettings.hotkey: HotkeyChoice` → `hotkeys: [HotkeyChoice]`.

Tolerant decode, following the existing `coachAnalysisEnabled` precedent:

| Stored state | Decodes to |
|---|---|
| `hotkeys` present, non-empty | that list (duplicates removed, order preserved) |
| `hotkeys` absent, legacy `hotkey` present | `[legacyValue]` |
| both absent | `[.fn]` |
| `hotkeys` present but empty | `[.fn]` |

**Invariant: the list is never empty.** A zero-key state would make the app impossible to
trigger with no in-app way to recover.

### Key identity moves into LisperKit

The keycode mapping currently lives in `HotkeyMonitor` (app-side, therefore untestable). It moves
to `HotkeyChoice.keyCode: UInt16` so it is single-sourced and unit-tested.

### `HotkeySetDecision` (new, `Sources/LisperKit/Input/`)

Generalises `FnKeyDecision` from "is this the Fn key" to "is this **one of my enabled** keys",
preserving the hard-won Fn semantics exactly:

- an event whose keyCode is not an enabled key returns `nil` — **ignore**, never treat as a release;
- a key is down when **either** its modifier flag **or** its physical key state says so.

It adds **ownership**: the first enabled key to go down owns the session, and events from other
enabled keys are ignored until the owner releases.

Ownership is the load-bearing part. Every historical hotkey bug in this app is a *phantom release*
from an unrelated `flagsChanged` event (see DEBUGGING-LOG 2026-06-14c, 2026-06-29, 2026-06-30).
Enabling several keys multiplies exactly that risk, so a non-owning key is made structurally
incapable of ending another key's take.

### App-side changes

`HotkeyMonitor` stays thin: it registers monitors for the enabled set and delegates every decision
to the pure type. The existing watchdog polls the **owning** key's physical state.

### UI

- `SettingsView`: the "Key" `Picker` becomes a multi-select toggle list, enforcing ≥ 1 selected
  (the last remaining key cannot be unticked).
- `HistoryView` / `OnboardingView`: show a combined label, e.g. "Hold Fn (🌐) or F13".

### Out of scope (YAGNI)

Keyboard auto-detection; different behaviour per key; recording arbitrary key combinations.

---

## Part 2 — Simplification

### 2a. Remove the coherence / coach engine

Delete outright:

- `Coach/CoherenceAnalyzer.swift`, `Coach/CoherenceModels.swift`
- `Coach/DailyDigestGenerator.swift`
- `Coach/Playbook.swift` + `Coach/Playbook/playbook.json` resource
- `Coach/CoachAnalysisService.swift`
- the coherence/vocabulary/phrase panels and the daily-digest card in `CoachView.swift`
- the `coachAnalysisEnabled` setting and its Settings row

This stops a **Groq LLM call per session**, lowering API cost and dictation latency.

### 2b. Flow Score keeps 3 tiles

`FlowScore.compute` already has a degraded path for `coherence == nil`. That path becomes the only
path, and the `coherence:` parameter is removed:

| Tile | Source |
|---|---|
| Filler-free | `stats.fillersPer100Words` |
| Continuity | `disfluency.per100Words` proxy |
| Sustain | duration vs 60 s target |
| ~~Single thread~~ | **removed** — it required coherence |

Weights are the existing degraded weights: filler-free 0.45, continuity 0.35, sustain 0.20.
`singleThread` and `isComplete` leave the struct entirely, and the "Single thread" tile is removed
from the hero.

Consequence worth stating: the user's Single Thread was 12/100 carrying 30% weight, so scores will
**rise** after this change. Historical scores are recomputed on read, not migrated.

### 2c. Fix the broken trend graph

**Root cause** (`CoachView.flowSparkline`, two compounding defects):

1. It plots **one point per session** against a `unit: .day` x-axis, so every take in a day lands on
   the *same x* — visible as vertically stacked dots (52 / 68 / 78 on 19 Jul).
2. `.interpolationMethod(.catmullRom)` through those duplicate x values **overshoots wildly**; the
   `AreaMark` renders the overshoot as tall spikes escaping the plot area.

**Fix:** aggregate to **one mean score per day** before plotting — which is what a "Trend" chart
implies anyway — and switch to `.monotone`, which cannot overshoot. Aggregation is a pure function
in LisperKit (`FlowTrend.dailyMeans`) so it is unit-tested; the view only renders.

Related: the trend currently reads **persisted LLM analyses**, so removing the engine would starve
it. Flow Score therefore becomes deterministic and is computed from stored `SessionRecord`s on read
— which also backfills the entire history instead of only the sessions that were LLM-analysed.

### 2d. Remove the Formal style mode

`StyleMode` loses `.formal`; cleanup is always casual. The Settings picker is removed, and
`CleanupPromptBuilder`'s formal branch and its tests go with it. Settings decoding maps a stored
`"formal"` to `.casual` rather than failing.

Since `StyleMode` ends up with a single case, it is deleted entirely and `CleanupContext.style` is
dropped — carrying a one-case enum is worse than removing the concept.

### Data / migration

No destructive SQL migration. Analysis rows already written stay in the database, unread and inert.
Dropping tables buys nothing and risks data loss on a mistake.

---

## Testing

Test-first, in LisperKit (per the repo's testability boundary):

**Hotkey**
- `HotkeyChoice.keyCode` for every case
- a keycode outside the enabled set returns `nil` (ignored, not a release)
- Fn stays down when the flag clears but the key is physically held
- a second enabled key pressed mid-take is ignored
- the owner's release ends the take
- settings: legacy `hotkey` migrates; missing → `[.fn]`; empty → `[.fn]`; duplicates removed

**Simplification**
- `FlowScore.compute` returns the 3-tile score with the degraded weights
- `FlowScore.dailyMeans` collapses several same-day scores into one mean point, sorted by day
- settings decoding maps stored `"formal"` to casual without throwing

Full suite via `swift run LisperKitTests` (never `swift test` — it executes nothing here).
