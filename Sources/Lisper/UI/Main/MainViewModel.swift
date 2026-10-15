import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers
import LisperKit

extension Notification.Name {
    /// Posted by AppDelegate whenever the pipeline persists a new session.
    static let lisperSessionSaved = Notification.Name("lisper.sessionSaved")
    /// Posted when settings change outside the main window (dictionary auto-learn).
    static let lisperSettingsChangedExternally = Notification.Name("lisper.settingsChangedExternally")
    static let lisperHotkeyCaptureBegan = Notification.Name("lisper.hotkeyCaptureBegan")
    static let lisperHotkeyCaptureEnded = Notification.Name("lisper.hotkeyCaptureEnded")
    /// Posted by AppDelegate when a Settings hotkey-capture must end from OUTSIDE
    /// SettingsView's own lifecycle (app deactivated, or the main window closed without
    /// `.onDisappear` firing). SettingsView forwards this straight to `capture.cancel()` —
    /// the same single choke point `.onDisappear` already uses. See finding #4, 2026-08-03.
    static let lisperEndHotkeyCapture = Notification.Name("lisper.endHotkeyCapture")
}

enum MainTab: String, CaseIterable, Identifiable {
    case home = "Home", insights = "Insights", dictionary = "Dictionary", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: return "square.grid.2x2"
        case .insights: return "chart.line.uptrend.xyaxis"
        case .dictionary: return "character.book.closed"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
final class MainViewModel: ObservableObject {
    let env: AppEnvironment
    let onSettingsChanged: () -> Void

    @Published var tab: MainTab = .home
    @Published var sessions: [SessionRecord] = []
    @Published var search = ""
    @Published var settings: AppSettings {
        didSet {
            env.settingsStore.save(settings)
            onSettingsChanged()
        }
    }
    @Published var apiKey: String = KeychainStore.loadAPIKey() ?? ""
    private var cancellables: Set<AnyCancellable> = []

    init(env: AppEnvironment, onSettingsChanged: @escaping () -> Void) {
        self.env = env
        self.onSettingsChanged = onSettingsChanged
        self.settings = env.settingsStore.settings
        reloadSessions()
        NotificationCenter.default.publisher(for: .lisperSessionSaved)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadSessions() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .lisperSettingsChangedExternally)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.settings = self.env.settingsStore.settings
            }
            .store(in: &cancellables)
    }

    @Published var lifetime: LifetimeStats?

    func reloadSessions() {
        let q = search.trimmingCharacters(in: .whitespaces)
        sessions = (try? q.isEmpty ? env.database.recentSessions(limit: 200)
                                   : env.database.searchSessions(query: q)) ?? []
        lifetime = try? env.database.lifetimeStats()
    }

    func deleteSession(_ s: SessionRecord) {
        if let id = s.id { _ = try? env.database.deleteSession(id: id) }
        reloadSessions()
    }

    func saveAPIKey() {
        KeychainStore.saveAPIKey(apiKey.trimmingCharacters(in: .whitespaces))
        onSettingsChanged()
    }

    /// Capture is armed — stop the hotkey monitor so the key being CHOSEN does not also
    /// start a recording. Paired with `hotkeyCaptureEnded()`.
    func hotkeyCaptureBegan() {
        NotificationCenter.default.post(name: .lisperHotkeyCaptureBegan, object: nil)
    }

    func hotkeyCaptureEnded() {
        NotificationCenter.default.post(name: .lisperHotkeyCaptureEnded, object: nil)
    }

    /// Export a session's saved WAV via a save panel. No-op if no audio on disk.
    func extractAudio(_ s: SessionRecord) {
        guard let id = s.id, AudioStore.exists(sessionId: id) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "lisper-\(id).wav"
        panel.allowedContentTypes = [.wav]
        if panel.runModal() == .OK, let dest = panel.url {
            try? FileManager.default.removeItem(at: dest)        // overwrite if user picked an existing name
            try? FileManager.default.copyItem(at: AudioStore.url(for: id), to: dest)
        }
    }

    func hasAudio(_ s: SessionRecord) -> Bool {
        guard let id = s.id else { return false }
        return AudioStore.exists(sessionId: id)
    }

    // MARK: Flow Score helpers — deterministic, computed from stored sessions

    /// Flow Score for a session, computed on read. Nothing is persisted: the score is a
    /// pure function of the raw transcript + duration, so the whole history scores itself
    /// (previously only LLM-analysed sessions had a score, which starved the trend chart).
    private func flowScore(for s: SessionRecord) -> FlowScore {
        let stats = TranscriptStats.compute(raw: s.rawTranscript,
                                            durationSeconds: s.durationSeconds,
                                            customFillers: settings.customFillers)
        let dis = DisfluencyStats.compute(raw: s.rawTranscript)
        return FlowScore.compute(stats: stats, disfluency: dis, durationSeconds: s.durationSeconds)
    }

    /// Sessions shorter than this don't say much about flow, so they're excluded.
    private static let minWordsForFlow = 40

    /// The most recent qualifying session's score.
    func heroFlowScore() -> FlowScore? {
        guard let s = (try? env.database.recentSessions(limit: 30))?
            .first(where: { $0.wordCount >= Self.minWordsForFlow }) else { return nil }
        return flowScore(for: s)
    }

    /// One averaged point per day for the trend chart.
    func flowTrend(limit: Int = 200) -> [(day: Date, mean: Int)] {
        let sessions = (try? env.database.recentSessions(limit: limit)) ?? []
        let points = sessions
            .filter { $0.wordCount >= Self.minWordsForFlow }
            .map { (date: $0.startedAt, overall: flowScore(for: $0).overall) }
        var cal = Calendar(identifier: .gregorian)   // never Calendar.current — Buddhist system calendar
        cal.timeZone = .current
        return FlowTrend.dailyMeans(points, calendar: cal)
    }

    /// Build a report bundle from a session + the user's note. Returns the folder.
    @discardableResult
    func reportBadDictation(_ s: SessionRecord, note: String) -> URL? {
        guard let id = s.id else { return nil }
        // Prefer the REAL debug record (rms, guardsFired, latency, error) captured
        // when the dictation ran — that's what makes a report diagnosable. Only
        // fall back to a record synthesized from the DB row if the rolling debug
        // log has already rotated/purged it.
        let rec = env.latestDebugRecord(forSession: id) ?? DictationDebugRecord(
            timestamp: s.startedAt, sessionId: id, durationSeconds: s.durationSeconds,
            rms: 0, engineUsed: s.engineUsed, cleanupUsed: s.cleanupUsed,
            rawTranscript: s.rawTranscript, cleanedText: s.cleanedText,
            guardsFired: [], latencyMs: 0, error: nil)
        let st = env.settingsStore.settings
        // NEVER include the API key — only these non-secret fields.
        let snapshot: [String: String] = [
            "dictionaryTerms": st.dictionaryTerms.joined(separator: ", "),
            "transcriptionLanguage": st.transcriptionLanguage,
            "groqWhisperModel": st.groqWhisperModel,
            "groqEndingCheckModel": st.groqEndingCheckModel,
            "groqChatModel": st.groqChatModel,
            "sttEngine": st.sttEngine.rawValue,
        ]
        let audio = AudioStore.exists(sessionId: id) ? try? Data(contentsOf: AudioStore.url(for: id)) : nil
        return try? ReportWriter.write(into: env.reportsDir(), sessionId: id, record: rec,
                                       settingsSnapshot: snapshot, note: note, audio: audio ?? nil)
    }
}
