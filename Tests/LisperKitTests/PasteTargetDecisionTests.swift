import Testing
@testable import LisperKit

/// Before pasting: when a NATIVE app's focus is clearly not a text box (a Finder list, a
/// button), ⌘V would only beep — skip it and offer a one-click copy. Everything else is
/// pasted and then checked (PasteLandedCheck).
@Suite struct PasteTargetDecisionTests {

    private func facts(element: Bool = true, role: String? = nil, cursor: Bool = false,
                       chromium: Bool = false) -> FocusFacts {
        FocusFacts(hasFocusedElement: element, role: role, hasTextCursor: cursor,
                   isChromiumBased: chromium)
    }

    @Test func testTextFieldPastes() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
            #expect(PasteTargetDecision.decide(facts(role: role)) == .paste)
        }
    }

    /// A web editor (contenteditable) often reports a generic role but has a text cursor.
    @Test func testGenericRoleWithTextCursorPastes() {
        #expect(PasteTargetDecision.decide(facts(role: "AXGroup", cursor: true)) == .paste)
    }

    @Test func testClearlyNonTextFocusInNativeAppOffersCopyInstead() {
        for role in ["AXWebArea", "AXList", "AXOutline", "AXTable", "AXScrollArea", "AXButton", "AXGroup"] {
            #expect(PasteTargetDecision.decide(facts(role: role)) == .offerCopyInstead)
        }
    }

    /// Chromium reports a text cursor on a plain page body, so its pre-paste answer isn't
    /// trusted: paste, and let the read-back decide.
    @Test func testChromiumAppsAlwaysPaste() {
        #expect(PasteTargetDecision.decide(facts(role: "AXWebArea", cursor: true, chromium: true)) == .paste)
        #expect(PasteTargetDecision.decide(facts(role: "AXGroup", chromium: true)) == .paste)
        #expect(PasteTargetDecision.decide(facts(element: false, chromium: true)) == .paste)
    }

    /// No focused element (some terminals expose none) and unknown roles: paste as before.
    @Test func testAmbiguousFocusPastes() {
        #expect(PasteTargetDecision.decide(facts(element: false)) == .paste)
        for role in ["AXWindow", "AXSomethingNew"] {
            #expect(PasteTargetDecision.decide(facts(role: role)) == .paste)
        }
    }
}
