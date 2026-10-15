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
