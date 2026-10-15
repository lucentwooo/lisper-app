import Foundation
import LisperKit

/// Builds the pipeline from current settings. Rebuilt whenever settings change.
final class AppEnvironment {
    let settingsStore = SettingsStore()
    let database: LisperDatabase

    /// ~/Library/Application Support/Lisper/debug
    func debugDir() -> URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lisper/debug", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func reportsDir() -> URL { debugDir().appendingPathComponent("reports", isDirectory: true) }

    private lazy var debugLog = DebugLog(fileURL: debugDir().appendingPathComponent("dictations.jsonl"))

    /// The real captured debug record for a session (rms / guardsFired / latency),
    /// if the rolling debug log still has it. Used to build an accurate "Report
    /// bad dictation" bundle instead of fabricating empty metrics.
    func latestDebugRecord(forSession id: Int64) -> DictationDebugRecord? {
        debugLog.latestRecord(forSession: id)
    }

    init() {
        database = (try? LisperDatabase.standard()) ?? (try! LisperDatabase(queue: .init()))
        try? database.prune(retention: settingsStore.settings.retention)
        AudioStore.purgeExpired()
    }

    func makePipeline() -> DictationPipeline {
        let s = settingsStore.settings
        let apiKey = KeychainStore.loadAPIKey()
        let guardLog = GuardLog()

        var groqSTT: TranscriptionEngine? = nil
        var llm: CleanupEngine? = nil
        if let apiKey, !apiKey.isEmpty {
            let client = GroqClient(baseURL: s.groqBaseURL, apiKey: apiKey)
            groqSTT = GroqWhisperEngine(client: client, model: s.groqWhisperModel,
                                        language: s.transcriptionLanguage, guardLog: guardLog,
                                        endingCheckModel: s.distinctEndingCheckModel)
            if s.llmCleanupEnabled {
                let main = LLMCleanupEngine(client: client, model: s.groqChatModel)
                llm = s.distinctBackupChatModel.map {
                    RateLimitFallbackCleanup(primary: main, backup: LLMCleanupEngine(client: client, model: $0))
                } ?? main
            }
        }
        let apple = AppleSpeechEngine()
        let primary: TranscriptionEngine? = (s.sttEngine == .groq && groqSTT != nil) ? groqSTT : apple
        let fallback: TranscriptionEngine? = (s.sttEngine == .groq && groqSTT != nil) ? apple : nil
        let trimmer: VoiceActivityTrimmer? = s.vadTrimmingEnabled ? EnergyVoiceActivityTrimmer() : nil
        return DictationPipeline(primarySTT: primary, fallbackSTT: fallback,
                                 llmCleanup: llm, ruleCleanup: RuleCleanupEngine(),
                                 database: database, debugLog: debugLog, guardLog: guardLog,
                                 trimmer: trimmer)
    }

    func cleanupContext() -> CleanupContext {
        let s = settingsStore.settings
        let front = TextInserter.frontmostApp()
        return CleanupContext(appName: front.name, bundleID: front.bundleID,
                              dictionaryTerms: s.dictionaryTerms)
    }
}
