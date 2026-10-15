# Sub-bass UI cues + live Fn-key muting

Date: 2026-06-13 · Status: implemented

Two post-v0.1 refinements, both approved interactively (sound candidates were
auditioned as generated WAVs before selection).

## 1. Muted, cinematic UI cues

The original start/cancel cues (E5→G5 / G4→D4 sine melodies at volume 0.22)
read as chirpy. Replaced with an "Interstellar" register — felt more than
heard:

- **Start**: sub-bass pulse on E2 (82.41 Hz) with a faint airy overtone
  (6th harmonic at 0.06), 50 ms swell, `exp(-5.5t)` decay, 0.5 s.
- **Cancel**: the same sub voice gliding down a fourth (E2 → B1) over 0.35 s,
  softer (0.34 amplitude) — the take dissolving rather than ending.
- Both get a fake-reverb tail: two delayed copies (90 ms @ 0.30, 180 ms @ 0.12)
  summed in for a sense of space.
- Volume lowered 0.22 → 0.13. Quieter cues also bleed less into the mic
  capture at recording start.

Still synthesized in memory at 16 kHz via `WavEncoder`/`NSSound` — no bundled
assets. File: `Sources/Lisper/Audio/UISounds.swift` (app target, no unit
tests per the LisperKit boundary).

## 2. Fn-key language switching despite FnKeyGuard

**Bug**: `FnKeyGuard` wrote `AppleFnUsageType = 0` correctly, but tapping Fn
still switched keyboard layout.

**Root cause**: the Globe-key action is performed by long-lived system agents
(`com.apple.TextInputSwitcher`, `com.apple.TextInputMenuAgent`) that read the
preference once at launch. A `CFPreferences` write never reaches a running
agent — System Settings notifies them through a private channel we can't use.
Confirmed on-machine: the pref was already 0 on disk while TextInputSwitcher
had been alive since before Lisper first wrote it.

**Fix**: every `FnKeyGuard.write()` (both mute and restore) now force-quits
those two agents via `NSWorkspace`; launchd respawns them on demand with the
fresh value. They are stateless UI agents — respawn is instant and side-effect
free. Chosen over the alternative (a one-time prompt asking the user to set
"Press 🌐 key to: Do Nothing" manually) to keep the experience zero-config.

Note: `mute()` still early-returns when the pref is already 0, so it won't
churn agents on every settings save; the one historical stale state on this
machine was repaired manually once.
