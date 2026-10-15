import AppKit

enum MenuBarState { case idle, recording, processing, warning }

final class MenuBarController {
    private var statusItem: NSStatusItem!
    var onOpenMain: (() -> Void)?
    var onTogglePause: ((Bool) -> Void)?
    /// The newest dictation's text, for "Copy Last Dictation" — works even after a relaunch.
    var lastDictation: (() -> String?)?
    private var paused = false

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        set(state: .idle)
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Lisper", action: #selector(openMain), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        let copyLast = NSMenuItem(title: "Copy Last Dictation", action: #selector(copyLastDictation),
                                  keyEquivalent: "c")
        copyLast.target = self
        menu.addItem(copyLast)
        let pause = NSMenuItem(title: "Pause Hotkey", action: #selector(togglePause(_:)), keyEquivalent: "p")
        pause.target = self
        menu.addItem(pause)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Lisper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func set(state: MenuBarState) {
        let (symbol, desc): (String, String)
        switch state {
        case .idle: (symbol, desc) = ("waveform", "Lisper idle")
        case .recording: (symbol, desc) = ("waveform.badge.mic", "Lisper recording")
        case .processing: (symbol, desc) = ("waveform.badge.magnifyingglass", "Lisper processing")
        case .warning: (symbol, desc) = ("waveform.badge.exclamationmark", "Lisper needs attention")
        }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: desc)
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: desc)
        statusItem.button?.image = img
    }

    @objc private func openMain() { onOpenMain?() }
    @objc private func copyLastDictation() {
        guard let text = lastDictation?(), !text.isEmpty else { NSSound.beep(); return }
        Clipboard.copy(text)
    }
    @objc private func togglePause(_ item: NSMenuItem) {
        paused.toggle()
        item.title = paused ? "Resume Hotkey" : "Pause Hotkey"
        onTogglePause?(paused)
    }
}
