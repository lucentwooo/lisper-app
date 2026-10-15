// Sources/LisperKit/Input/PasteTargetDecision.swift

/// What the Accessibility API says is focused in the frontmost app when a take finishes.
public struct FocusFacts: Equatable, Sendable {
    public var hasFocusedElement: Bool
    /// `AXRole` of the focused element, e.g. "AXTextField".
    public var role: String?
    /// The element has a text cursor/selection (`AXSelectedTextRange`) or a settable value —
    /// true for web editors that report a generic role.
    public var hasTextCursor: Bool
    /// Chromium/Electron apps often keep their accessibility tree off, so a "not a text box"
    /// answer from them can't be trusted.
    public var isChromiumBased: Bool

    public init(hasFocusedElement: Bool, role: String?, hasTextCursor: Bool, isChromiumBased: Bool) {
        self.hasFocusedElement = hasFocusedElement; self.role = role
        self.hasTextCursor = hasTextCursor; self.isChromiumBased = isChromiumBased
    }
}

/// Where a finished take goes: pasted at the cursor, offered as a one-click copy, or both.
///
/// Pasting with no text box focused sends ⌘V into nothing, then restores the old clipboard —
/// the words vanish until dug out of Home. So when the focus is clearly NOT a text box, offer a
/// copy instead. When unsure, paste exactly as before: a missed paste is worse than a spare
/// prompt, and a spare prompt on every take would be worse still.
public enum PasteTargetDecision {
    public struct Outcome: Equatable, Sendable {
        public let paste: Bool
        public let offerCopy: Bool
        public init(paste: Bool, offerCopy: Bool) { self.paste = paste; self.offerCopy = offerCopy }
    }

    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Roles that are never somewhere to type: a web page body, Finder lists, controls.
    static let nonTextRoles: Set<String> = [
        "AXWebArea", "AXList", "AXOutline", "AXTable", "AXBrowser", "AXScrollArea", "AXGroup",
        "AXButton", "AXImage", "AXSplitGroup", "AXRow", "AXCell", "AXStaticText", "AXLink",
        "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSlider",
        "AXTabGroup", "AXToolbar", "AXLayoutArea",
    ]

    public static func decide(_ f: FocusFacts) -> Outcome {
        if f.hasTextCursor || f.role.map(textRoles.contains) == true {
            return Outcome(paste: true, offerCopy: false)
        }
        if f.isChromiumBased { return Outcome(paste: true, offerCopy: false) }
        // Nothing focused is ambiguous (some terminals expose no element): paste, and offer.
        if !f.hasFocusedElement { return Outcome(paste: true, offerCopy: true) }
        if let role = f.role, nonTextRoles.contains(role) { return Outcome(paste: false, offerCopy: true) }
        return Outcome(paste: true, offerCopy: false)
    }
}
