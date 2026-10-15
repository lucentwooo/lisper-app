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
