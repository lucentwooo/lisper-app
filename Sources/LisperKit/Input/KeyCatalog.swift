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
