import AppKit
import SwiftUI
import LisperKit

/// Floating, non-activating panel at the bottom-center of the active screen.
final class PillController {
    let model = PillModel()
    /// The recorder feeds mic levels here (any thread); the waveform pulls them on its own
    /// steady clock so it moves at the same speed on every mic (see LevelMeter).
    let meter = LevelMeter()
    /// 10 bars/s — the mic delivers a buffer every ~100 ms on every device (measured on the
    /// MacBook mic and Bluetooth headphones), which is also how the waveform moved before.
    private static let waveformTick: TimeInterval = 0.1
    private var waveformTimer: Timer?
    private var panel: NSPanel?
    private var hideTask: DispatchWorkItem?

    func show(phase: PillPhase) {
        hideTask?.cancel()
        model.phase = phase
        if phase == .listening { startWaveform() } else { stopWaveform() }
        if panel == nil { makePanel() }
        position()
        panel?.orderFrontRegardless()
        if case .success = phase { scheduleHide(after: 1.2) }
        if case .error = phase { scheduleHide(after: 3.0) }
    }

    func hide() {
        hideTask?.cancel()
        stopWaveform()
        model.phase = .hidden
        panel?.orderOut(nil)
    }

    private func startWaveform() {
        guard waveformTimer == nil else { return }
        let timer = Timer(timeInterval: Self.waveformTick, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.model.push(level: self.meter.tick())
        }
        RunLoop.main.add(timer, forMode: .common)
        waveformTimer = timer
    }

    private func stopWaveform() {
        waveformTimer?.invalidate()
        waveformTimer = nil
        meter.reset()
    }

    private func scheduleHide(after seconds: TimeInterval) {
        let task = DispatchWorkItem { [weak self] in self?.hide() }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task)
    }

    private func makePanel() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 30),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: PillView(model: model))
        panel = p
    }

    private func position() {
        guard let panel else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 120, height: 30))
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 24))
    }
}
