// Sources/LisperKit/Input/PasteTargetDecision.swift

/// What the Accessibility API says is focused in the frontmost app when a take finishes.
public struct FocusFacts: Equatable, Sendable {
    public var hasFocusedElement: Bool
    /// `AXRole` of the focused element, e.g. "AXTextField".
    public var role: String?
    /// The element has a text cursor/selection (`AXSelectedTextRange`) or a settable value —
    /// true for web editors that report a generic role.
    public var hasTextCursor: Bool
    /// Chromium/Electron apps report a text cursor even on a plain page body, so their
    /// pre-paste answer can't tell a text box from a page.
    public var isChromiumBased: Bool

    public init(hasFocusedElement: Bool, role: String?, hasTextCursor: Bool, isChromiumBased: Bool) {
        self.hasFocusedElement = hasFocusedElement; self.role = role
        self.hasTextCursor = hasTextCursor; self.isChromiumBased = isChromiumBased
    }
}

/// Before pasting: should the take be pasted, or offered as a one-click copy instead?
///
/// Only a NATIVE app whose focus is clearly not a text box (a Finder list, a button) skips the
/// paste — there ⌘V would just beep. Everything else is pasted and then read back
/// (PasteLandedCheck), which is what catches a Chrome/Electron page with no text box.
public enum PasteTargetDecision {
    public enum Outcome: Equatable, Sendable { case paste, offerCopyInstead }

    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Roles that are never somewhere to type: a web page body, Finder lists, controls.
    static let nonTextRoles: Set<String> = [
        "AXWebArea", "AXList", "AXOutline", "AXTable", "AXBrowser", "AXScrollArea", "AXGroup",
        "AXButton", "AXImage", "AXSplitGroup", "AXRow", "AXCell", "AXStaticText", "AXLink",
        "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSlider",
        "AXTabGroup", "AXToolbar", "AXLayoutArea",
    ]

    public static func decide(_ f: FocusFacts) -> Outcome {
        if f.isChromiumBased || f.hasTextCursor || f.role.map(textRoles.contains) == true { return .paste }
        if let role = f.role, nonTextRoles.contains(role) { return .offerCopyInstead }
        return .paste
    }
}

/// After pasting: did the words land? Read back from the focused element — if they aren't in
/// it, they went nowhere (a web page with nothing focused, an empty window), so offer a copy.
/// Measured in Chrome (2026-10-15): text fields, textareas and contenteditable editors report
/// their text; a page body reports AXWebArea without it.
public enum PasteLandedCheck {
    /// Enough of the start of the text to recognise it, short enough that an editor's
    /// formatting further on can't break the match.
    static let needleLength = 30

    public static func offerCopy(hasElement: Bool, role: String?, value: String?, pasted: String) -> Bool {
        let needle = squash(String(squash(pasted).prefix(needleLength)))
        guard !needle.isEmpty else { return false }
        if let value { return !squash(value).contains(needle) }
        // A text box that hides its text (a password field) can't be checked: trust the paste.
        if let role, PasteTargetDecision.textRoles.contains(role) { return false }
        return true
    }

    /// Collapses every run of whitespace (incl. non-breaking spaces and line breaks) to one
    /// space, so an editor re-flowing the text doesn't read as "not there".
    static func squash(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
