import SwiftUI
import LisperKit

/// First-run experience — full-bleed cinematic hero on the glow canvas:
/// the orb breathing at center, poster-weight masthead, quiet copy.
struct OnboardingView: View {
    @ObservedObject var model: MainViewModel
    @State private var step = 0
    @State private var micGranted = PermissionsService.microphoneGranted
    @State private var axGranted = PermissionsService.accessibilityGranted
    @State private var keyDraft = ""
    @State private var breathe = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            orb

            switch step {
            case 0:
                Text("Lisper").eyebrow()
                Text("Speak. It's written.")
                    .font(Theme.mastheadBlack(52)).kerning(-2)
                    .foregroundColor(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                body13("Hold a key anywhere on your Mac, say what you mean, and polished text lands at your cursor. No window. No friction.")
                Button("Begin setup") { withAnimation { step = 1 } }
                    .buttonStyle(AccentButtonStyle()).padding(.top, 6)
            case 1:
                stepCard(title: "Microphone", granted: micGranted,
                         text: "Lisper listens only while you hold the key. Recordings aren't kept unless you turn that on in Settings.") {
                    PermissionsService.requestMicrophone { ok in micGranted = ok }
                } openSettings: { PermissionsService.openMicrophoneSettings() }
            case 2:
                stepCard(title: "Accessibility", granted: axGranted,
                         text: "So Lisper can watch your hotkey, place text into any app, and learn a word when you correct its spelling. It never records your typing.",
                         hint: "Toggle already on but stuck here? macOS pinned an older build — in System Settings, remove Lisper with the − button, then Grant again.") {
                    PermissionsService.requestAccessibility()
                } openSettings: { PermissionsService.openAccessibilitySettings() }
            case 3:
                heading("Free the Fn key")
                body13("While Lisper runs, it mutes the system 🌐-key action automatically — no language switching mid-dictation. You can also pick a different hotkey later in Settings.")
                Button("Done") { withAnimation { step = 4 } }.buttonStyle(AccentButtonStyle())
            case 4:
                heading("One key unlocks it all")
                body13("A free Groq key powers the best transcription and AI cleanup. Skip it to run fully on-device with Apple's engine.")
                SecureField("gsk_…", text: $keyDraft)
                    .textFieldStyle(.plain).foregroundColor(Theme.textPrimary)
                    .padding(10).frame(width: 320)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline)))
                HStack(spacing: 10) {
                    Button("Skip for now") { finish() }.buttonStyle(GhostButtonStyle())
                    Button("Save & finish") {
                        model.apiKey = keyDraft; model.saveAPIKey(); finish()
                    }.buttonStyle(AccentButtonStyle())
                }
                Link("console.groq.com/keys", destination: URL(string: "https://console.groq.com/keys")!)
                    .font(.system(size: 11)).foregroundColor(Theme.accent)
            default:
                heading("Try it")
                let keyLabels = model.settings.hotkeyCodes.map(KeyCatalog.label(for:)).joined(separator: " or ")
                body13("Click into any text field, hold \(keyLabels), and say hello. Esc cancels; \(keyLabels) + Space locks hands-free.")
                Button("Open Lisper") {
                    model.settings.onboardingComplete = true
                    model.tab = .home
                }.buttonStyle(AccentButtonStyle())
            }
            Spacer()

            HStack(spacing: 7) {
                ForEach(0..<5) { i in
                    Circle().fill(i <= step ? Theme.accent : Color.white.opacity(0.16))
                        .frame(width: 6, height: 6)
                }
            }.padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { breathe = true }
        .onReceive(timer) { _ in
            micGranted = PermissionsService.microphoneGranted
            axGranted = PermissionsService.accessibilityGranted
            if step == 1 && micGranted { withAnimation { step = 2 } }
            if step == 2 && axGranted { withAnimation { step = 3 } }
        }
    }

    /// The brand orb, breathing slowly on the hero step.
    private var orb: some View {
        OrbMark(size: step == 0 ? 104 : 76, glow: true)
            .scaleEffect(breathe && step == 0 ? 1.06 : 1.0)
            .animation(step == 0 ? .easeInOut(duration: 4.5).repeatForever(autoreverses: true) : .default,
                       value: breathe)
            .animation(.easeOut(duration: 0.4), value: step)
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(Theme.masthead(32)).kerning(-1.2)
            .foregroundColor(Theme.textPrimary).multilineTextAlignment(.center)
    }

    private func body13(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14)).foregroundColor(Theme.textSecondary)
            .multilineTextAlignment(.center).lineSpacing(4)
            .frame(maxWidth: 420)
    }

    private func finish() {
        withAnimation { step = 5 }
    }

    @ViewBuilder
    private func stepCard(title: String, granted: Bool, text: String, hint: String? = nil,
                          request: @escaping () -> Void, openSettings: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundColor(granted ? Theme.success : Theme.textTertiary)
            heading(title)
        }
        body13(text)
        if granted {
            Button("Continue") { withAnimation { step += 1 } }.buttonStyle(AccentButtonStyle())
        } else {
            HStack(spacing: 10) {
                Button("Grant access") { request() }.buttonStyle(AccentButtonStyle())
                Button("Open System Settings") { openSettings() }.buttonStyle(GhostButtonStyle())
            }
            if let hint {
                Text(hint).font(.system(size: 11)).foregroundColor(Theme.textTertiary)
                    .multilineTextAlignment(.center).frame(maxWidth: 400)
            }
        }
    }
}
