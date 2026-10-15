import Testing
@testable import LisperKit

/// A take that finishes with no text box focused used to paste into nothing and then restore
/// the old clipboard — the words were gone until you dug them out of Home. When the focused
/// element is clearly not a text box, offer a one-click copy instead of pasting.
@Suite struct PasteTargetDecisionTests {

    private func facts(element: Bool = true, role: String? = nil, cursor: Bool = false,
                       chromium: Bool = false) -> FocusFacts {
        FocusFacts(hasFocusedElement: element, role: role, hasTextCursor: cursor,
                   isChromiumBased: chromium)
    }

    @Test func testTextFieldPastesWithoutOffer() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
            #expect(PasteTargetDecision.decide(facts(role: role)) == .init(paste: true, offerCopy: false))
        }
    }

    /// A web editor (contenteditable) often reports a generic role but has a text cursor.
    @Test func testGenericRoleWithTextCursorPastes() {
        #expect(PasteTargetDecision.decide(facts(role: "AXGroup", cursor: true))
                == .init(paste: true, offerCopy: false))
    }

    /// Clearly not a text box (a web page body, a Finder list, a button): don't paste into
    /// nothing — offer the copy.
    @Test func testClearlyNonTextFocusOffersCopyInsteadOfPasting() {
        for role in ["AXWebArea", "AXList", "AXOutline", "AXTable", "AXScrollArea", "AXButton", "AXGroup"] {
            #expect(PasteTargetDecision.decide(facts(role: role)) == .init(paste: false, offerCopy: true))
        }
    }

    /// Chromium/Electron apps (Slack, VS Code, Chrome) often hide their accessibility tree, so
    /// a non-text answer can't be trusted there — paste exactly as before, no prompt.
    @Test func testChromiumAppsAlwaysPasteWithoutOffer() {
        #expect(PasteTargetDecision.decide(facts(role: "AXGroup", chromium: true))
                == .init(paste: true, offerCopy: false))
        #expect(PasteTargetDecision.decide(facts(element: false, chromium: true))
                == .init(paste: true, offerCopy: false))
    }

    /// No focused element at all is ambiguous (some terminals expose none): still paste, but
    /// offer the copy in case it went nowhere.
    @Test func testNoFocusedElementPastesAndOffersCopy() {
        #expect(PasteTargetDecision.decide(facts(element: false)) == .init(paste: true, offerCopy: true))
    }

    /// An unrecognised role (or a bare window) keeps today's behaviour.
    @Test func testUnknownRoleKeepsPasting() {
        for role in ["AXWindow", "AXSomethingNew"] {
            #expect(PasteTargetDecision.decide(facts(role: role)) == .init(paste: true, offerCopy: false))
        }
    }
}
