import Testing
@testable import LisperKit

@Suite struct HotkeySetDecisionTests {

    @Test func testKeyCodeOutsideEnabledSetIsIgnored() {
        var d = HotkeySetDecision(enabled: [63])
        #expect(!d.isEnabled(105))
        let pressed = d.press(keyCode: 105)
        #expect(!pressed)
        #expect(d.owner == nil)
    }

    @Test func testEnabledKeyPressStartsTakeAndTakesOwnership() {
        var d = HotkeySetDecision(enabled: [63, 105])
        let pressed = d.press(keyCode: 105)
        #expect(pressed)
        #expect(d.owner == 105)
    }

    /// OWNERSHIP: every historical hotkey bug in this app is a phantom release from an
    /// unrelated event. A second enabled key must be structurally unable to end the
    /// first key's take.
    @Test func testSecondEnabledKeyIsIgnoredWhileFirstIsHeld() {
        var d = HotkeySetDecision(enabled: [63, 105])
        let firstPress = d.press(keyCode: 63)
        #expect(firstPress)
        let secondPress = d.press(keyCode: 105)
        #expect(!secondPress)     // no second take
        let secondRelease = d.release(keyCode: 105)
        #expect(!secondRelease)   // CANNOT end the owner's take
        #expect(d.owner == 63)
    }

    @Test func testOwnerReleaseEndsTakeAndClearsOwnership() {
        var d = HotkeySetDecision(enabled: [63, 105])
        _ = d.press(keyCode: 63)
        let released = d.release(keyCode: 63)
        #expect(released)
        #expect(d.owner == nil)
    }

    @Test func testRepeatPressFromOwnerDoesNotRestart() {
        var d = HotkeySetDecision(enabled: [63])
        let firstPress = d.press(keyCode: 63)
        #expect(firstPress)
        let repeatPress = d.press(keyCode: 63)
        #expect(!repeatPress)   // key repeat
    }

    @Test func testReleaseWithoutPressIsNotAnEnd() {
        var d = HotkeySetDecision(enabled: [63])
        let released = d.release(keyCode: 63)
        #expect(!released)
    }

    @Test func testAfterOwnerReleasesAnotherKeyMayStartATake() {
        var d = HotkeySetDecision(enabled: [63, 105])
        _ = d.press(keyCode: 63)
        _ = d.release(keyCode: 63)
        let pressed = d.press(keyCode: 105)
        #expect(pressed)
        #expect(d.owner == 105)
    }

    /// `clearOwner()` un-owns the take but must NOT forget that the key is still down —
    /// after a release, the next press is a clean new take.
    @Test func testClearOwnerAllowsAFreshPressOnceTheKeyIsReleased() {
        var d = HotkeySetDecision(enabled: [63])
        _ = d.press(keyCode: 63)
        d.clearOwner()
        _ = d.release(keyCode: 63)
        let pressed = d.press(keyCode: 63)
        #expect(pressed)
        #expect(d.owner == 63)
    }

    @Test func testIsEnabledReflectsTheConfiguredSet() {
        let d = HotkeySetDecision(enabled: [63, 59])
        #expect(d.isEnabled(63))
        #expect(d.isEnabled(59))
        #expect(!d.isEnabled(105))
    }

    // MARK: held-key dedup (phantom PRESS)

    /// The mirror image of the phantom-release family: a key that is still physically
    /// down must never produce a second press edge, whoever owns the take.
    @Test func testSecondPressOfAStillHeldKeyIsNotAnEdge() {
        var d = HotkeySetDecision(enabled: [63])
        let first = d.press(keyCode: 63)
        #expect(first)
        let second = d.press(keyCode: 63)
        #expect(!second)
        #expect(d.heldKeys == [63])
    }

    /// THE regression test for the phantom press (DEBUGGING-LOG 2026-08-03). Esc-cancel
    /// mid-hold calls `clearOwner()`; the Fn key then emits a spurious `.function` event
    /// while STILL physically held. Ownership alone cannot dedup that — held-state must.
    @Test func testPressAfterClearOwnerWhileStillHeldIsNotAnEdge() {
        var d = HotkeySetDecision(enabled: [63])
        _ = d.press(keyCode: 63)
        d.clearOwner()                                   // Esc cancel
        #expect(d.owner == nil)
        let phantom = d.press(keyCode: 63)
        #expect(!phantom)                                // must NOT start a new take
        #expect(d.owner == nil)
    }

    /// Toggle mode clears ownership on the press edge, so held-state is the ONLY thing
    /// standing between a held key's repeats and a stream of toggles.
    @Test func testToggleStylePressThenClearOwnerStillDedupsRepeats() {
        var d = HotkeySetDecision(enabled: [105])
        let first = d.press(keyCode: 105)
        #expect(first)
        d.clearOwner()
        let repeat1 = d.press(keyCode: 105)
        let repeat2 = d.press(keyCode: 105)
        #expect(!repeat1)
        #expect(!repeat2)
    }

    /// A release ALWAYS drops held-state, even from a key that never owned a take —
    /// otherwise a non-owning key could strand itself and blockade that hotkey forever.
    @Test func testReleaseClearsHeldStateEvenForANonOwner() {
        var d = HotkeySetDecision(enabled: [63, 105])
        _ = d.press(keyCode: 63)          // fn owns
        _ = d.press(keyCode: 105)         // held, but not owner
        #expect(d.heldKeys == [63, 105])
        let ended = d.release(keyCode: 105)
        #expect(!ended)                                        // cannot end fn's take
        #expect(d.heldKeys == [63])       // but IS no longer held
        #expect(d.owner == 63)
        let repress = d.press(keyCode: 105)
        #expect(!repress)                                      // fn still owns, so no edge
        _ = d.release(keyCode: 63)
        _ = d.release(keyCode: 105)
        #expect(d.heldKeys.isEmpty)
    }

    /// A release the monitors never saw is recovered by the watchdog, which feeds the
    /// physical key state back in as a release — for ANY held key, owner or not.
    @Test func testReleaseWithoutPressLeavesHeldStateEmpty() {
        var d = HotkeySetDecision(enabled: [63])
        let ended = d.release(keyCode: 63)
        #expect(!ended)
        #expect(d.heldKeys.isEmpty)
    }

    /// `reset()` is for when held-state can no longer be trusted (monitors torn down).
    @Test func testResetClearsOwnerAndHeldState() {
        var d = HotkeySetDecision(enabled: [63, 105])
        _ = d.press(keyCode: 63)
        _ = d.press(keyCode: 105)
        d.reset()
        #expect(d.owner == nil)
        #expect(d.heldKeys.isEmpty)
        let pressed = d.press(keyCode: 63)
        #expect(pressed)   // a fresh press works immediately after a reset
    }

    /// A key outside the enabled set never enters held-state (nothing to strand).
    @Test func testDisabledKeyNeverEntersHeldState() {
        var d = HotkeySetDecision(enabled: [63])
        _ = d.press(keyCode: 105)
        #expect(d.heldKeys.isEmpty)
    }

    @Test func testFreshDecisionHasNoHeldKeys() {
        let d = HotkeySetDecision(enabled: [63, 105])
        #expect(d.heldKeys.isEmpty)
        #expect(d.owner == nil)
    }

    /// Fn semantics preserved: the `.function` flag clears while the key is still
    /// physically held, so EITHER signal means "down".
    @Test func testFnIsDownWhenFlagClearsButKeyIsPhysicallyHeld() {
        #expect(HotkeySetDecision.isDown(eventKeyCode: 63,
                                         hotkeyCode: 63, flagSet: false, physicallyDown: true) == true)
    }

    @Test func testFnIsUpWhenBothSignalsAreFalse() {
        #expect(HotkeySetDecision.isDown(eventKeyCode: 63,
                                         hotkeyCode: 63, flagSet: false, physicallyDown: false) == false)
    }

    /// nil means "ignore this event entirely" — it must NEVER be read as a release.
    @Test func testMismatchedKeyCodeReturnsNilNotFalse() {
        #expect(HotkeySetDecision.isDown(eventKeyCode: 99,
                                         hotkeyCode: 63, flagSet: true, physicallyDown: true) == nil)
    }

    // MARK: watchdog release (DEBUGGING-LOG 2026-08-03b)

    /// THE regression test for "Right ⌘ recordings die after ~0.5 s". `CGEventSource.keyState`
    /// never reports keycode 54 as down on this hardware, so a physical-state-only watchdog
    /// synthesised a release half a second into every take. The modifier flag is still set
    /// while the key is held, and that must veto the synthetic release.
    @Test func testWatchdogDoesNotReleaseAModifierWhoseFlagIsStillSet() {
        #expect(HotkeySetDecision.shouldSynthesizeRelease(physicallyDown: false, flagSet: true) == false)
    }

    /// The Fn case: `.function` clears spuriously mid-hold, so physical state alone keeps it alive.
    @Test func testWatchdogDoesNotReleaseAKeyThatIsStillPhysicallyDown() {
        #expect(HotkeySetDecision.shouldSynthesizeRelease(physicallyDown: true, flagSet: false) == false)
    }

    /// Both signals down means the release was genuinely missed — un-strand the key, or that
    /// hotkey is blockaded forever.
    @Test func testWatchdogReleasesWhenNeitherSignalSaysDown() {
        #expect(HotkeySetDecision.shouldSynthesizeRelease(physicallyDown: false, flagSet: false) == true)
    }

    /// Same rule as `isDown`: a key is down iff EITHER signal says so. The watchdog is just
    /// its negation, so the two can never disagree about what "held" means.
    @Test func testWatchdogReleaseIsTheNegationOfIsDown() {
        for physical in [true, false] {
            for flag in [true, false] {
                let down = HotkeySetDecision.isDown(eventKeyCode: 63,
                                                    hotkeyCode: 63, flagSet: flag, physicallyDown: physical)
                #expect(HotkeySetDecision.shouldSynthesizeRelease(physicallyDown: physical,
                                                                  flagSet: flag) == !(down ?? false))
            }
        }
    }
}
