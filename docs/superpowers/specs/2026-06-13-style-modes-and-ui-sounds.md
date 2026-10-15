# Formal/Casual style modes + Apple-quality UI sounds

Date: 2026-06-13 · Status: approved, not yet implemented

Post-v0.1 feature round, brainstormed interactively. Four workstreams:
a global Formal/Casual style setting that replaces the per-app tone system,
a redesigned three-sound UI cue family, a re-fix of the Fn language-switcher
bug, and a CLAUDE.md description update.

## Motivation

The LLM cleanup is censoring swear words in every context — the prompt never
mentions profanity, so the model sanitizes on its own initiative. Lucent wants
two explicit modes: **Formal** for public-facing writing (copy, scripts) and
**Casual** for everyday dictation where swearing must survive verbatim.
Separately, Wispr Flow's UI sounds are noticeably better than Lisper's
current sub-bass cues; the new set should reach that quality with original
sounds informed by Apple's published sound-design practice.

## 1. Style modes (Formal / Casual)

### Decisions (user-confirmed)

- **One global toggle** — no per-app detection. The per-app tone system
  (`ToneHint`, `ToneRules`, `toneRules` setting, bundle-ID rules, the
  "Tone per app" settings section and `ToneRulesEditor`) is **removed
  entirely**, including the terminal/verbatim special case.
- **Formal removes swears entirely** (not softened): "this is fucking
  broken" → "this is broken". Casual transcribes profanity exactly as
  spoken — never censored, softened, or removed.
- **Default mode: casual** (everyday use is the common case).
- UI lives in the Settings view as a "Style" section with Wispr-style
  selectable cards showing example cleanups.

> Deviation note: this deletes LisperKit public types (`ToneHint`,
> `ToneRules`) that CLAUDE.md's deviation policy protects. Explicitly
> user-approved 2026-06-13; the v0.1 plan is complete so no pending task
> depends on them.

### Data model

```swift
public enum StyleMode: String, Codable, CaseIterable, Sendable {
    case formal, casual
}
```

- `AppSettings.styleMode: StyleMode = .casual` replaces `toneRules`.
- `CleanupContext` drops `tone: ToneHint`, gains `style: StyleMode`.
  (`appName`/`bundleID` stay — still used for context phrasing and history.)
- **Migration constraint:** `AppSettings` uses synthesized Codable, and
  `SettingsStore` falls back to fresh defaults when decoding throws. A new
  non-optional key would fail decoding of every existing settings blob and
  silently reset the user's hotkey/dictionary/fillers. `AppSettings` must
  therefore decode missing keys to defaults (custom `init(from:)` with
  `decodeIfPresent` for all fields, or equivalent). The now-unknown stored
  `toneRules` key is ignored by Codable and needs no handling. Add a settings
  test: v0.1-era JSON (with `toneRules`, without `styleMode`) decodes to
  `styleMode == .casual` while preserving the other stored values.

### Prompt behavior (`CleanupPromptBuilder`)

The shared rules (sentence order, filler removal, self-corrections,
never-answer-the-transcript, output-only-cleaned-text) are unchanged.
The per-tone `switch` is replaced by a two-case style block:

- **Casual:** keep it conversational; keep contractions; *"Profanity is part
  of the speaker's voice — transcribe swear words exactly as spoken; never
  censor, soften, or remove them."*
- **Formal:** public-facing writing; complete, well-structured sentences,
  polished tone; *"Remove profanity entirely while preserving the sentence's
  meaning."*

The meaning-preservation contract holds in both modes: no answering, no
added content, no summarizing. Formal's swear removal is the *only*
permitted deletion beyond fillers/false starts.

### Offline fallback

`RuleBasedCleanup` is unchanged. It never censored, so casual mode is
already correct offline. Formal mode degrades gracefully: with no LLM,
swears stay in. We do not maintain a profanity lexicon for rule-based
removal.

### Settings UI

Replace the "Tone per app" `HairlineSection` (SettingsView.swift:61-64) and
`ToneRulesEditor` with a "Style" section: two selectable cards (Casual
first, since it's the default), each with a title, a one-line description,
and a before/after example, all using `Theme` tokens. Selected card gets the
accent treatment.

| Card | Description | Example (raw: *"um this is fucking awesome, we should uh ship it"*) |
|---|---|---|
| **Casual** | Everyday messages and notes. Keeps your voice — swearing included. | "This is fucking awesome, we should ship it." |
| **Formal** | Public-facing writing — copy, scripts, emails. Polished, no profanity. | "This is awesome. We should ship it." |

### Tests (LisperKit, test-first)

- `PromptBuilderTests`: casual prompt contains the never-censor instruction;
  formal prompt contains the remove-profanity instruction; both retain the
  never-answer contract lines; old per-app assertions deleted.
- `SettingsTests`: round-trip with `styleMode`; legacy-JSON migration test
  above.
- `PipelineFallbackTests` / golden-transcript tests updated for the new
  `CleanupContext` shape.

## 2. UI sound redesign (start / lock / cancel)

### Decisions (user-confirmed)

- **Wispr/Apple-style audible pitched tones** replace the sub-bass identity
  from the 2026-06-13 sub-bass spec.
- Still **synthesized in Swift** (`UISounds.swift`), no bundled assets.
- **Audition workflow:** render 2–3 candidate families as WAV files for
  Lucent to listen to and pick from *before* wiring into the app — same
  process as the sub-bass round.
- **Lock gets a sound** — `lockRecording()` (AppDelegate) is silent today;
  add `UISounds.playLock()`.

### Research-derived design (sources in footnote)

One shared synthesized voice across all three cues — a soft "glass marimba":
sine fundamental + harmonics 2–4 at roughly −6/−12/−18 dB with exponential
per-partial decay, percussive 2–5 ms attack, gentle low-pass ~6–8 kHz,
high-pass ~200 Hz, light Schroeder-style reverb (4 combs + 2 allpasses,
RT60 ≈ 0.3–0.6 s). Family identity comes from the timbre; meaning comes from
pitch contour and note count:

| Cue | Motif | Envelope/tail | Length |
|---|---|---|---|
| **Start** | 2 notes, rising perfect fifth (≈ G4 392 Hz → D5 587 Hz) | exp decay ~200 ms, **short, near-dry tail** | ≤ 300 ms |
| **Lock** | 3 notes, rising 1–5–8 arpeggio (G4–D5–G5), ~80–100 ms spacing | longest decay ~300–450 ms + the lush reverb tail (long release reads as "confirmed") | ~450–600 ms |
| **Cancel** | falling fifth (D5 → G4), slightly darker (LPF ~4–5 kHz) | ~120–180 ms decay, dry | ~150–250 ms |

Engineering constraints:

- **48 kHz** render (current 16 kHz caps content at 8 kHz and is the main
  fidelity ceiling). Still in-memory via `WavEncoder`/`NSSound`.
- All three loudness-matched, peaks ≈ −16 dBFS pre-`NSSound.volume`; played
  quiet (tune the existing low-volume approach by ear during audition).
- **Mic-bleed rule:** the start cue must be short and tail-light because the
  microphone opens with it; the lush tail belongs to lock alone (the user
  isn't speaking yet), and cancel stays short and dry per the table — the
  mic is already closed there, but a dry tail is what reads as "dismissed".
  Tonal partials > 200 Hz
  with no broadband energy also keep Whisper from transcribing the cue.
- Clean finish: no leading silence, no truncated tails, fades to true zero.
- Candidate WAVs are written to a scratch folder for audition, generated by
  the same synthesis code that ships (a small debug entry point, not a
  separate implementation).

App target only — no LisperKit changes, no unit tests per the testability
boundary (`WavEncoder` is already covered).

Research sources: WWDC 2017 session 803 "Designing Sound"; Twenty Thousand
Hertz "The Sound of Apple"; Brewster/Wright/Edwards earcon guidelines
(HCI'95); Bhatara et al. 2025 (Human Behavior and Emerging Technologies);
BeepBank-500 earcon corpus (arXiv 2509.17277).

## 3. Fn language-switcher bug (regression/debug task)

Pressing Fn to start dictation **still opens the macOS input-source
switcher**, despite the 2026-06-13 fix (write `AppleFnUsageType = 0` +
force-quit `TextInputSwitcher`/`TextInputMenuAgent`).

This is a systematic-debugging task, not a designed fix. Known facts to
start from:

- `FnKeyGuard.mute()` early-returns when the pref already reads 0 — if the
  on-disk value is 0 but a live agent holds a stale non-zero value, the fix
  never fires. The earlier manual repair on this machine may have masked
  exactly this path.
- Candidate alternate mechanisms to check: ByHost vs. plain preference
  domain; `AppleGlobeKeyAction`-era keys on newer macOS; whether the menu is
  triggered by a different agent than the two we kill; whether Lisper's own
  CGEvent tap sees the key first and could suppress it.

**Acceptance:** with Lisper running and hotkey = Fn, pressing/holding Fn
starts dictation and never opens the input-source switcher or emoji
picker, across app restarts and a logout/login.

## 4. CLAUDE.md description update

Reword the project description: Lisper is no longer "a menu-bar app" — it's
a full macOS app (main window with History, Coach, Dictionary, Settings)
with a menu-bar presence and a recording pill. Touch only the description
wording; commands/architecture/rules sections stay accurate.

## Out of scope

- Wispr-style multi-level cleanup (None/Light/Medium/High) — only the two
  style modes were requested.
- Caps/punctuation formality variants ("very casual" lowercase mode).
- Per-app overrides of the style mode.
- An "undo AI edit" affordance (raw transcript is already stored per
  session; surfacing it is a separate feature).
