import Testing
@testable import LisperKit

@Suite struct SettingsTests {
    @Test func testDefaults() {
        let s = AppSettings()
        #expect(s.hotkeyCodes == [63])   // Fn
        #expect(s.hotkeyMode == .hold)
        #expect(s.sttEngine == .groq)
        // Full large-v3, not `-turbo`: the distilled decoder substitutes single words.
        #expect(s.groqWhisperModel == "whisper-large-v3")
        #expect(s.groqChatModel == "openai/gpt-oss-120b")
        #expect(s.retention == .forever)
        #expect(s.llmCleanupEnabled)
    }

    /// Groq shut `llama-3.3-70b-versatile` down on 2026-08-16; every install that had it
    /// stored kept sending it and silently fell back to rule cleanup for two months.
    /// A retired chat model must migrate to the current default on load.
    @Test func testRetiredChatModelMigratesToDefault() throws {
        for retired in ["llama-3.3-70b-versatile", "llama-3.1-8b-instant", "qwen/qwen3-32b",
                        "meta-llama/llama-4-scout-17b-16e-instruct", "qwen/qwen3.6-27b"] {
            let json = #"{"groqChatModel":"\#(retired)"}"#
            let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
            #expect(s.groqChatModel == AppSettings().groqChatModel, "\(retired) should migrate")
        }
    }

    /// turbo checks large-v3's endings by default — including on existing installs, whose stored
    /// blob has no key for it yet.
    @Test func testEndingCheckModelDefaultsToTurbo() throws {
        #expect(AppSettings().groqEndingCheckModel == "whisper-large-v3-turbo")
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"groqWhisperModel":"whisper-large-v3"}"#.utf8))
        #expect(s.distinctEndingCheckModel == "whisper-large-v3-turbo")
    }

    /// Blank turns the check off; the transcription model itself is no check at all.
    @Test func testEndingCheckModelIsNilWhenBlankOrSameAsWhisperModel() {
        var s = AppSettings()
        s.groqEndingCheckModel = "  "
        #expect(s.distinctEndingCheckModel == nil)
        s.groqEndingCheckModel = "whisper-large-v3 "
        #expect(s.distinctEndingCheckModel == nil)
        s.groqWhisperModel = "whisper-large-v3-turbo"
        s.groqEndingCheckModel = "whisper-large-v3"
        #expect(s.distinctEndingCheckModel == "whisper-large-v3")
    }

    @Test func testEndingCheckModelRoundTrips() throws {
        var s = AppSettings()
        s.groqEndingCheckModel = "distil-whisper"
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.groqEndingCheckModel == "distil-whisper")
    }

    /// A model the user typed in themselves (still live) is theirs — never overwritten.
    @Test func testCustomChatModelIsKept() throws {
        let json = #"{"groqChatModel":"openai/gpt-oss-20b"}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.groqChatModel == "openai/gpt-oss-20b")
    }

    /// A malformed LEGACY key must not throw — SettingsStore resets EVERYTHING (dictionary
    /// included) on a decode error. The current keys still decode.
    @Test func testMalformedLegacyHotkeyKeysDoNotResetSettings() throws {
        let json = #"{"hotkey":42,"hotkeys":"nope","hotkeyCodes":[59],"dictionaryTerms":["Jeriq"]}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.hotkeyCodes == [59])
        #expect(s.dictionaryTerms == ["Jeriq"])
    }

    @Test func testRoundTripThroughStore() {
        let defaults = UserDefaults(suiteName: "lisper-tests")!
        defaults.removePersistentDomain(forName: "lisper-tests")
        let store = SettingsStore(defaults: defaults)
        var s = store.settings
        s.hotkeyCodes = [54]
        s.dictionaryTerms = ["Lucent"]
        store.save(s)
        let reloaded = SettingsStore(defaults: defaults).settings
        #expect(reloaded.hotkeyCodes == [54])
        #expect(reloaded.dictionaryTerms == ["Lucent"])
    }

    /// A settings blob stored by an older build still contains "styleMode":"formal".
    /// Tolerant decoding must ignore the now-unknown key rather than resetting EVERY
    /// setting to defaults (SettingsStore wipes everything on a decode error).
    @Test func testLegacyFormalStyleModeDecodesWithoutThrowing() throws {
        let json = #"{"styleMode":"formal","llmCleanupEnabled":false}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.llmCleanupEnabled == false)   // the rest of the blob survived
    }

    /// Off for a new install (privacy by default — recordings are opt-in), but an existing
    /// install that stored `true` keeps it.
    @Test func testSaveAudioForDebuggingDefaultsOffAndRoundTrips() throws {
        let defaults = UserDefaults(suiteName: "lisper.test.\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        #expect(store.settings.saveAudioForDebugging == false)
        store.update { $0.saveAudioForDebugging = true }
        let reopened = SettingsStore(defaults: defaults)
        #expect(reopened.settings.saveAudioForDebugging == true)
        let stored = try JSONDecoder().decode(AppSettings.self,
                                              from: Data(#"{"saveAudioForDebugging":true}"#.utf8))
        #expect(stored.saveAudioForDebugging == true)
    }

    @Test func testVadTrimmingDefaultsOnAndRoundTrips() {
        #expect(AppSettings().vadTrimmingEnabled == true)
        let defaults = UserDefaults(suiteName: "lisper.test.\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        #expect(store.settings.vadTrimmingEnabled == true)
        store.update { $0.vadTrimmingEnabled = false }
        let reopened = SettingsStore(defaults: defaults)
        #expect(reopened.settings.vadTrimmingEnabled == false)
    }

    /// A v0.1-era blob (has toneRules, lacks styleMode) must decode without
    /// resetting the user's other settings.
    @Test func testLegacyBlobDecodesWithDefaults() throws {
        let legacy = """
        {"hotkey":"rightCommand","hotkeyMode":"hold","sttEngine":"groq",\
        "llmCleanupEnabled":true,"groqWhisperModel":"whisper-large-v3-turbo",\
        "groqChatModel":"llama-3.3-70b-versatile",\
        "groqBaseURL":"https://api.groq.com/openai/v1",\
        "dictionaryTerms":["Lucent"],"customFillers":[],\
        "toneRules":{"rules":{"com.example":"casual"}},\
        "retention":"forever","launchAtLogin":false,"onboardingComplete":true}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: legacy)
        #expect(s.vadTrimmingEnabled == true)   // missing key -> default on
        #expect(s.hotkeyCodes == [54])
        #expect(s.dictionaryTerms == ["Lucent"])
        #expect(s.onboardingComplete)
    }

    @Test func testHotkeyKeyCodes() {
        #expect(HotkeyChoice.fn.keyCode == 63)
        #expect(HotkeyChoice.rightCommand.keyCode == 54)
        #expect(HotkeyChoice.rightOption.keyCode == 61)
        #expect(HotkeyChoice.f13.keyCode == 105)
        #expect(HotkeyChoice.f14.keyCode == 107)
        #expect(HotkeyChoice.f15.keyCode == 113)
    }

    @Test func testDefaultHotkeysIsFn() {
        #expect(AppSettings().hotkeyCodes == [63])
    }

    /// A blob from a single-key build migrates its `hotkey` into the new list.
    @Test func testLegacySingleHotkeyMigrates() throws {
        let json = #"{"hotkey":"f13"}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.hotkeyCodes == [105])
    }

    @Test func testMissingHotkeysFallsBackToFn() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(s.hotkeyCodes == [63])
    }

    /// An empty list would make the app impossible to trigger, with no in-app recovery.
    @Test func testEmptyHotkeysFallsBackToFn() throws {
        let json = #"{"hotkeys":[]}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.hotkeyCodes == [63])
    }

    @Test func testDuplicateHotkeysAreRemovedPreservingOrder() throws {
        let json = #"{"hotkeys":["f13","fn","f13"]}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.hotkeyCodes == [105, 63])
    }

    /// `hotkeys` wins over a stale legacy `hotkey` in the same blob.
    @Test func testNewListWinsOverLegacyKey() throws {
        let json = #"{"hotkey":"f15","hotkeys":["fn","f13"]}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.hotkeyCodes == [63, 105])
    }

    @Test func testHotkeysRoundTripThroughEncoding() throws {
        var s = AppSettings()
        s.hotkeyCodes = [63, 105]
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data).hotkeyCodes == [63, 105])
    }

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
}
