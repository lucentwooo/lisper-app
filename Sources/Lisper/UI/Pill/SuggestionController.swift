// Sources/Lisper/UI/Pill/SuggestionController.swift
import AppKit
import SwiftUI
import LisperKit

/// The small "Added to dictionary" toast — appears bottom-center above the pill when Lisper
/// learns a word you corrected after it pasted (Wispr-style auto-learn). The words are
/// already in the dictionary; Undo takes them back out.
final class SuggestionController {
    var onUndo: (([String]) -> Void)?
    private var panel: NSPanel?
    private var hideTask: DispatchWorkItem?
    /// Everything the toast currently on screen covers. A second learn while it is up joins
    /// it rather than replacing it — otherwise the first words would lose their Undo.
    private var shown: [WordCorrection] = []

    func show(learned new: [WordCorrection]) {
        guard !new.isEmpty else { return }
        let earlier = panel == nil ? [] : shown
        let corrections = earlier + new.filter { n in !earlier.contains { $0.corrected == n.corrected } }
        dismiss()
        shown = corrections
        let view = LearnedToast(
            corrections: Array(corrections.prefix(3)),
            moreCount: max(0, corrections.count - 3),
            onUndo: { [weak self] in
                self?.onUndo?(corrections.map(\.corrected))
                self?.dismiss()
            },
            onDismiss: { [weak self] in self?.dismiss() })

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: view)
        panel = p

        if let screen = NSScreen.main {
            p.contentView?.layoutSubtreeIfNeeded()
            p.setContentSize(p.contentView?.fittingSize ?? NSSize(width: 320, height: 120))
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.minY + 70))
        }
        p.orderFrontRegardless()

        let task = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: task)
    }

    func dismiss() {
        hideTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
        shown = []
    }
}

private struct LearnedToast: View {
    let corrections: [WordCorrection]
    let moreCount: Int
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Added to dictionary").sectionLabel()
            ForEach(corrections, id: \.corrected) { c in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12)).foregroundColor(Theme.success)
                    Text(c.corrected)
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.textPrimary)
                    Text("was \u{201C}\(c.original)\u{201D}")
                        .font(.system(size: 11)).foregroundColor(Theme.textTertiary)
                    Spacer(minLength: 16)
                }
            }
            if moreCount > 0 {
                Text("+\(moreCount) more").font(.system(size: 11)).foregroundColor(Theme.textTertiary)
            }
            HStack {
                Spacer()
                Button("Undo") { onUndo() }.buttonStyle(GhostButtonStyle())
                Button("OK") { onDismiss() }.buttonStyle(QuietButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.85))
                .overlay(GrainOverlay().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1))
                .shadow(color: Theme.glowDeep.opacity(0.3), radius: 18, y: 6)
        )
    }
}
