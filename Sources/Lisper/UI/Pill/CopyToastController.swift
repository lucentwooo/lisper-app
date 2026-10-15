// Sources/Lisper/UI/Pill/CopyToastController.swift
import AppKit
import SwiftUI

/// One-click copy for a take that had nowhere to go: no text box was focused when it finished,
/// so the words would otherwise only be reachable from Home. Bottom-center, above the pill;
/// a non-activating panel, so clicking Copy doesn't pull focus from the app you're in.
final class CopyToastController {
    private var panel: NSPanel?
    private var hideTask: DispatchWorkItem?

    func show(text: String) {
        dismiss()
        let view = CopyToast(
            text: text,
            onCopy: { [weak self] in
                Clipboard.copy(text)
                self?.scheduleHide(after: 0.9)
            },
            onDismiss: { [weak self] in self?.dismiss() })

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
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

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        if let f = screen?.visibleFrame {
            p.contentView?.layoutSubtreeIfNeeded()
            p.setContentSize(p.contentView?.fittingSize ?? NSSize(width: 340, height: 120))
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.minY + 70))
        }
        p.orderFrontRegardless()
        scheduleHide(after: 12)
    }

    func dismiss() {
        hideTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task)
    }
}

/// The pasteboard write behind every Copy button, so they all behave the same.
enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct CopyToast: View {
    let text: String
    let onCopy: () -> Void
    let onDismiss: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No text box — copy it").sectionLabel()
            Text(text)
                .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                .lineLimit(3).lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Button("Dismiss") { onDismiss() }.buttonStyle(QuietButtonStyle())
                Button {
                    copied = true
                    onCopy()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(AccentButtonStyle())
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
