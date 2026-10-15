# Lisper — Design Spec

**Date:** 2026-06-12
**Status:** Approved (user pre-approved execution 2026-06-12)
**Goal:** A personal, product-shaped macOS clone of Wispr Flow — system-wide voice dictation with LLM cleanup and a speaking-coach dashboard — at ≤$5/month running cost (target ~$1/month).

## 1. Product summary

Lisper is a macOS menu-bar app. Hold a hotkey anywhere in macOS, speak naturally, release — and clean, formatted text is inserted at the cursor in whatever app is frontmost. Every dictation is stored locally (raw + cleaned), powering a Coach dashboard that tracks filler words, pace, and crutch words over time, with weekly AI coaching tips.

It replicates Wispr Flow's confirmed architecture (thin client → cloud ASR → LLM cleanup, ~700ms budget) using Groq-hosted models at ~1/15th the subscription price, with Apple's on-device engine as a free/offline fallback.

### Success criteria

- Dictating into Slack/Mail/browser/IDE works reliably; text appears at cursor.
- Release-to-text latency ≤ ~1.5s for utterances under 15s (target ~1s).
- Cleanup quality comparable to Wispr Flow: no fillers, correct punctuation, sensible paragraphs/lists, app-appropriate tone, meaning preserved verbatim.
- Running cost at heavy personal use ≤ $5/month (expected ≤ $1.50).
- Coach dashboard shows real trends after a week of use.
- App feels native, fast, and visually striking (see §8 Design language).

## 2. Cost & engine strategy

| Layer | Default (quality path) | Fallback (free/offline) |
|---|---|---|
| Speech-to-text | Groq `whisper-large-v3-turbo`, $0.04/hr audio | Apple SpeechAnalyzer (macOS 26, on-device) |
| Cleanup LLM | Groq `llama-3.3-70b-versatile` (configurable model string) | Rule-based filler stripping |
| Weekly coach tip | Same Groq LLM, 1 call/week | Skipped if no key |

Estimated heavy use (1 hr dictated audio/day): ~$1.20/mo STT + LLM usage well within Groq free tier (or cents). Hard ceiling $5/mo is unreachable in practice. One API key (Groq) drives everything; key stored in macOS Keychain. All engine/model identifiers are user-editable strings in Settings so providers can be swapped without code changes (any OpenAI-compatible endpoint works for both STT and chat).

## 3. Architecture

Swift 6.2, SwiftUI + AppKit where needed. SPM-only build (no Xcode project): Command Line Tools + `swift build`, a bundling script assembles `Lisper.app`, signed with a locally generated certificate so TCC permissions persist across rebuilds.

### SPM targets

- **`LisperKit`** (library — all logic, fully testable): pipeline orchestration, engines, persistence, stats, prompt building, settings model.
- **`Lisper`** (executable — app shell): menu-bar item, floating recording pill, main window UI, permissions onboarding, hotkey monitor, audio capture, pasteboard insertion (thin AppKit wrappers around LisperKit protocols).
- **`LisperKitTests`**: unit tests.

### Pipeline (the core loop)

1. **Hotkey** — global `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged/.keyDown)` watching the configured key. Default: hold **Fn** (matches Wispr Flow). Alternatives offered: right-⌘, right-⌥, F13–F19. Modes: hold-to-talk (default) or press-to-toggle. Onboarding tells the user to set System Settings → Keyboard → "Press 🌐 key" to **Do Nothing** so Fn is free.
2. **Capture** — `AVAudioEngine` tap, 16 kHz mono Float32 in memory, 5-minute cap (recording auto-stops and processes when hit), RMS level stream feeding the pill's waveform. *(see 2026-06-13 amendment — audio may also be persisted locally for debugging)*
3. **Transcribe** — `TranscriptionEngine` protocol: `transcribe(audio: AudioBuffer, hints: DictionaryHints) async throws -> RawTranscript`.
   - `GroqWhisperEngine`: WAV-encode buffer, multipart POST to `…/openai/v1/audio/transcriptions`, model `whisper-large-v3-turbo`, `prompt` seeded with personal-dictionary terms.
   - `AppleSpeechEngine`: SpeechAnalyzer/SpeechTranscriber (on-device, macOS 26 API).
   - Fallback chain: Groq → Apple → error state on the pill. Offline detection short-circuits to Apple.
4. **Clean** — `CleanupEngine` protocol: `clean(raw: String, context: CleanupContext) async throws -> String`.
   - `LLMCleanupEngine`: OpenAI-compatible chat completion (default Groq). System prompt encodes: remove fillers/false starts, punctuate, paragraph, format spoken lists ("first… second…" → list), apply personal dictionary spellings, obey app tone hint, **preserve meaning verbatim — never answer questions, never add content, output only the cleaned text**. Self-corrections honored ("…on Tuesday, no wait, Wednesday" → "Wednesday").
   - `RuleBasedCleanupEngine`: regex filler removal + sentence casing (offline/no-key fallback).
   - `CleanupContext` = frontmost app bundle ID + tone hint + dictionary terms.
5. **Insert** — save current `NSPasteboard` contents → write cleaned text → synthesize ⌘V via `CGEvent` → restore prior pasteboard after ~300ms. Frontmost app via `NSWorkspace.frontmostApplication`. If insertion is impossible (secure input field), leave text on pasteboard + user notification "Press ⌘V".
6. **Persist** — write session to SQLite; stats computed inline.

### App-aware tone

Editable map of bundle ID → tone hint. Defaults: Slack/Messages/Discord → casual; Mail/Pages/Docs → polished; Terminal/IDEs (com.apple.Terminal, dev.warp, com.microsoft.VSCode, etc.) → verbatim-technical (no rewording, keep technical terms exactly); unknown → neutral.

### Personal dictionary

User-managed list of names/terms (e.g. "Lucent", "BetterYourAds", "Lisper"). Injected into both the Whisper `prompt` parameter and the cleanup system prompt.

## 4. Persistence

SQLite via GRDB (SPM dependency). Database at `~/Library/Application Support/Lisper/lisper.sqlite`.

**`sessions` table:** id, started_at, duration_seconds, app_bundle_id, app_name, raw_transcript, cleaned_text, word_count, filler_count, fillers_json (per-filler counts), wpm, engine_used, cleanup_used, inserted (bool).

**`weekly_tips` table:** week_start, tip_markdown, generated_at.

Settings in `UserDefaults` (a `Codable` settings struct), API key in Keychain. Retention setting: forever (default) / 90 / 30 days; pruning on launch. Audio is never persisted.

> **Amended 2026-06-13:** audio is now persisted locally for debugging (7-day purge, never leaves the machine, toggleable). See `docs/superpowers/specs/2026-06-13-lisper-debug-loop-design.md`.

## 5. Coach (differentiator — Wispr has nothing like this)

Computed locally from **raw** transcripts (the pre-cleanup truth of how the user actually speaks):

- Filler rate: fillers per 100 words, overall + trend by day/week. Default filler set: um, uh, like, you know, sort of, kind of, I mean, basically, actually, literally, so (sentence-initial) — user-extensible custom crutch words.
- WPM per session + trend.
- Top crutch words this week with counts ("'like' ×47").
- Streaks: longest run of sessions under N fillers/100 words.
- Per-app breakdown (where do you ramble?).
- **Weekly tip:** one LLM call over the week's raw transcripts → 2–3 specific, actionable suggestions, rendered as a card; cached in `weekly_tips`.

## 6. UI surfaces

1. **Menu-bar item** — waveform glyph; states: idle / recording / processing / error. Menu: Open Lisper, pause hotkey, quit.
2. **Recording pill** — floating non-activating `NSPanel`, bottom-center of the active screen, visible only while recording/processing. Black capsule, live waveform bars driven by mic RMS, glow treatment per §8. States: listening → processing (shimmer) → brief success tick (or error). Never steals focus.
3. **Main window** (~960×640, dark-only): sidebar navigation — **History** (searchable session list: cleaned text, app icon, time; expandable to show raw transcript diff; copy buttons), **Coach** (dashboard per §5, Swift Charts), **Dictionary** (term list editor), **Settings** (hotkey recorder, mode, engine pickers + model strings, API key field, tone-rule editor, retention, launch-at-login via `SMAppService`).
4. **Onboarding** (first run): cinematic welcome → mic permission → accessibility permission (with "open System Settings" buttons and live-detected status) → Fn/globe-key setup note → optional Groq key (skippable → Apple engine) → "hold Fn and say hello" test moment.

## 7. Permissions

- **Microphone** — `NSMicrophoneUsageDescription`, standard prompt.
- **Accessibility** (`AXIsProcessTrusted`) — required for global hotkey monitoring and synthetic ⌘V. Onboarding deep-links to the Privacy pane and polls until granted.
- Stable code signature (local cert, created once by `scripts/make-cert.sh`) so grants survive rebuilds.

## 8. Design language — "cinematic Apple"

Reference: deep-space black with a luminous electric-blue bloom rising from the lower-left, fine film grain everywhere, Apple-keynote energy. Dark-only in v1.

**Tokens** (single `Theme` namespace in code):

- Canvas: `#050608` base; panels `#0B0D12` at 80% over the glow.
- Glow: radial gradient anchored lower-left — core `#3FB6FF` → `#0A66FF` → transparent by 60% radius; a second faint teal bloom `#0FA3A3` bottom edge. Slow drift animation (≥20s loop, subtle).
- Grain: tileable monochrome noise texture generated once at runtime and cached (`NoiseTexture` in the app target), overlaid via `.blendMode(.overlay)` at 3–4% opacity on every surface including the pill.
- Accent: `#2997FF`; success `#30D158`; destructive `#FF453A`.
- Text: `#F5F7FA` primary; 55% white secondary; 30% white tertiary.
- Hairlines: 8% white borders, 1px. Corner radius 16 (cards), capsule (pill). Shadows: soft blue-tinted, large radius, low opacity.
- Type: SF Pro (system). Stats use large light-weight numerals (e.g. 56pt `.light`) with tight tracking; labels 11pt uppercase 60% white with wide tracking.
- Materials: `.ultraThinMaterial` cards floating over the glow background.
- Motion: unhurried — 0.4–0.6s ease-out transitions, gentle scale+fade for cards, waveform bars spring-animated.

Every window (onboarding, main, even error states) sits on the glow+grain canvas. The pill glows brighter while listening — like the mic is the light source.

## 9. Error handling

- Engine failures: Groq error/timeout (8s) → Apple engine → if both fail, pill shows error and raw audio is discarded (nothing saved).
- No network: skip Groq silently (reachability check), use Apple + rule-based cleanup; History marks session "offline".
- LLM cleanup failure: fall back to rule-based; save session flagged `cleanup_used = "rules"`.
- Empty/silent recordings (<0.4s or no speech): ignored, pill fades with a subtle "nothing heard" state.
- Hotkey unavailable (monitor returns nil / permission missing): menu-bar icon shows warning state, clicking opens the relevant onboarding step.
- Pasteboard restore guaranteed via `defer`-style handling even on insertion errors.

## 10. Testing

- **Unit (swift test):** filler/WPM stat math against fixture transcripts; rule-based cleanup; prompt builder (dictionary + tone injection); engine fallback chain with mock engines; GRDB store round-trip + retention pruning; settings codec.
- **Golden transcripts:** fixture set of messy raw dictations with expected cleaned outputs (structure assertions: no fillers remain, list formatting applied) — validates prompt contract via mocked LLM responses, plus an optional live smoke script (`scripts/smoke-cleanup.sh`) hitting Groq when a key is present.
- **Manual smoke checklist** (documented in README): dictate into TextEdit, Safari text field, Slack, VS Code, Terminal; clipboard restored; offline mode; permission revocation recovery.

## 11. Build & distribution

- `scripts/make-cert.sh` — one-time local signing certificate ("Lisper Dev").
- `scripts/build.sh [--release]` — `swift build` → assemble `dist/Lisper.app` (Info.plist: `LSUIElement=true`, mic usage string, bundle ID `com.lucent.lisper`, version) → copy resources (app icon) → `codesign`.
- `scripts/run.sh` — build + relaunch.
- App icon: generated programmatically (script) — waveform glyph on the blue-glow/grain canvas.
- README: setup (cert, build, permissions, Groq key), smoke checklist, cost notes.

## 12. Out of scope (v1)

Streaming text while speaking; command mode ("make that shorter"); iOS/Windows; team features; multi-language UI (Whisper auto-detects languages regardless); App Store distribution/notarization; local Whisper/Parakeet model downloads (engine protocol leaves the door open).

## 13. Risks & mitigations

- **Fn key capture quirks** → offer right-⌘/right-⌥/F-keys; globe-key onboarding note; hotkey logic isolated behind a `HotkeyMonitor` protocol.
- **Synthetic paste blocked in some apps** → clipboard-retained fallback + notification (Wispr has the same failure mode).
- **SPM-only SwiftUI app bundling friction** → bundling script is part of v1 scope, tested early (task #1 in plan).
- **Groq model deprecations** → model IDs are editable settings, not constants.
- **SpeechAnalyzer API instability (new in macOS 26)** → isolated behind `TranscriptionEngine`; Groq path is primary.
