import SwiftUI
import ServiceManagement
import LisperKit

struct SettingsView: View {
    @ObservedObject var model: MainViewModel
    @State private var keySaved = false
    @State private var revertingLogin = false
    @State private var loginItemHint: String?
    @StateObject private var capture = HotkeyCaptureController()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Masthead(eyebrow: "Preferences", title: "Settings",
                         subtitle: "Tune how Lisper listens, cleans, and remembers.")

                HairlineSection(label: "Hotkey",
                                desc: "The key you hold to dictate, anywhere in macOS.") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Keys").sectionLabel()
                            ForEach(model.settings.hotkeyCodes, id: \.self) { code in
                                HStack {
                                    Text(KeyCatalog.label(for: code))
                                        .foregroundColor(Theme.textPrimary)
                                    if KeyCatalog.isPrintable(code) {
                                        Text("types text — may interfere")
                                            .font(.system(size: 11))
                                            .foregroundColor(Theme.textFaint)
                                    }
                                    Spacer()
                                    Button("Remove") {
                                        var keys = model.settings.hotkeyCodes
                                        keys.removeAll { $0 == code }
                                        if !keys.isEmpty { model.settings.hotkeyCodes = keys }
                                    }
                                    // The last key can't be removed — a zero-key state would
                                    // make the app impossible to trigger.
                                    .disabled(model.settings.hotkeyCodes.count == 1)
                                }
                            }
                            Button(capture.isArmed ? "Press a key…  (Esc to cancel)" : "+ Add key") {
                                if capture.isArmed {
                                    capture.cancel()
                                } else {
                                    capture.onCaptureEnded = { model.hotkeyCaptureEnded() }
                                    model.hotkeyCaptureBegan()
                                    capture.start { code in
                                        var keys = model.settings.hotkeyCodes
                                        if !keys.contains(code) { keys.append(code) }
                                        model.settings.hotkeyCodes = keys
                                    }
                                }
                            }.buttonStyle(AccentButtonStyle())
                            if let refusal = capture.refusal {
                                Text(refusal)
                                    .font(.system(size: 11)).foregroundColor(Theme.textTertiary)
                            }
                            Text("Every key listed works at once — handy across a laptop and an external keyboard.")
                                .font(.system(size: 11)).foregroundColor(Theme.textFaint)
                        }
                        Picker("Mode", selection: $model.settings.hotkeyMode) {
                            Text("Hold to talk").tag(HotkeyMode.hold)
                            Text("Press to toggle").tag(HotkeyMode.toggle)
                        }.pickerStyle(.segmented).labelsHidden()
                        if model.settings.hotkeyCodes.contains(KeyCatalog.fn) {
                            Text("While Lisper runs, the system 🌐-key action (like switching input language) is muted so Fn belongs to dictation.")
                                .font(.system(size: 11)).foregroundColor(Theme.textTertiary)
                        }
                }

                HairlineSection(label: "Engines",
                                desc: "Bring your own Groq key for the best quality, or run free on-device.") {
                        SecureField("Groq API key (gsk_…)", text: $model.apiKey)
                            .textFieldStyle(.plain).foregroundColor(Theme.textPrimary)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                        HStack {
                            Button(keySaved ? "Saved ✓" : "Save key") {
                                model.saveAPIKey(); keySaved = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { keySaved = false }
                            }.buttonStyle(AccentButtonStyle())
                            Link("Get a free key at console.groq.com",
                                 destination: URL(string: "https://console.groq.com/keys")!)
                                .font(.system(size: 11)).foregroundColor(Theme.accent)
                        }
                        Picker("Transcription", selection: $model.settings.sttEngine) {
                            Text("Groq Whisper (best)").tag(STTEngineChoice.groq)
                            Text("Apple on-device (free, offline)").tag(STTEngineChoice.apple)
                        }.pickerStyle(.segmented).labelsHidden()
                        Toggle("AI cleanup (LLM polish — needs key)", isOn: $model.settings.llmCleanupEnabled)
                            .toggleStyle(.switch).font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                        Toggle("Trim silence before transcribing (fewer hallucinations, faster)",
                               isOn: $model.settings.vadTrimmingEnabled)
                            .toggleStyle(.switch).font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                        VStack(spacing: 6) {
                            HStack(spacing: 8) {
                                TextField("Whisper model", text: $model.settings.groqWhisperModel)
                                TextField("Ending-check model", text: $model.settings.groqEndingCheckModel)
                                    .help("Catches the end of a take the Whisper model dropped. Blank turns it off.")
                            }
                            HStack(spacing: 8) {
                                TextField("Chat model", text: $model.settings.groqChatModel)
                                TextField("Backup chat model", text: $model.settings.groqBackupChatModel)
                                    .help("Used only when the chat model is rate-limited")
                            }
                        }
                        .textFieldStyle(.plain).font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                        .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
                }

                HairlineSection(label: "Data",
                                desc: "Transcripts never leave this Mac except to your chosen API.") {
                        Picker("Keep history", selection: $model.settings.retention) {
                            Text("Forever").tag(RetentionPolicy.forever)
                            Text("90 days").tag(RetentionPolicy.days90)
                            Text("30 days").tag(RetentionPolicy.days30)
                        }.pickerStyle(.segmented).labelsHidden()
                        Toggle("Save audio for debugging (kept 7 days, never leaves this Mac)",
                               isOn: $model.settings.saveAudioForDebugging)
                            .toggleStyle(.switch).font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                        Toggle("Launch at login", isOn: $model.settings.launchAtLogin)
                            .toggleStyle(.switch).font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                            .onChange(of: model.settings.launchAtLogin) { _, newValue in
                                if revertingLogin { revertingLogin = false; return }
                                if newValue {
                                    do {
                                        try SMAppService.mainApp.register()
                                        loginItemHint = nil
                                    } catch {
                                        revertingLogin = true
                                        model.settings.launchAtLogin = false
                                        loginItemHint = "Couldn't register — move Lisper.app to /Applications first."
                                    }
                                } else {
                                    try? SMAppService.mainApp.unregister()
                                    loginItemHint = nil
                                }
                            }
                        if let loginItemHint {
                            Text(loginItemHint).font(.system(size: 11)).foregroundColor(Theme.destructive)
                        }
                }
            }
            .padding(.horizontal, 36).padding(.top, 36).padding(.bottom, 44)
        }
        // Settings is rendered by a `switch model.tab` in MainRootView, not a persisted
        // TabView — switching tabs while capture is armed deallocates this view's
        // `@StateObject capture` without ever calling cancel(). Without this, the local
        // NSEvent monitors leak and (worse) `hotkeyCaptureEnded()` never posts, leaving
        // HotkeyMonitor.isPaused stuck true — the dictation hotkey goes dead until relaunch.
        .onDisappear { capture.cancel() }
        // Covers the paths `.onDisappear` doesn't: the app deactivating while capture is
        // armed (⌘Tab away — local monitors then receive nothing, and the hotkey stays
        // paused with no trace in the hotkey log), and the main window closing via ⌘W,
        // which does NOT deallocate/replace this view's NSHostingView (see AppDelegate's
        // `isReleasedWhenClosed = false`) so `.onDisappear` cannot be relied on to fire.
        // See finding #4, 2026-08-03 final review.
        .onReceive(NotificationCenter.default.publisher(for: .lisperEndHotkeyCapture)) { _ in
            capture.cancel()
        }
    }
}
