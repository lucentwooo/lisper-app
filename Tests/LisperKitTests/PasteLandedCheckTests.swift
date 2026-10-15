import Testing
@testable import LisperKit

/// After a paste, the focused element is read back: if the words aren't in it, they went
/// nowhere (e.g. a web page with no text box focused) and a one-click copy is offered.
/// Measured in Chrome (2026-10-15): text fields, textareas and contenteditable editors all
/// report their text; a page body reports AXWebArea without it.
@Suite struct PasteLandedCheckTests {
    private let pasted = "Can you send me the deck before Friday? Thanks."

    @Test func testWordsFoundInFieldMeansLanded() {
        #expect(!PasteLandedCheck.offerCopy(hasElement: true, role: "AXTextArea",
                                            value: "Hi Sam. Can you send me the deck before Friday? Thanks.",
                                            pasted: pasted))
    }

    /// A Chromium page body: an AXWebArea whose value is not the pasted text.
    @Test func testWebPageBodyOffersCopy() {
        #expect(PasteLandedCheck.offerCopy(hasElement: true, role: "AXWebArea", value: "",
                                           pasted: pasted))
    }

    @Test func testNothingFocusedOffersCopy() {
        #expect(PasteLandedCheck.offerCopy(hasElement: false, role: nil, value: nil, pasted: pasted))
    }

    /// Editors re-flow whitespace (non-breaking spaces, line breaks): still landed.
    @Test func testWhitespaceDifferencesStillCountAsLanded() {
        #expect(!PasteLandedCheck.offerCopy(hasElement: true, role: "AXTextArea",
                                            value: "Can you send\u{00A0}me the\ndeck before Friday? Thanks.",
                                            pasted: pasted))
    }

    /// A text box that hides its contents (password field) can't be checked — trust the paste.
    @Test func testUnreadableTextBoxIsTrusted() {
        #expect(!PasteLandedCheck.offerCopy(hasElement: true, role: "AXTextField", value: nil,
                                            pasted: pasted))
    }

    /// Something focused that is not a text box and exposes no text: the paste went nowhere.
    @Test func testUnreadableNonTextElementOffersCopy() {
        #expect(PasteLandedCheck.offerCopy(hasElement: true, role: "AXGroup", value: nil,
                                           pasted: pasted))
    }

    @Test func testEmptyPasteNeverOffers() {
        #expect(!PasteLandedCheck.offerCopy(hasElement: false, role: nil, value: nil, pasted: "  "))
    }
}
