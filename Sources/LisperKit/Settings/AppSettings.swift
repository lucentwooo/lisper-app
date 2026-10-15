import Foundation

/// LEGACY. The trigger key is a raw keycode now (`AppSettings.hotkeyCodes`); this enum
/// exists ONLY to decode settings blobs written before that change. Do not add cases,
/// do not reference it outside `AppSettings.init(from:)`.
public enum HotkeyChoice: String, Codable, Sendable {
    case fn, rightCommand, rightOption, f13, f14, f15

    public var keyCode: UInt16 {
        switch self {
        case .fn: return 63             // kVK_Function
        case .rightCommand: return 54
        case .rightOption: return 61
        case .f13: return 105
        case .f14: return 107
        case .f15: return 113
        }
    }
}

public enum HotkeyMode: String, Codable, CaseIterable, Sendable { case hold, toggle }

public enum STTEngineChoice: String, Codable, CaseIterable, Sendable { case groq, apple }

public enum RetentionPolicy: String, Codable, CaseIterable, Sendable {
    case forever, days90, days30
    public var days: Int? { self == .forever ? nil : (self == .days90 ? 90 : 30) }
}

public struct AppSettings: Codable, Equatable, Sendable {
    /// Every enabled trigger keycode. All are live at once so the app works across a
    /// laptop keyboard (Fn) and an external one (a Windows keyboard's Left ⌃) without
    /// changing a setting. Labels come from `KeyCatalog.label(for:)`.
    /// INVARIANT: deduped, and never empty — an empty list would make the app impossible
    /// to trigger.
    public var hotkeyCodes: [UInt16] = [KeyCatalog.fn]
    public var hotkeyMode: HotkeyMode = .hold
    public var sttEngine: STTEngineChoice = .groq
    public var llmCleanupEnabled: Bool = true
    /// `-turbo` is the distilled decoder (4 layers vs 32): same audio encoder, but markedly
    /// worse at *resolving* an ambiguous word, which shows up as single-word substitutions in
    /// an otherwise-correct sentence ("transcription" → "transcribe"). Full `large-v3` costs
    /// a few hundred ms more per take and is the accuracy default; switch back in Settings if
    /// the latency matters more than the odd wrong word.
    public var groqWhisperModel: String = "whisper-large-v3"
    /// Transcribes the same clip alongside `groqWhisperModel` to catch an ending it dropped:
    /// large-v3 sometimes stops with words still to come (28 of 358 saved takes), and turbo
    /// hears most of those endings. Its words are added only after large-v3's own
    /// (EndingRecovery). Blank turns the check off.
    public var groqEndingCheckModel: String = "whisper-large-v3-turbo"
    /// Groq's named replacement for `llama-3.3-70b-versatile` (shut down 2026-08-16). A
    /// reasoning model: `GroqClient.chat` sends it a low reasoning effort for speed.
    public var groqChatModel: String = "openai/gpt-oss-120b"
    /// Used only when the chat model is rate-limited (429): Groq limits are per model, so a
    /// burst of takes still gets AI cleanup instead of dropping to rules.
    public var groqBackupChatModel: String = "openai/gpt-oss-20b"
    public var groqBaseURL: String = "https://api.groq.com/openai/v1"
    /// BCP-47 hint pinned on Whisper requests so it can't drift off its language
    /// lock on noisy audio. Empty string == auto-detect.
    public var transcriptionLanguage: String = "en"
    /// Off for new installs: keeping recordings is opt-in. Existing installs keep whatever
    /// they stored (the key is always encoded, so tolerant decoding never hits this default).
    public var saveAudioForDebugging: Bool = false
    /// Proactively trim leading/trailing non-speech before transcription (kills
    /// silence hallucinations at the source, cuts upload latency). Default ON.
    /// Existing installs activate it on upgrade: the key is absent in their stored
    /// blob, so tolerant decoding falls back to this `true` default.
    public var vadTrimmingEnabled: Bool = true
    public var dictionaryTerms: [String] = []
    public var customFillers: [String] = []
    public var retention: RetentionPolicy = .forever
    public var launchAtLogin: Bool = false
    public var onboardingComplete: Bool = false
    public init() {}

    /// The backup chat model to retry on after a rate limit, or nil when it is blank or the
    /// same as the main model (compared trimmed) — retrying the same model can't help.
    public var distinctBackupChatModel: String? {
        let backup = groqBackupChatModel.trimmingCharacters(in: .whitespaces)
        let main = groqChatModel.trimmingCharacters(in: .whitespaces)
        return backup.isEmpty || backup == main ? nil : backup
    }

    /// The model that checks for a dropped ending, or nil when it is blank or the same as the
    /// transcription model (compared trimmed) — a model can't catch its own miss.
    public var distinctEndingCheckModel: String? {
        let check = groqEndingCheckModel.trimmingCharacters(in: .whitespaces)
        let main = groqWhisperModel.trimmingCharacters(in: .whitespaces)
        return check.isEmpty || check == main ? nil : check
    }

    /// Chat models Groq has shut down (console.groq.com/docs/deprecations, checked 2026-10-10):
    /// llama-3.3-70b-versatile and llama-3.1-8b-instant 2026-08-16; qwen/qwen3-32b and
    /// llama-4-scout 2026-07-17; qwen/qwen3.6-27b 2026-09-14. A stored one fails every request,
    /// and cleanup silently degrades to rules — so on load it is replaced with the current
    /// default. Only list documented shutdowns: this overrides a user's own choice.
    static let retiredChatModels: Set<String> = [
        "llama-3.3-70b-versatile", "llama-3.1-8b-instant", "qwen/qwen3-32b",
        "meta-llama/llama-4-scout-17b-16e-instruct", "qwen/qwen3.6-27b",
    ]

    private enum CodingKeys: String, CodingKey {
        case hotkey, hotkeys, hotkeyCodes, hotkeyMode, sttEngine, llmCleanupEnabled
        case groqWhisperModel, groqEndingCheckModel, groqChatModel, groqBackupChatModel, groqBaseURL, transcriptionLanguage, saveAudioForDebugging
        case vadTrimmingEnabled
        case dictionaryTerms, customFillers
        case retention, launchAtLogin, onboardingComplete
    }

    /// Tolerant decoding: a stored blob from any prior version decodes with
    /// defaults for missing keys instead of throwing (SettingsStore resets
    /// EVERYTHING to defaults on a decode error).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        // Migration ladder: `hotkeyCodes` (current) -> named `hotkeys` -> legacy single
        // `hotkey` -> default [Fn]. Deduped, and never allowed to be empty.
        // `try?` on the legacy keys: a malformed one must not throw, because a decode error
        // makes SettingsStore reset EVERYTHING, dictionary included.
        let storedCodes = try c.decodeIfPresent([UInt16].self, forKey: .hotkeyCodes)
        let namedList = (try? c.decodeIfPresent([HotkeyChoice].self, forKey: .hotkeys)) ?? nil
        let legacyName = (try? c.decodeIfPresent(HotkeyChoice.self, forKey: .hotkey)) ?? nil
        var resolved = storedCodes
            ?? namedList?.map(\.keyCode)
            ?? legacyName.map { [$0.keyCode] }
            ?? d.hotkeyCodes
        var seen = Set<UInt16>()
        resolved = resolved.filter { seen.insert($0).inserted }
        hotkeyCodes = resolved.isEmpty ? d.hotkeyCodes : resolved
        hotkeyMode = try c.decodeIfPresent(HotkeyMode.self, forKey: .hotkeyMode) ?? d.hotkeyMode
        sttEngine = try c.decodeIfPresent(STTEngineChoice.self, forKey: .sttEngine) ?? d.sttEngine
        llmCleanupEnabled = try c.decodeIfPresent(Bool.self, forKey: .llmCleanupEnabled) ?? d.llmCleanupEnabled
        groqWhisperModel = try c.decodeIfPresent(String.self, forKey: .groqWhisperModel) ?? d.groqWhisperModel
        groqEndingCheckModel = try c.decodeIfPresent(String.self, forKey: .groqEndingCheckModel) ?? d.groqEndingCheckModel
        let storedChatModel = try c.decodeIfPresent(String.self, forKey: .groqChatModel) ?? d.groqChatModel
        groqChatModel = Self.retiredChatModels.contains(storedChatModel) ? d.groqChatModel : storedChatModel
        let storedBackup = try c.decodeIfPresent(String.self, forKey: .groqBackupChatModel) ?? d.groqBackupChatModel
        groqBackupChatModel = Self.retiredChatModels.contains(storedBackup) ? d.groqBackupChatModel : storedBackup
        groqBaseURL = try c.decodeIfPresent(String.self, forKey: .groqBaseURL) ?? d.groqBaseURL
        transcriptionLanguage = try c.decodeIfPresent(String.self, forKey: .transcriptionLanguage) ?? d.transcriptionLanguage
        saveAudioForDebugging = try c.decodeIfPresent(Bool.self, forKey: .saveAudioForDebugging) ?? d.saveAudioForDebugging
        vadTrimmingEnabled = try c.decodeIfPresent(Bool.self, forKey: .vadTrimmingEnabled) ?? d.vadTrimmingEnabled
        dictionaryTerms = try c.decodeIfPresent([String].self, forKey: .dictionaryTerms) ?? d.dictionaryTerms
        customFillers = try c.decodeIfPresent([String].self, forKey: .customFillers) ?? d.customFillers
        retention = try c.decodeIfPresent(RetentionPolicy.self, forKey: .retention) ?? d.retention
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        onboardingComplete = try c.decodeIfPresent(Bool.self, forKey: .onboardingComplete) ?? d.onboardingComplete
    }

    /// Custom because `CodingKeys` carries the legacy `hotkey`/`hotkeys` keys (read-only, for
    /// migration only — see `init(from:)`) alongside the current `hotkeyCodes` property, which
    /// the compiler can't synthesize `encode(to:)` for.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hotkeyCodes, forKey: .hotkeyCodes)
        try c.encode(hotkeyMode, forKey: .hotkeyMode)
        try c.encode(sttEngine, forKey: .sttEngine)
        try c.encode(llmCleanupEnabled, forKey: .llmCleanupEnabled)
        try c.encode(groqWhisperModel, forKey: .groqWhisperModel)
        try c.encode(groqEndingCheckModel, forKey: .groqEndingCheckModel)
        try c.encode(groqChatModel, forKey: .groqChatModel)
        try c.encode(groqBackupChatModel, forKey: .groqBackupChatModel)
        try c.encode(groqBaseURL, forKey: .groqBaseURL)
        try c.encode(transcriptionLanguage, forKey: .transcriptionLanguage)
        try c.encode(saveAudioForDebugging, forKey: .saveAudioForDebugging)
        try c.encode(vadTrimmingEnabled, forKey: .vadTrimmingEnabled)
        try c.encode(dictionaryTerms, forKey: .dictionaryTerms)
        try c.encode(customFillers, forKey: .customFillers)
        try c.encode(retention, forKey: .retention)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(onboardingComplete, forKey: .onboardingComplete)
    }
}

public final class SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "lisper.settings.v1"
    private let queue = DispatchQueue(label: "lisper.settings")
    private var cached: AppSettings

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            cached = s
        } else { cached = AppSettings() }
    }

    public var settings: AppSettings { queue.sync { cached } }

    public func save(_ s: AppSettings) {
        queue.sync {
            cached = s
            if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: key) }
        }
    }

    public func update(_ mutate: (inout AppSettings) -> Void) {
        queue.sync {
            mutate(&cached)
            if let data = try? JSONEncoder().encode(cached) { defaults.set(data, forKey: key) }
        }
    }
}
