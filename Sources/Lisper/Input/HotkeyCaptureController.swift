// Sources/Lisper/Input/HotkeyCaptureController.swift
import AppKit
import LisperKit

/// Records the next key the user presses, for the Settings picker.
///
/// Local monitors only — capture happens while the Settings window is frontmost, and using
/// global ones would need Accessibility trust for a UI affordance that does not require it.
/// The caller pauses `HotkeyMonitor` for the duration so the key being CHOSEN does not also
/// start a recording.
@MainActor
final class HotkeyCaptureController: ObservableObject {
    @Published private(set) var isArmed = false
    /// Set when the user pressed a key that cannot be a hotkey; capture stays armed.
    @Published private(set) var refusal: String?

    /// Fired every time capture ends for any reason (captured a key, Esc, or an external
    /// cancel()) while it was armed. The Settings view wires this to `hotkeyCaptureEnded()`
    /// so the hotkey monitor is ALWAYS resumed — including the Esc path below, which calls
    /// `cancel()` internally and has no other way to reach the view model.
    var onCaptureEnded: (() -> Void)?

    private var monitors: [Any] = []
    private var onCapture: ((UInt16) -> Void)?

    func start(onCapture: @escaping (UInt16) -> Void) {
        guard !isArmed else { return }
        self.onCapture = onCapture
        isArmed = true
        refusal = nil
        // flagsChanged catches modifiers (which never emit keyDown); keyDown catches the rest.
        let consume: (NSEvent) -> NSEvent? = { [weak self] e in
            guard let self, self.handle(e.keyCode) else { return e }
            return nil   // consumed — must not also reach the Settings UI
        }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: consume) as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: consume) as Any)
    }

    func cancel() {
        let wasArmed = isArmed
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        onCapture = nil
        isArmed = false
        refusal = nil
        if wasArmed { onCaptureEnded?() }
    }

    /// - Returns: true when the event was consumed and must not reach the UI.
    private func handle(_ keyCode: UInt16) -> Bool {
        guard isArmed else { return false }
        // Esc leaves capture without choosing anything.
        if keyCode == KeyCatalog.escape { cancel(); return true }
        // `flagsChanged` fires on RELEASE as well as press. Capture only a modifier that is
        // actually DOWN, using the same either-signal rule as `HotkeySetDecision.isDown`:
        // Right ⌘ never reads as physically down at all, and Fn's `.function` flag clears
        // spuriously mid-hold, so neither signal alone is sufficient.
        if let mod = KeyCatalog.modifier(for: keyCode) {
            let physical = CGEventSource.keyState(.combinedSessionState, key: keyCode)
            let flagSet = NSEvent.modifierFlags.contains(mod.flagName.nsFlag)
            guard physical || flagSet else { return true }   // a release — stay armed
        }
        if let rejection = KeyCatalog.rejection(for: keyCode) {
            refusal = rejection.reason      // stay armed so they can pick another key
            return true
        }
        let capture = onCapture
        cancel()
        capture?(keyCode)
        return true
    }
}
