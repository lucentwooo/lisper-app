# Custom Hotkeys Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user set any keyboard key as the dictation trigger by pressing it, so a Windows keyboard (no Fn, no F13–F15, no obvious ⌘) can drive the app.

**Architecture:** A hotkey stops being one of six enum cases and becomes a raw virtual keycode. A new pure `KeyCatalog` table in LisperKit turns a keycode into a display label, a modifier descriptor (which decides `flagsChanged` vs `keyDown` routing), and a refusal reason for keys that already have a job. Settings store `[UInt16]`, migrating from the old named list. Because a freely-chosen key may also be a shortcut modifier (Left ⌃), an in-flight take is silently abandoned when any other key joins the hold.

**Tech Stack:** Swift 5 language mode, SPM only, Swift Testing (`swift run LisperKitTests`), AppKit/SwiftUI app shell, GRDB.

**Spec:** `docs/superpowers/specs/2026-08-03-custom-hotkeys-design.md`

## Global Constraints

- Swift language mode v5 (`.swiftLanguageMode(.v5)` on every target), platform `.macOS(.v15)`. SPM only — never generate an Xcode project.
- ALL logic lives in `Sources/LisperKit/` and is unit-tested. `Sources/Lisper/` stays a thin AppKit/SwiftUI shell.
- LisperKit must NOT import AppKit. Anything AppKit-shaped (`NSEvent.ModifierFlags`) is represented as a plain enum in LisperKit and mapped app-side.
- Run tests with `swift run LisperKitTests` (full suite, no `--filter`). **`swift test` exits 0 but executes nothing on this machine — never trust it.**
- All UI colors/type/spacing come from the `Theme` namespace. Dark-only.
- The configured hotkey list is **deduped and never empty** — a zero-key state makes the app impossible to trigger.
- Commit after every task using the message given in that task's final step.

---

### Task 1: `KeyCatalog` — keycode → label, modifier, refusal

**Files:**
- Create: `Sources/LisperKit/Input/KeyCatalog.swift`
- Test: `Tests/LisperKitTests/KeyCatalogTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `ModifierFlagName` (enum: `.function/.command/.option/.control/.shift`), `ModifierKey` (struct: `deviceMask: UInt?`, `flagName: ModifierFlagName`), `HotkeyRejection` (enum: `.capsLock/.space/.escape`, with `.reason: String`), and `KeyCatalog` with statics `fn/space/escape/capsLock: UInt16`, `label(for:) -> String`, `modifier(for:) -> ModifierKey?`, `isPrintable(_:) -> Bool`, `rejection(for:) -> HotkeyRejection?`.

- [ ] **Step 1: Write the failing test**

Create `Tests/LisperKitTests/KeyCatalogTests.swift`:

```swift
import Testing
@testable import LisperKit

@Suite struct KeyCatalogTests {

    // MARK: labels

    @Test func testLabelsNameTheModifierSideExplicitly() {
        #expect(KeyCatalog.label(for: 59) == "Left ⌃")
        #expect(KeyCatalog.label(for: 62) == "Right ⌃")
        #expect(KeyCatalog.label(for: 54) == "Right ⌘")
        #expect(KeyCatalog.label(for: 55) == "Left ⌘")
        #expect(KeyCatalog.label(for: 63) == "Fn (🌐)")
    }

    @Test func testLabelsCoverFKeysAndLetters() {
        #expect(KeyCatalog.label(for: 105) == "F13")
        #expect(KeyCatalog.label(for: 0) == "A")
        #expect(KeyCatalog.label(for: 18) == "1")
    }

    /// An unknown keycode must still be usable as a hotkey — it just gets a dull name.
    @Test func testUnknownKeyCodeGetsAFallbackLabel() {
        #expect(KeyCatalog.label(for: 200) == "Key 200")
    }

    // MARK: modifiers

    /// The device-DEPENDENT mask identifies the exact physical key; it is what
    /// `HotkeyMonitor.handleFlags` tests against a `flagsChanged` event.
    @Test func testModifiersCarryTheirDeviceMask() {
        #expect(KeyCatalog.modifier(for: 59)?.deviceMask == 0x0001)   // Left ⌃
        #expect(KeyCatalog.modifier(for: 62)?.deviceMask == 0x2000)   // Right ⌃
        #expect(KeyCatalog.modifier(for: 54)?.deviceMask == 0x0010)   // Right ⌘
        #expect(KeyCatalog.modifier(for: 55)?.deviceMask == 0x0008)   // Left ⌘
        #expect(KeyCatalog.modifier(for: 61)?.deviceMask == 0x0040)   // Right ⌥
        #expect(KeyCatalog.modifier(for: 58)?.deviceMask == 0x0020)   // Left ⌥
        #expect(KeyCatalog.modifier(for: 56)?.deviceMask == 0x0002)   // Left ⇧
        #expect(KeyCatalog.modifier(for: 60)?.deviceMask == 0x0004)   // Right ⇧
    }

    /// Fn has no left/right variant and therefore no device mask — it is identified
    /// by the `.function` flag alone.
    @Test func testFnHasNoDeviceMaskButAFunctionFlag() {
        let fn = KeyCatalog.modifier(for: 63)
        #expect(fn?.deviceMask == nil)
        #expect(fn?.flagName == .function)
    }

    /// The coarse flag is what the watchdog falls back to; left and right share one.
    @Test func testLeftAndRightShareADeviceIndependentFlagName() {
        #expect(KeyCatalog.modifier(for: 54)?.flagName == .command)
        #expect(KeyCatalog.modifier(for: 55)?.flagName == .command)
        #expect(KeyCatalog.modifier(for: 59)?.flagName == .control)
        #expect(KeyCatalog.modifier(for: 62)?.flagName == .control)
    }

    /// Non-modifiers route through keyDown/keyUp instead of flagsChanged.
    @Test func testNonModifiersHaveNoModifierEntry() {
        #expect(KeyCatalog.modifier(for: 105) == nil)   // F13
        #expect(KeyCatalog.modifier(for: 0) == nil)     // A
        #expect(KeyCatalog.modifier(for: 200) == nil)   // unknown
    }

    // MARK: refusals

    /// Each refused key already has a job inside a recording.
    @Test func testKeysWithAnExistingJobAreRefused() {
        #expect(KeyCatalog.rejection(for: 57) == .capsLock)
        #expect(KeyCatalog.rejection(for: 49) == .space)
        #expect(KeyCatalog.rejection(for: 53) == .escape)
    }

    @Test func testOrdinaryKeysAreNotRefused() {
        #expect(KeyCatalog.rejection(for: 59) == nil)
        #expect(KeyCatalog.rejection(for: 63) == nil)
        #expect(KeyCatalog.rejection(for: 0) == nil)
    }

    @Test func testEveryRejectionExplainsItself() {
        for r in [HotkeyRejection.capsLock, .space, .escape] {
            #expect(!r.reason.isEmpty)
        }
    }

    /// Caps Lock latches instead of reporting down/up, so it is not a usable modifier
    /// hotkey even though it is physically a modifier.
    @Test func testCapsLockIsNotOfferedAsAModifier() {
        #expect(KeyCatalog.modifier(for: 57) == nil)
    }

    // MARK: printable

    @Test func testPrintableKeysAreFlaggedSoThePickerCanWarn() {
        #expect(KeyCatalog.isPrintable(0))    // A
        #expect(KeyCatalog.isPrintable(18))   // 1
        #expect(!KeyCatalog.isPrintable(59))  // Left ⌃
        #expect(!KeyCatalog.isPrintable(105)) // F13
        #expect(!KeyCatalog.isPrintable(49))  // Space is refused, not "printable"
    }

    // MARK: named constants

    @Test func testNamedConstantsMatchTheirKeyCodes() {
        #expect(KeyCatalog.fn == 63)
        #expect(KeyCatalog.space == 49)
        #expect(KeyCatalog.escape == 53)
        #expect(KeyCatalog.capsLock == 57)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift build 2>&1 | tail -5`
Expected: compile errors — `cannot find 'KeyCatalog' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/LisperKit/Input/KeyCatalog.swift`:

```swift
// Sources/LisperKit/Input/KeyCatalog.swift

/// Device-INDEPENDENT modifier identity. LisperKit owns this as a plain enum rather than
/// importing AppKit; `HotkeyMonitor` maps it to `NSEvent.ModifierFlags` app-side.
public enum ModifierFlagName: String, Equatable, Sendable {
    case function, command, option, control, shift
}

/// What the input path needs to know about a modifier key.
public struct ModifierKey: Equatable, Sendable {
    /// Device-DEPENDENT raw mask identifying this EXACT physical key (`NX_DEVICE*KEYMASK`),
    /// e.g. 0x0010 for Right ⌘. This is what distinguishes left from right in a
    /// `flagsChanged` event. Nil for Fn, which has no left/right variant.
    public let deviceMask: UInt?
    /// Coarse, device-independent flag. Left ⌘ and Right ⌘ share `.command`, so this can
    /// only answer "is SOME command key down" — used solely by the watchdog's fallback.
    public let flagName: ModifierFlagName

    public init(deviceMask: UInt?, flagName: ModifierFlagName) {
        self.deviceMask = deviceMask
        self.flagName = flagName
    }
}

/// Why a key may not be used as a hotkey.
public enum HotkeyRejection: Equatable, Sendable {
    case capsLock, space, escape

    public var reason: String {
        switch self {
        case .capsLock: return "Caps Lock latches instead of reporting a press and release, so hold-to-talk can't work on it."
        case .space:    return "Space locks a recording hands-free while you hold the hotkey."
        case .escape:   return "Esc cancels a recording in progress."
        }
    }
}

/// Pure lookup table mapping a virtual keycode to everything the hotkey path needs:
/// a display label, whether it is a modifier (which decides `flagsChanged` vs
/// `keyDown`/`keyUp` routing), and whether it is refused as a hotkey.
///
/// Replaces the old six-case `HotkeyChoice` enum, which made the trigger key a
/// closed set and left a Windows keyboard — no Fn, no F13–F15 — with nothing to press.
public enum KeyCatalog {
    public static let space: UInt16 = 49
    public static let escape: UInt16 = 53
    public static let capsLock: UInt16 = 57
    public static let fn: UInt16 = 63

    /// Caps Lock (57) is deliberately ABSENT: it is physically a modifier but latches,
    /// so it can never drive hold-to-talk. `rejection(for:)` turns it away at capture.
    private static let modifiers: [UInt16: ModifierKey] = [
        54: ModifierKey(deviceMask: 0x0010, flagName: .command),   // Right ⌘
        55: ModifierKey(deviceMask: 0x0008, flagName: .command),   // Left ⌘
        56: ModifierKey(deviceMask: 0x0002, flagName: .shift),     // Left ⇧
        58: ModifierKey(deviceMask: 0x0020, flagName: .option),    // Left ⌥
        59: ModifierKey(deviceMask: 0x0001, flagName: .control),   // Left ⌃
        60: ModifierKey(deviceMask: 0x0004, flagName: .shift),     // Right ⇧
        61: ModifierKey(deviceMask: 0x0040, flagName: .option),    // Right ⌥
        62: ModifierKey(deviceMask: 0x2000, flagName: .control),   // Right ⌃
        63: ModifierKey(deviceMask: nil,    flagName: .function),  // Fn (🌐)
    ]

    /// Keys that type something. Allowed as hotkeys — the picker just warns.
    private static let printableNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 47: ".", 50: "`",
        31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
    ]

    private static let otherNames: [UInt16: String] = [
        54: "Right ⌘", 55: "Left ⌘", 56: "Left ⇧", 58: "Left ⌥", 59: "Left ⌃",
        60: "Right ⇧", 61: "Right ⌥", 62: "Right ⌃", 63: "Fn (🌐)",
        49: "Space", 53: "Esc", 57: "Caps Lock", 36: "Return", 48: "Tab", 51: "Delete",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    /// Never fails: an unrecognised keycode still works as a hotkey, it just reads dully.
    public static func label(for keyCode: UInt16) -> String {
        printableNames[keyCode] ?? otherNames[keyCode] ?? "Key \(keyCode)"
    }

    /// Non-nil only for keys that arrive as `flagsChanged`.
    public static func modifier(for keyCode: UInt16) -> ModifierKey? {
        modifiers[keyCode]
    }

    public static func isPrintable(_ keyCode: UInt16) -> Bool {
        printableNames[keyCode] != nil
    }

    /// Non-nil when the key already has a job inside a recording and cannot be a hotkey.
    public static func rejection(for keyCode: UInt16) -> HotkeyRejection? {
        switch keyCode {
        case capsLock: return .capsLock
        case space:    return .space
        case escape:   return .escape
        default:       return nil
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift run LisperKitTests 2>&1 | tail -3`
Expected: `Test run with 20X tests in 32 suites passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/LisperKit/Input/KeyCatalog.swift Tests/LisperKitTests/KeyCatalogTests.swift
git commit -m "feat: KeyCatalog maps any keycode to label, modifier and refusal"
```

---

### Task 2: Settings store raw keycodes, migrating from named choices

**Files:**
- Modify: `Sources/LisperKit/Settings/AppSettings.swift`
- Test: `Tests/LisperKitTests/SettingsTests.swift`

**Interfaces:**
- Consumes: `KeyCatalog.fn` from Task 1.
- Produces: `AppSettings.hotkeyCodes: [UInt16]` (default `[63]`), replacing `AppSettings.hotkeys: [HotkeyChoice]`. `HotkeyChoice` survives as a legacy decode-only enum exposing `keyCode: UInt16`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/LisperKitTests/SettingsTests.swift`, inside the existing suite:

```swift
    // MARK: hotkey keycode migration

    /// A blob written by the multi-key version stores NAMES; they map to keycodes.
    @Test func testNamedHotkeyListMigratesToKeyCodes() throws {
        let stored = """
        {"hotkeys":["rightCommand","f13"],"hotkeyMode":"hold"}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: stored)
        #expect(s.hotkeyCodes == [54, 105])
    }

    /// The oldest blobs store a single name under `hotkey`.
    @Test func testLegacySingleHotkeyMigratesToOneKeyCode() throws {
        let stored = """
        {"hotkey":"rightCommand","hotkeyMode":"hold"}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: stored)
        #expect(s.hotkeyCodes == [54])
    }

    /// Current blobs store the codes directly and must win over any legacy key.
    @Test func testStoredKeyCodesWinOverLegacyNames() throws {
        let stored = """
        {"hotkeyCodes":[59],"hotkeys":["fn"],"hotkeyMode":"hold"}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: stored)
        #expect(s.hotkeyCodes == [59])
    }

    @Test func testMissingHotkeyKeyFallsBackToFn() throws {
        let stored = """
        {"hotkeyMode":"hold"}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: stored)
        #expect(s.hotkeyCodes == [63])
    }

    /// INVARIANT: never empty — a zero-key state makes the app impossible to trigger.
    @Test func testExplicitlyEmptyKeyCodeListFallsBackToFn() throws {
        let stored = """
        {"hotkeyCodes":[],"hotkeyMode":"hold"}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: stored)
        #expect(s.hotkeyCodes == [63])
    }

    @Test func testDuplicateKeyCodesAreDeduped() throws {
        let stored = """
        {"hotkeyCodes":[63,59,63],"hotkeyMode":"hold"}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: stored)
        #expect(s.hotkeyCodes == [63, 59])
    }

    @Test func testKeyCodesSurviveAnEncodeDecodeRoundTrip() throws {
        var s = AppSettings()
        s.hotkeyCodes = [59, 105]
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(back.hotkeyCodes == [59, 105])
    }
```

Then update the existing `testDefaults` assertion — replace the `hotkeys` line:

```swift
        #expect(s.hotkeyCodes == [63])   // Fn
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift build 2>&1 | tail -5`
Expected: `value of type 'AppSettings' has no member 'hotkeyCodes'`.

- [ ] **Step 3: Write the implementation**

In `Sources/LisperKit/Settings/AppSettings.swift`:

**3a.** Reduce `HotkeyChoice` to a decode-only shim — replace the whole enum with:

```swift
/// LEGACY. The trigger key is a raw keycode now (`AppSettings.hotkeyCodes`); this enum
/// exists ONLY to decode settings blobs written before that change. Do not add cases,
/// do not reference it outside `AppSettings.init(from:)`.
public enum HotkeyChoice: String, Codable, Sendable {
    case fn, rightCommand, rightOption, f13, f14, f15

    public var keyCode: UInt16 {
        switch self {
        case .fn: return 63             // kVK_Function
        case .rightCommand: return 54
        case .rightOption: return 61
        case .f13: return 105
        case .f14: return 107
        case .f15: return 113
        }
    }
}
```

**3b.** Replace the stored property:

```swift
    /// Every enabled trigger keycode. All are live at once so the app works across a
    /// laptop keyboard (Fn) and an external one (a Windows keyboard's Left ⌃) without
    /// changing a setting. Labels come from `KeyCatalog.label(for:)`.
    /// INVARIANT: deduped, and never empty — an empty list would make the app impossible
    /// to trigger.
    public var hotkeyCodes: [UInt16] = [KeyCatalog.fn]
```

**3c.** Add `hotkeyCodes` to `CodingKeys` (keep `hotkey` and `hotkeys` for migration):

```swift
        case hotkey, hotkeys, hotkeyCodes, hotkeyMode, sttEngine, llmCleanupEnabled
```

**3d.** Replace the migration block in `init(from:)`:

```swift
        // Migration ladder: `hotkeyCodes` (current) -> named `hotkeys` -> legacy single
        // `hotkey` -> default [Fn]. Deduped, and never allowed to be empty.
        let storedCodes = try c.decodeIfPresent([UInt16].self, forKey: .hotkeyCodes)
        let namedList = try c.decodeIfPresent([HotkeyChoice].self, forKey: .hotkeys)
        let legacyName = try c.decodeIfPresent(HotkeyChoice.self, forKey: .hotkey)
        var resolved = storedCodes
            ?? namedList?.map(\.keyCode)
            ?? legacyName.map { [$0.keyCode] }
            ?? d.hotkeyCodes
        var seen = Set<UInt16>()
        resolved = resolved.filter { seen.insert($0).inserted }
        hotkeyCodes = resolved.isEmpty ? d.hotkeyCodes : resolved
```

**3e.** In `encode(to:)` replace the hotkeys line with:

```swift
        try c.encode(hotkeyCodes, forKey: .hotkeyCodes)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift run LisperKitTests 2>&1 | tail -3`
Expected: all tests pass. The app target will NOT compile yet (Task 4 fixes it) — that is expected; `swift build` failures confined to `Sources/Lisper/` are fine at this point.

- [ ] **Step 5: Commit**

```bash
git add Sources/LisperKit/Settings/AppSettings.swift Tests/LisperKitTests/SettingsTests.swift
git commit -m "feat: store hotkeys as raw keycodes, migrating from named choices"
```

---

### Task 3: `HotkeySetDecision` keyed by keycode set

**Files:**
- Modify: `Sources/LisperKit/Input/HotkeySetDecision.swift`
- Test: `Tests/LisperKitTests/HotkeySetDecisionTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `HotkeySetDecision(enabled: Set<UInt16>)`, `owner: UInt16?`, `isEnabled(_ keyCode: UInt16) -> Bool`, and `isDown(eventKeyCode:hotkeyCode:flagSet:physicallyDown:) -> Bool?`. `press`, `release`, `clearOwner`, `reset`, `heldKeys`, and `shouldSynthesizeRelease` keep their current signatures and behaviour.

- [ ] **Step 1: Update the tests to the new API**

In `Tests/LisperKitTests/HotkeySetDecisionTests.swift`, mechanically replace throughout:
- `HotkeySetDecision(enabled: [.fn])` → `HotkeySetDecision(enabled: [63])`
- `HotkeySetDecision(enabled: [.fn, .f13])` → `HotkeySetDecision(enabled: [63, 105])`
- `HotkeySetDecision(enabled: [.f13])` → `HotkeySetDecision(enabled: [105])`
- `HotkeyChoice.fn.keyCode` → `63`, `HotkeyChoice.f13.keyCode` → `105`
- `d.owner == .fn` → `d.owner == 63`, `d.owner == .f13` → `d.owner == 105`
- `d.choice(forKeyCode: 105) == nil` → `!d.isEnabled(105)`
- In the two `isDown` tests and the negation test: `choice: .fn` → `hotkeyCode: 63`

Add one new test covering the enabled-set gate:

```swift
    @Test func testIsEnabledReflectsTheConfiguredSet() {
        let d = HotkeySetDecision(enabled: [63, 59])
        #expect(d.isEnabled(63))
        #expect(d.isEnabled(59))
        #expect(!d.isEnabled(105))
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build 2>&1 | tail -5`
Expected: `cannot convert value of type '[UInt16]' to expected argument type '[HotkeyChoice]'`.

- [ ] **Step 3: Write the implementation**

In `Sources/LisperKit/Input/HotkeySetDecision.swift`:

```swift
    public let enabled: Set<UInt16>
    public private(set) var owner: UInt16?

    public init(enabled: Set<UInt16>) {
        self.enabled = enabled
    }

    /// Is this keycode one of the configured trigger keys?
    public func isEnabled(_ keyCode: UInt16) -> Bool {
        enabled.contains(keyCode)
    }
```

Update `press` / `release` to use it (behaviour unchanged — only the lookup changes):

```swift
    public mutating func press(keyCode: UInt16) -> Bool {
        guard isEnabled(keyCode) else { return false }
        // Already down: an auto-repeat, or a spurious modifier event mid-hold. Not an edge,
        // and deliberately checked BEFORE ownership so it still holds after `clearOwner()`.
        guard !heldKeys.contains(keyCode) else { return false }
        heldKeys.insert(keyCode)
        guard owner == nil else { return false }   // a non-owning key
        owner = keyCode
        return true
    }

    public mutating func release(keyCode: UInt16) -> Bool {
        heldKeys.remove(keyCode)
        guard isEnabled(keyCode), keyCode == owner else { return false }
        owner = nil
        return true
    }
```

And `isDown`, which no longer needs the enum:

```swift
    public static func isDown(eventKeyCode: UInt16, hotkeyCode: UInt16,
                              flagSet: Bool, physicallyDown: Bool) -> Bool? {
        guard eventKeyCode == hotkeyCode else { return nil }
        return flagSet || physicallyDown
    }
```

Delete the now-unused `choice(forKeyCode:)`. Update the doc comment's reference to
`HotkeyChoice` so it names `KeyCatalog` instead.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift run LisperKitTests 2>&1 | tail -3`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LisperKit/Input/HotkeySetDecision.swift Tests/LisperKitTests/HotkeySetDecisionTests.swift
git commit -m "refactor: key HotkeySetDecision by keycode instead of named choice"
```

---

### Task 4: Route any keycode through `HotkeyMonitor` and the app shell

**Files:**
- Modify: `Sources/Lisper/Input/HotkeyMonitor.swift`
- Modify: `Sources/Lisper/AppDelegate.swift` (lines ~75, ~110-115)
- Modify: `Sources/Lisper/UI/Main/HistoryView.swift`
- Modify: `Sources/Lisper/UI/Onboarding/OnboardingView.swift`

**Interfaces:**
- Consumes: `KeyCatalog` (Task 1), `AppSettings.hotkeyCodes` (Task 2), `HotkeySetDecision(enabled:)`, `isEnabled`, `isDown(eventKeyCode:hotkeyCode:…)` (Task 3).
- Produces: `HotkeyMonitor.configure(hotkeyCodes: [UInt16], mode: HotkeyMode)` and `HotkeyMonitor.hotkeyCodes: [UInt16]`.

This task has no unit tests — it is app-shell wiring. Its gate is a clean build plus the manual check in Step 4.

- [ ] **Step 1: Rewrite the monitor's key handling**

In `Sources/Lisper/Input/HotkeyMonitor.swift`:

**1a.** Replace the stored config:

```swift
    private(set) var hotkeyCodes: [UInt16] = [KeyCatalog.fn]
    private var decision = HotkeySetDecision(enabled: [KeyCatalog.fn])
```

**1b.** Replace `configure`:

```swift
    func configure(hotkeyCodes: [UInt16], mode: HotkeyMode) {
        self.hotkeyCodes = hotkeyCodes.isEmpty ? [KeyCatalog.fn] : hotkeyCodes
        self.decision = HotkeySetDecision(enabled: Set(self.hotkeyCodes))
        self.mode = mode
        stop(); start()
    }
```

**1c.** Replace `handleFlags`'s per-case switch with the catalog lookup:

```swift
    private func handleFlags(_ event: NSEvent) {
        guard !isPaused else { return }
        // Only modifier hotkeys arrive as flagsChanged.
        guard decision.isEnabled(event.keyCode),
              let mod = KeyCatalog.modifier(for: event.keyCode) else { return }
        let physical = CGEventSource.keyState(.combinedSessionState, key: event.keyCode)
        // The device-DEPENDENT mask is what distinguishes Left ⌃ from Right ⌃ in the raw
        // flags. Fn has no such mask and is identified by `.function` alone.
        let flagSet: Bool
        if let mask = mod.deviceMask {
            flagSet = event.modifierFlags.rawValue & mask != 0
        } else {
            flagSet = event.modifierFlags.contains(.function)
        }
        guard let isDown = HotkeySetDecision.isDown(eventKeyCode: event.keyCode,
                                                    hotkeyCode: event.keyCode,
                                                    flagSet: flagSet, physicallyDown: physical)
        else { return }   // not ours — ignore, never a release
        HotkeyTrace.log("flags key=\(KeyCatalog.label(for: event.keyCode)) code=\(event.keyCode) flag=\(flagSet) phys=\(physical) -> down=\(isDown)")
        transition(keyCode: event.keyCode, down: isDown)
    }
```

**1d.** Replace `handleKey`'s guard:

```swift
        guard decision.isEnabled(event.keyCode),
              KeyCatalog.modifier(for: event.keyCode) == nil else { return }
        transition(keyCode: event.keyCode, down: down)
```

**1e.** Create `Sources/Lisper/Input/ModifierFlagName+AppKit.swift` — the one place
LisperKit's plain enum meets AppKit. Task 6's capture controller uses it too, so it must
not live inside `HotkeyMonitor`:

```swift
// Sources/Lisper/Input/ModifierFlagName+AppKit.swift
import AppKit
import LisperKit

extension ModifierFlagName {
    /// The device-INDEPENDENT AppKit flag for this modifier. Left and Right variants share
    /// one flag, so this can only answer "is SOME control key down", never which one.
    var nsFlag: NSEvent.ModifierFlags {
        switch self {
        case .function: return .function
        case .command:  return .command
        case .option:   return .option
        case .control:  return .control
        case .shift:    return .shift
        }
    }
}
```

**1f.** Replace `currentFlagSet(forKeyCode:)`'s switch with the shared mapping:

```swift
    private func currentFlagSet(forKeyCode keyCode: UInt16) -> Bool {
        guard let mod = KeyCatalog.modifier(for: keyCode) else { return false }
        return NSEvent.modifierFlags.contains(mod.flagName.nsFlag)
    }
```

Keep its existing doc comment about device-independence, updating "Right ⌘" phrasing to
mention that Left and Right variants share one flag.

- [ ] **Step 2: Update the app shell's call sites**

In `Sources/Lisper/AppDelegate.swift` — three edits:

```swift
        hotkey.configure(hotkeyCodes: s.hotkeyCodes, mode: s.hotkeyMode)
```
(both occurrences, ~line 75 and ~line 113)

```swift
        if s.hotkeyCodes != hotkey.hotkeyCodes || s.hotkeyMode != hotkey.mode {
```

```swift
        if s.hotkeyCodes.contains(KeyCatalog.fn) { FnKeyGuard.mute() }
```
and the `else` variant:
```swift
        if s.hotkeyCodes.contains(KeyCatalog.fn) { FnKeyGuard.mute() } else { FnKeyGuard.restore() }
```

In `Sources/Lisper/UI/Main/HistoryView.swift`:

```swift
                    Text("Hold \(model.settings.hotkeyCodes.map(KeyCatalog.label(for:)).joined(separator: " or ")) anywhere and start talking")
```

In `Sources/Lisper/UI/Onboarding/OnboardingView.swift`:

```swift
                let keyLabels = model.settings.hotkeyCodes.map(KeyCatalog.label(for:)).joined(separator: " or ")
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`. `SettingsView.swift` still references the old API — if it
errors, leave a minimal temporary fix ONLY if trivial; otherwise complete Task 6's
`SettingsView` rewrite before building. (Recommended order: do Task 6 immediately after
this one.)

- [ ] **Step 4: Verify the existing hotkey still works**

Run: `./scripts/run.sh`
Then hold Fn, say a sentence, release. Expected: the pill appears, text is pasted, and
`/tmp/lisper-hotkey.log` shows `flags key=Fn (🌐) code=63 … -> down=true` followed by a
release. Confirm no watchdog line fires mid-hold.

- [ ] **Step 5: Commit**

```bash
git add Sources/Lisper/Input/HotkeyMonitor.swift Sources/Lisper/AppDelegate.swift Sources/Lisper/UI/Main/HistoryView.swift Sources/Lisper/UI/Onboarding/OnboardingView.swift
git commit -m "refactor: drive the hotkey monitor from keycodes via KeyCatalog"
```

---

### Task 5: Abort a take when another key joins the hold

**Files:**
- Create: `Sources/LisperKit/Input/RecordingAbortDecision.swift`
- Test: `Tests/LisperKitTests/RecordingAbortDecisionTests.swift`
- Modify: `Sources/Lisper/Input/RecordingKeyTap.swift`
- Modify: `Sources/Lisper/AppDelegate.swift`

**Interfaces:**
- Consumes: `KeyCatalog.space`, `KeyCatalog.escape` (Task 1); `AppSettings.hotkeyCodes` (Task 2).
- Produces: `RecordingAbortDecision.shouldAbort(keyCode:hotkeyCodes:isRecording:) -> Bool`; `RecordingKeyTap.onOtherKey: ((Int64) -> Void)?`.

- [ ] **Step 1: Write the failing test**

Create `Tests/LisperKitTests/RecordingAbortDecisionTests.swift`:

```swift
import Testing
@testable import LisperKit

/// Choosing a real shortcut modifier (Left ⌃) as the hotkey means the trigger key is also
/// a shortcut prefix. Without this rule every ⌃C would dictate.
@Suite struct RecordingAbortDecisionTests {

    private let hotkeys: Set<UInt16> = [59]   // Left ⌃

    @Test func testAForeignKeyDuringATakeAbortsIt() {
        #expect(RecordingAbortDecision.shouldAbort(keyCode: 8,   // C
                                                   hotkeyCodes: hotkeys,
                                                   isRecording: true))
    }

    /// Space is the hands-free lock — it must never abort.
    @Test func testSpaceDoesNotAbort() {
        #expect(!RecordingAbortDecision.shouldAbort(keyCode: KeyCatalog.space,
                                                    hotkeyCodes: hotkeys,
                                                    isRecording: true))
    }

    /// Esc already means "cancel", handled by its own path with its own sound.
    @Test func testEscapeDoesNotAbort() {
        #expect(!RecordingAbortDecision.shouldAbort(keyCode: KeyCatalog.escape,
                                                    hotkeyCodes: hotkeys,
                                                    isRecording: true))
    }

    /// A non-modifier hotkey (F13) DOES emit keyDown — it must not abort its own take.
    @Test func testTheHotkeyItselfDoesNotAbort() {
        #expect(!RecordingAbortDecision.shouldAbort(keyCode: 105,
                                                    hotkeyCodes: [105],
                                                    isRecording: true))
    }

    /// A second enabled hotkey is still "one of ours" and must not kill the first's take.
    @Test func testAnotherEnabledHotkeyDoesNotAbort() {
        #expect(!RecordingAbortDecision.shouldAbort(keyCode: 105,
                                                    hotkeyCodes: [63, 105],
                                                    isRecording: true))
    }

    @Test func testNothingAbortsWhenNoTakeIsInFlight() {
        #expect(!RecordingAbortDecision.shouldAbort(keyCode: 8,
                                                    hotkeyCodes: hotkeys,
                                                    isRecording: false))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build 2>&1 | tail -5`
Expected: `cannot find 'RecordingAbortDecision' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/LisperKit/Input/RecordingAbortDecision.swift`:

```swift
// Sources/LisperKit/Input/RecordingAbortDecision.swift

/// Should a keystroke arriving mid-take abandon it?
///
/// Once the trigger key can be ANY key, it can be a real shortcut modifier — Left ⌃ is the
/// obvious pick on a Windows keyboard, and it is also the prefix of ⌃C, ⌃A, ⌃←. Without
/// this rule every one of those shortcuts would start dictating.
///
/// The take is abandoned silently: no pill, no transcript, no history row, nothing in
/// `dictations.jsonl` — it never reaches the pipeline. The foreign keystroke itself is
/// passed through untouched, so ⌃C still copies.
public enum RecordingAbortDecision {

    /// - Parameters:
    ///   - keyCode: the key that just went down.
    ///   - hotkeyCodes: every configured trigger key. A non-modifier hotkey (F13) emits a
    ///     real keyDown, so it would otherwise abort its own take.
    ///   - isRecording: the AUTHORITATIVE capture state (`recorder.isRecording`), never a
    ///     derived flag — see DEBUGGING-LOG 2026-06-30.
    public static func shouldAbort(keyCode: UInt16,
                                   hotkeyCodes: Set<UInt16>,
                                   isRecording: Bool) -> Bool {
        guard isRecording else { return false }
        // Both exemptions already own a meaning inside a recording.
        if keyCode == KeyCatalog.space { return false }    // hands-free lock
        if keyCode == KeyCatalog.escape { return false }   // explicit cancel
        return !hotkeyCodes.contains(keyCode)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift run LisperKitTests 2>&1 | tail -3`
Expected: all tests pass.

- [ ] **Step 5: Surface foreign keys from the tap**

In `Sources/Lisper/Input/RecordingKeyTap.swift`, add the handler property beside the others:

```swift
    /// Any keyDown that is not Esc or Space, while a recording is in flight. Unlike those
    /// two the event is NOT swallowed — a shortcut the user meant must still reach the app.
    var onOtherKey: ((Int64) -> Void)?
```

and replace the switch's `default: break` with:

```swift
            default:
                me.onOtherKey?(event.getIntegerValueField(.keyboardEventKeycode))
```

Update the type's doc comment to say it also reports other keys without swallowing them.

- [ ] **Step 6: Add the abort path and delay the pill**

In `Sources/Lisper/AppDelegate.swift`:

**6a.** Add a stored property beside `deferredFinish`:

```swift
    /// The pill is shown a beat after capture starts, so a take aborted by a shortcut
    /// (⌃C on a Left-⌃ hotkey) never flashes any UI at all. Capture itself is immediate —
    /// no speech is lost.
    private var pendingPillShow: DispatchWorkItem?
    private static let pillDelaySeconds = 0.2
```

**6b.** In `beginRecording()`, wire the tap handler next to the existing two (before `recordKeys.start()`):

```swift
        recordKeys.onOtherKey = { [weak self] code in
            guard let self else { return }
            let codes = Set(self.env.settingsStore.settings.hotkeyCodes)
            guard RecordingAbortDecision.shouldAbort(keyCode: UInt16(clamping: code),
                                                     hotkeyCodes: codes,
                                                     isRecording: self.recorder.isRecording)
            else { return }
            self.abortRecording()
        }
```

**6c.** In `beginRecording()`, replace `pill.show(phase: .listening)` with the deferred show:

```swift
            let show = DispatchWorkItem { [weak self] in
                guard let self, self.recorder.isRecording else { return }
                self.pendingPillShow = nil
                self.pill.show(phase: .listening)
            }
            pendingPillShow = show
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pillDelaySeconds, execute: show)
```

**6d.** Cancel the pending show wherever a take ends. Add this line to the top of
`cancelRecording()` and `finishRecording()` (right beside the existing
`deferredFinish?.cancel(); deferredFinish = nil`), and to `beginRecording()` next to the
same line:

```swift
        pendingPillShow?.cancel(); pendingPillShow = nil
```

**6e.** Add `abortRecording()` immediately after `cancelRecording()`:

```swift
    /// Another key joined the hold — the user meant a shortcut, not dictation. Identical to
    /// `cancelRecording()` except it is SILENT: no cancel sound, and (inside the pill delay)
    /// no pill was ever shown. Nothing is transcribed, saved, or logged.
    private func abortRecording() {
        guard recorder.isRecording else { return }
        HotkeyTrace.log("abortRecording: another key joined the hold")
        deferredFinish?.cancel(); deferredFinish = nil
        pendingPillShow?.cancel(); pendingPillShow = nil
        _ = recorder.stop()
        recordKeys.stop()
        recordingLocked = false
        pill.model.locked = false
        hotkey.noteSessionEnded()
        pill.hide()
        menuBar.set(state: .idle)
    }
```

- [ ] **Step 7: Build and verify manually**

Run: `swift build 2>&1 | tail -3 && ./scripts/run.sh`

Then, with Fn still configured: hold Fn and press a letter — expect no pill, no history row,
and an `abortRecording` line in `/tmp/lisper-hotkey.log`. Hold Fn, speak, release — expect
the take to complete normally. Hold Fn, press Space — expect the lock sound and a locked
take (Space must NOT abort).

- [ ] **Step 8: Commit**

```bash
git add Sources/LisperKit/Input/RecordingAbortDecision.swift Tests/LisperKitTests/RecordingAbortDecisionTests.swift Sources/Lisper/Input/RecordingKeyTap.swift Sources/Lisper/AppDelegate.swift
git commit -m "feat: abandon a take silently when another key joins the hold"
```

---

### Task 6: Press-a-key picker in Settings

**Files:**
- Create: `Sources/Lisper/Input/HotkeyCaptureController.swift`
- Modify: `Sources/Lisper/UI/Main/SettingsView.swift` (lines ~18-50)

**Interfaces:**
- Consumes: `KeyCatalog` (Task 1), `AppSettings.hotkeyCodes` (Task 2), `HotkeyMonitor.isPaused`.
- Produces: `HotkeyCaptureController` — an `ObservableObject` with `isArmed: Bool`, `refusal: String?`, `start(onCapture: @escaping (UInt16) -> Void)`, `cancel()`.

- [ ] **Step 1: Write the capture controller**

Create `Sources/Lisper/Input/HotkeyCaptureController.swift`:

```swift
// Sources/Lisper/Input/HotkeyCaptureController.swift
import AppKit
import LisperKit

/// Records the next key the user presses, for the Settings picker.
///
/// Local monitors only — capture happens while the Settings window is frontmost, and using
/// global ones would need Accessibility trust for a UI affordance that does not require it.
/// The caller pauses `HotkeyMonitor` for the duration so the key being CHOSEN does not also
/// start a recording.
@MainActor
final class HotkeyCaptureController: ObservableObject {
    @Published private(set) var isArmed = false
    /// Set when the user pressed a key that cannot be a hotkey; capture stays armed.
    @Published private(set) var refusal: String?

    private var monitors: [Any] = []
    private var onCapture: ((UInt16) -> Void)?

    func start(onCapture: @escaping (UInt16) -> Void) {
        guard !isArmed else { return }
        self.onCapture = onCapture
        isArmed = true
        refusal = nil
        // flagsChanged catches modifiers (which never emit keyDown); keyDown catches the rest.
        let consume: (NSEvent) -> NSEvent? = { [weak self] e in
            guard let self, self.handle(e.keyCode) else { return e }
            return nil   // consumed — must not also reach the Settings UI
        }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: consume) as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: consume) as Any)
    }

    func cancel() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        onCapture = nil
        isArmed = false
        refusal = nil
    }

    /// - Returns: true when the event was consumed and must not reach the UI.
    private func handle(_ keyCode: UInt16) -> Bool {
        guard isArmed else { return false }
        // Esc leaves capture without choosing anything.
        if keyCode == KeyCatalog.escape { cancel(); return true }
        // `flagsChanged` fires on RELEASE as well as press. Capture only a modifier that is
        // actually DOWN, using the same either-signal rule as `HotkeySetDecision.isDown`:
        // Right ⌘ never reads as physically down at all, and Fn's `.function` flag clears
        // spuriously mid-hold, so neither signal alone is sufficient.
        if let mod = KeyCatalog.modifier(for: keyCode) {
            let physical = CGEventSource.keyState(.combinedSessionState, key: keyCode)
            let flagSet = NSEvent.modifierFlags.contains(mod.flagName.nsFlag)
            guard physical || flagSet else { return true }   // a release — stay armed
        }
        if let rejection = KeyCatalog.rejection(for: keyCode) {
            refusal = rejection.reason      // stay armed so they can pick another key
            return true
        }
        let capture = onCapture
        cancel()
        capture?(keyCode)
        return true
    }
}
```

- [ ] **Step 2: Replace the checkbox list in `SettingsView`**

In `Sources/Lisper/UI/Main/SettingsView.swift`, add near the other `@State`/`@StateObject`
declarations:

```swift
    @StateObject private var capture = HotkeyCaptureController()
```

Replace the `ForEach(HotkeyChoice.allCases…)` block and its trailing help text (everything
from `ForEach` through the `Text("All ticked keys work at once…")` line) with:

```swift
                            ForEach(model.settings.hotkeyCodes, id: \.self) { code in
                                HStack {
                                    Text(KeyCatalog.label(for: code))
                                        .foregroundColor(Theme.textPrimary)
                                    if KeyCatalog.isPrintable(code) {
                                        Text("types text — may interfere")
                                            .font(.system(size: 11))
                                            .foregroundColor(Theme.textFaint)
                                    }
                                    Spacer()
                                    Button("Remove") {
                                        var keys = model.settings.hotkeyCodes
                                        keys.removeAll { $0 == code }
                                        if !keys.isEmpty { model.settings.hotkeyCodes = keys }
                                    }
                                    // The last key can't be removed — a zero-key state would
                                    // make the app impossible to trigger.
                                    .disabled(model.settings.hotkeyCodes.count == 1)
                                }
                            }
                            Button(capture.isArmed ? "Press a key…  (Esc to cancel)" : "+ Add key") {
                                if capture.isArmed {
                                    capture.cancel()
                                    model.hotkeyCaptureEnded()
                                } else {
                                    model.hotkeyCaptureBegan()
                                    capture.start { code in
                                        var keys = model.settings.hotkeyCodes
                                        if !keys.contains(code) { keys.append(code) }
                                        model.settings.hotkeyCodes = keys
                                        model.hotkeyCaptureEnded()
                                    }
                                }
                            }.buttonStyle(AccentButtonStyle())
                            if let refusal = capture.refusal {
                                Text(refusal)
                                    .font(.system(size: 11)).foregroundColor(Theme.textTertiary)
                            }
                            Text("Every key listed works at once — handy across a laptop and an external keyboard.")
                                .font(.system(size: 11)).foregroundColor(Theme.textFaint)
```

Update the Fn help text condition below it:

```swift
                        if model.settings.hotkeyCodes.contains(KeyCatalog.fn) {
```

- [ ] **Step 3: Pause the monitor during capture**

In `Sources/Lisper/UI/Main/MainViewModel.swift`, add:

```swift
    /// Capture is armed — stop the hotkey monitor so the key being CHOSEN does not also
    /// start a recording. Paired with `hotkeyCaptureEnded()`.
    func hotkeyCaptureBegan() {
        NotificationCenter.default.post(name: .lisperHotkeyCaptureBegan, object: nil)
    }

    func hotkeyCaptureEnded() {
        NotificationCenter.default.post(name: .lisperHotkeyCaptureEnded, object: nil)
    }
```

and, in the same file, outside the class:

```swift
extension Notification.Name {
    static let lisperHotkeyCaptureBegan = Notification.Name("lisper.hotkeyCaptureBegan")
    static let lisperHotkeyCaptureEnded = Notification.Name("lisper.hotkeyCaptureEnded")
}
```

In `Sources/Lisper/AppDelegate.swift`, inside `applicationDidFinishLaunching`, observe them:

```swift
        NotificationCenter.default.addObserver(forName: .lisperHotkeyCaptureBegan,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.hotkey.isPaused = true
        }
        NotificationCenter.default.addObserver(forName: .lisperHotkeyCaptureEnded,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.hotkey.isPaused = false
        }
```

- [ ] **Step 4: Build and verify manually**

Run: `swift build 2>&1 | tail -3 && ./scripts/run.sh`

Open Settings → Hotkey and check each of these:
1. The list shows "Fn (🌐)" with a disabled Remove button.
2. "+ Add key" → press **Left Control** → a "Left ⌃" row appears.
3. Hold Left Control anywhere and speak — it dictates.
4. Press ⌃C in another app — it copies, and no take is recorded.
5. "+ Add key" → press **Caps Lock** → refusal text appears, capture stays armed; press Esc to leave.
6. "+ Add key" → press **A** → the row appears with the "types text" warning.
7. Remove the "A" row, quit and relaunch — Fn and Left ⌃ both survive.

- [ ] **Step 5: Run the full suite**

Run: `swift run LisperKitTests 2>&1 | tail -3`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/Lisper/Input/HotkeyCaptureController.swift Sources/Lisper/UI/Main/SettingsView.swift Sources/Lisper/UI/Main/MainViewModel.swift Sources/Lisper/AppDelegate.swift
git commit -m "feat: press-a-key hotkey picker replaces the fixed checkbox list"
```

---

### Task 7: Document the change

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/DEBUGGING-LOG.md`

- [ ] **Step 1: Update CLAUDE.md**

In the architecture section, replace any description of the hotkey as a fixed choice with:

```markdown
The trigger key is a raw virtual keycode (`AppSettings.hotkeyCodes: [UInt16]`, default `[63]`
= Fn), not a named choice — any key can be captured in Settings. `KeyCatalog` (LisperKit)
maps a keycode to its label, its modifier descriptor (which decides `flagsChanged` vs
`keyDown` routing), and whether it is refused (Caps Lock, Space, Esc). While a take is in
flight, a keyDown from any other key silently abandons it, so a shortcut modifier like
Left ⌃ stays usable for shortcuts.
```

- [ ] **Step 2: Add a landmine note to the debugging log**

Add a row to the symptom→cause table in `docs/DEBUGGING-LOG.md`:

```markdown
| **A take starts but nothing is ever saved, no error, no `dictations.jsonl` row** | Combo abort: a keyDown from a key other than the hotkey/Space/Esc silently abandons the take (`AppDelegate.abortRecording`, `RecordingAbortDecision`). Intended when the hotkey is a shortcut modifier like Left ⌃ — but it also means a stray keypress mid-dictation kills the take. `/tmp/lisper-hotkey.log` logs `abortRecording` every time. |
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md docs/DEBUGGING-LOG.md
git commit -m "docs: describe keycode hotkeys and the combo-abort landmine"
```

---

## Self-Review Notes

**Spec coverage:** §1 keycode model → Task 2; §2 `KeyCatalog` → Task 1; §3 picker → Task 6;
§4 combo abort + pill delay → Task 5; §5 migration → Task 2; §6 unchanged pieces → Tasks 3–4.
Testing section → Tasks 1, 2, 3, 5 (unit) and Tasks 4, 5, 6 Step 4 (manual).

**Known ordering constraint:** Task 2 breaks the app target's compile until Task 4 lands.
Tasks 2→3→4 should run back to back; only Task 4 restores a clean `swift build`. This is
called out in Task 2 Step 4 and Task 4 Step 3.
