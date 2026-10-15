# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Lisper is a personal macOS voice-dictation app (a Wispr Flow clone) — a full windowed app (Home, Insights, Dictionary, Settings) plus a menu-bar item and floating recording pill: hold your hotkey (Fn by default, any key can be chosen in Settings) anywhere → speak → Groq Whisper transcribes → Groq LLM cleans → text is pasted at the cursor. Local SQLite history powers a minimal Insights page (a deterministic Flow Score + per-day trend). Dark-only "cinematic Apple" aesthetic (black canvas, blue glow, film grain).

The project is built from two authoritative documents — read them before non-trivial work:

- **Spec:** `docs/superpowers/specs/2026-06-12-lisper-design.md` — product behavior, architecture, design tokens, error handling.
- **Plan:** `docs/superpowers/plans/2026-06-12-lisper.md` — 13 ordered tasks with exact file contents, tests, and per-task commit messages. If implementation is incomplete, continue from the first unfinished task (check `git log --oneline` — one commit per task).
- **Debug loop:** `docs/superpowers/specs/2026-06-13-lisper-debug-loop-design.md`
- **Debugging log:** `docs/DEBUGGING-LOG.md` — known landmines + a symptom→cause index + past root-cause fixes. **Consult it before debugging any bug** (Lisper bugs often masquerade — e.g. a dead hotkey that looks like a permissions problem but is a silently-aborted launch). **Add an entry after fixing any non-trivial bug**, using the template at the bottom.

## Commands

```bash
swift build                          # build (SPM-only — no Xcode project, ever)
swift run LisperKitTests             # run all unit tests (Swift Testing). NOTE: plain
                                     # `swift test` exits 0 but EXECUTES NOTHING on this
                                     # CLT-only machine (no Xcode/XCTest) — never trust it.
                                     # --filter is not supported; always run the full suite.
./scripts/build.sh [--release]       # swift build → assemble + codesign dist/Lisper.app
./scripts/run.sh                     # kill running instance, rebuild, open dist/Lisper.app
./scripts/make-cert.sh               # one-time: create "Lisper Dev" signing cert so macOS
                                     # permission grants (Mic/Accessibility) survive rebuilds
./scripts/build.sh --dist            # shareable build: universal, ad-hoc signed,
                                     # dist/share/Lisper.app + dist/Lisper.zip
./scripts/publish-public.sh [--release vX.Y.Z]  # push a clean snapshot of origin/main to the
                                     # PUBLIC repo; --release also builds a downloadable release
```

The app must be run as `dist/Lisper.app` (not the bare `.build` binary) — TCC permissions and Info.plist (`LSUIElement`, usage strings) only apply to the bundle.

**Public copy.** This repo is private and stays private: its history holds personal dictation
transcripts and strategy docs. Others get the app from a separate public repo that
`publish-public.sh` fills with one squashed snapshot per publish (minus
`scripts/public-exclude.txt`, authored with the GitHub no-reply email). So anything committed
here can end up public on the next publish — never commit real transcripts, real people's names,
keys, or private notes; synthetic test text only, and add private docs to the exclude list.
Releases are ad-hoc signed, not notarized (no paid Apple account) — `README.md` tells users how
to open them; `PRIVACY.md` must stay accurate when data handling changes.

## Architecture

Two SPM targets with a hard testability boundary:

- **`Sources/LisperKit/`** (library) — ALL logic lives here and is unit-tested: transcript stats, rule-based cleanup, cleanup prompt builder + built-in vocabulary, settings/Keychain, GRDB store, WAV encoder, Groq client, engine protocols, pipeline orchestration.
- **`Sources/Lisper/`** (executable) — thin AppKit/SwiftUI shell only: hotkey monitor, AVAudioEngine capture, pasteboard insertion, permissions, menu bar, recording pill (`NSPanel`), main window, onboarding. App-side services implement LisperKit protocols so the pipeline stays testable with mocks.

The core pipeline (`DictationPipeline`): hotkey → capture 16 kHz mono in memory; a local copy is also persisted for debugging (`Application Support/Lisper/audio/<id>.wav`, auto-purged after 7 days, never leaves the machine, toggleable via Settings → "Save audio for debugging") → transcribe → clean → paste via synthetic ⌘V (save/restore prior pasteboard) → persist session to SQLite. Engines sit behind `TranscriptionEngine`/`CleanupEngine` protocols with a fallback chain: Groq → Apple on-device (`SFSpeechRecognizer`) → rule-based cleanup. Offline or no API key must always degrade gracefully, never error out.

The trigger key is a raw virtual keycode (`AppSettings.hotkeyCodes: [UInt16]`, default `[63]`
= Fn), not a named choice — any key can be captured in Settings. `KeyCatalog` (LisperKit)
maps a keycode to its label, its modifier descriptor (which decides `flagsChanged` vs
`keyDown` routing), and whether it is refused (Caps Lock, Space, Esc). While an unlocked
hold-mode take is in flight, a keyDown from any other key silently abandons it, so a shortcut
modifier like Left ⌃ stays usable for shortcuts. Space-locked (hands-free) and toggle-mode takes
are exempt — a stray key must never destroy a hands-free dictation.

The cleanup LLM is a hosted model that the provider can retire: a retired ID fails every request,
so `AppSettings.retiredChatModels` migrates stored IDs, and a failed cleanup is logged
(`cleanupError` in `dictations.jsonl`) and surfaced on the pill rather than silently degrading.

Persistence: GRDB/SQLite at `~/Library/Application Support/Lisper/lisper.sqlite` (`sessions`; the `weekly_tips`, `session_analyses` and `daily_insights` tables remain from earlier migrations but are unused — never drop them in place). Settings are a Codable struct in UserDefaults (`lisper.settings.v1`); the Groq API key lives in the Keychain — never in code, defaults, or the DB.

## Hard rules

- Swift language mode v5 (`.swiftLanguageMode(.v5)` on every target), platform `.macOS(.v15)`. SPM-only — do not generate an Xcode project.
- All UI colors/type/spacing come from the `Theme` namespace (`Sources/Lisper/UI/Theme.swift`); never hardcode colors elsewhere. Dark-only.
- Engine/model identifiers (e.g. `whisper-large-v3-turbo`, `openai/gpt-oss-120b`) are user-editable settings strings, never constants baked into call sites.
- LisperKit code is developed test-first; the plan gives the exact tests per task. Commit after every task using the plan's commit message.
- Coach stats are computed from **raw** transcripts (pre-cleanup), not cleaned text.
- Cleanup must preserve meaning verbatim — the LLM prompt forbids answering questions or adding content; keep that contract when touching prompts (validated by `PromptBuilderTests` and golden-transcript tests).

## Deviation policy (from the plan)

GRDB minor API differences, SwiftUI modifier availability, and similar may be fixed locally — but never change: LisperKit public type/method names other tasks depend on, Theme token names, file paths, or spec behavior. If a step's expected output can't be achieved, stop and report rather than redesigning.
