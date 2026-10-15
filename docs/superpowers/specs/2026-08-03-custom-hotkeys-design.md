# Custom hotkeys — design

**Date:** 2026-08-03
**Status:** approved, ready for planning

## Problem

The trigger key is one of six hardcoded choices — Fn, Right ⌘, Right ⌥, F13, F14, F15 — presented
as a checkbox list. A Windows keyboard attached to a Mac has none of them in a usable form: no Fn
key, no F13–F15, and while macOS maps the Windows key to ⌘ and right Alt to Right ⌥, a user cannot
be expected to know that. On such a keyboard the app is effectively untriggerable, and the only
recourse today is a code change.

The fix is to stop enumerating keys at all: let the user press whatever key they want and record it.

## Design

### 1. A hotkey is a keycode, not a case

`HotkeyChoice` (a six-case enum, stored by name) is replaced by the raw virtual keycode.

- `AppSettings.hotkeys: [HotkeyChoice]` → `AppSettings.hotkeyCodes: [UInt16]`, default `[63]` (Fn).
- The **invariant survives**: the list is deduped and may never be empty — a zero-key state makes
  the app impossible to trigger.
- `HotkeyChoice` remains in the codebase **only** as a decoding shim for stored settings (see
  Migration). Nothing else references it.

Everything a call site used to get from the enum now comes from a pure lookup table.

### 2. `KeyCatalog` — the keycode lookup table (LisperKit)

A new pure, fully unit-tested type. It answers the two questions the input path asks of a key:

```swift
public enum KeyCatalog {
    /// Display label: "Fn (🌐)", "Left ⌃", "Right ⌥", "F13", "A", "Key 42" for unknowns.
    public static func label(for keyCode: UInt16) -> String

    /// Non-nil when the key is a modifier — modifiers arrive as `flagsChanged`, every
    /// other key as keyDown/keyUp, and that routing decision is currently hardcoded per case.
    public static func modifier(for keyCode: UInt16) -> ModifierKey?

    /// Keys that produce text. Allowed as hotkeys, but the picker warns.
    public static func isPrintable(_ keyCode: UInt16) -> Bool
}

public struct ModifierKey: Equatable, Sendable {
    /// Device-DEPENDENT raw mask identifying this exact physical key, e.g. NX_DEVICERCMDKEYMASK
    /// (0x0010) for Right ⌘. Nil for Fn, which has no left/right variant.
    public let deviceMask: UInt?
    /// Device-INDEPENDENT flag name (.command, .control, …). Coarser — Left ⌘ and Right ⌘
    /// share `.command` — and used only by the watchdog's "is it still down" fallback.
    public let flagName: ModifierFlagName
}

/// LisperKit owns this as a plain enum rather than importing AppKit; `HotkeyMonitor`
/// maps it to `NSEvent.ModifierFlags` app-side, preserving the target boundary.
public enum ModifierFlagName: Equatable, Sendable {
    case function, command, option, control, shift
}
```

Modifier keycodes covered: 54 Right ⌘, 55 Left ⌘, 56 Left ⇧, 58 Left ⌥, 59 Left ⌃, 60 Right ⇧,
61 Right ⌥, 62 Right ⌃, 63 Fn. Device masks are the `NX_DEVICE*KEYMASK` constants
(`0x01` LCtrl, `0x02` LShift, `0x04` RShift, `0x08` LCmd, `0x10` RCmd, `0x20` LAlt, `0x40` RAlt,
`0x2000` RCtrl). Fn is identified by `.function` alone.

**Three keys are refused at capture**, each because it already has a job inside a recording:

| Key | Why refused |
|---|---|
| **Caps Lock** (57) | Latches rather than reporting a clean down/up — hold-to-talk cannot work on it. |
| **Space** (49) | The hands-free lock, and exempt from combo abort. As a hotkey it would collide with both. |
| **Esc** (53) | Cancels a take in flight, and cancels hotkey capture itself. |

Unknown keycodes degrade gracefully — label `"Key <n>"`, not a modifier, not printable. An unknown
key still works as a hotkey via the keyDown/keyUp path.

### 3. The picker (app target, `SettingsView`)

The checkbox list becomes an editable list:

- One row per configured key: its `KeyCatalog.label` plus a remove button. The last remaining row's
  remove button is disabled (the never-empty invariant).
- A **"+ Add key"** button arms capture. While armed the button reads "Press a key…", and:
  - `HotkeyMonitor.isPaused` is set, so the key being chosen does not also fire a recording;
  - a local `flagsChanged` + `keyDown` monitor takes the **first** key event and adds its keycode;
  - **Esc** cancels capture without adding anything;
  - **Caps Lock and Space** are refused with an inline explanation, capture stays armed;
  - a **printable** key is accepted but the row shows a warning that it will interfere with typing;
  - a **duplicate** of an existing row is ignored (capture just disarms).
- Capture always disarms after one event, accepted or refused-by-Esc.

Multi-key behaviour is unchanged and is now the answer to the mixed-keyboard case: keep Fn for the
laptop, add Left ⌃ for the Windows keyboard, both live at once.

### 4. Combo abort

Picking a real modifier like Left ⌃ means the hotkey is also a shortcut prefix. Today any press of
an enabled key starts a take, so Ctrl+C would dictate.

**Rule:** while a take is in flight, a keyDown from any *other* key aborts it — capture stops, audio
is discarded, nothing reaches the pipeline, and the hotkey's eventual release is a no-op.

**Exemptions:** Space (the hands-free lock) and Esc (already means cancel).

**Where it lives:** `RecordingKeyTap` already taps keyDown for the entire life of a recording and
already special-cases Esc and Space, so it grows one handler:

```swift
var onOtherKey: ((Int64) -> Void)?   // any keycode that is not Esc or Space
```

The foreign key is **passed through unmodified** (unlike Esc/Space, which are swallowed) — Ctrl+C
must still reach the frontmost app. Modifier-only combos (Ctrl+Shift) emit no keyDown and therefore
never abort, which is harmless.

**Pill timing:** audio capture still starts instantly on key-down so no speech is lost, but the pill
is shown ~200 ms later. An abort inside that window shows nothing at all — no pill, no transcript,
no history row, matching how a cancelled take already behaves. An abort after the pill is visible
hides it. Aborted takes are not written to `dictations.jsonl` as `tooShort`; they never enter the
pipeline.

**Side benefit:** Fn+Delete and Fn+arrow (forward-delete, Home/End) stop producing stray takes,
which they do today.

### 5. Migration

Tolerant decoding, matching the existing pattern in `AppSettings.init(from:)`:

1. `hotkeyCodes: [UInt16]` present → use it.
2. Else legacy `hotkeys: [HotkeyChoice]` → map each case to its keycode.
3. Else legacy single `hotkey: HotkeyChoice` → one-element list.
4. Else default `[63]`.

Then dedupe, and fall back to `[63]` if the result is empty. A decode failure must never throw —
`SettingsStore` resets *everything* to defaults on error.

### 6. What is unchanged

`HotkeySetDecision` is already keyed by `UInt16` internally; it loses its `enabled: [HotkeyChoice]`
parameter in favour of `Set<UInt16>` and keeps ownership arbitration, `heldKeys` dedup, and
`shouldSynthesizeRelease` exactly as they are. Hold vs toggle mode, the Fn→Space lock
(`RecordingGesture`), the watchdog, and the whole pipeline are untouched.

`HotkeyMonitor.handleFlags` stops switching on enum cases and reads the flag bit from
`KeyCatalog.modifier(for:)?.deviceMask` instead, falling back to `.function` for Fn. This is the
one place where the six-case switch is genuinely replaced rather than renamed.

## Testing

LisperKit (Swift Testing, `swift run LisperKitTests`):

- **KeyCatalog** — labels for each known modifier, F-keys and letters; `"Key 42"` for unknowns;
  `modifier(for:)` returns the right device mask for Left ⌃ (0x01) and Right ⌘ (0x10) and `nil` for
  F13; Fn has a nil `deviceMask` but a `.function` flag; Caps Lock is absent; `isPrintable` true for
  letters and digits, false for modifiers and F-keys; Caps Lock, Space and Esc are all refusable.
- **Settings migration** — `["fn"]` → `[63]`; `["rightCommand","f13"]` → `[54,105]`; legacy singular
  `"rightCommand"` → `[54]`; missing key → `[63]`; explicit empty array → `[63]`; duplicates deduped;
  a round-trip encode/decode is stable.
- **Abort decision** — a pure helper covering: foreign key while a take is owned → abort; Space →
  no abort (lock); Esc → no abort (existing cancel path); foreign key with no take in flight → no-op;
  the hotkey's own keycode → no abort.
- **HotkeySetDecision** — existing suite ported to `Set<UInt16>`, behaviour identical.

App target (manual, per `docs/DEBUGGING-LOG.md` practice): capture Left ⌃ on the Windows keyboard,
confirm hold-to-talk works, confirm Ctrl+C aborts silently and still copies, confirm Fn still works
alongside it, confirm the setting survives a relaunch.

## Risks

- **A bad capture bricks the trigger.** Mitigated by the never-empty invariant, the ability to
  remove rows, and Fn remaining in the list unless explicitly removed.
- **Abort fires when it shouldn't.** The tap only exists during a recording, and only two keys are
  exempt; if a user's flow needs another exemption it is a one-line addition.
- **`KeyCatalog` device masks are the fiddly part** — they are the same constants
  `HotkeyMonitor.handleFlags` already hardcodes for Right ⌘/⌥, extended to the remaining modifiers,
  and are unit-tested directly.
