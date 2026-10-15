// Sources/Lisper/Input/TextInserter.swift
import AppKit
import Carbon.HIToolbox

/// Inserts text at the cursor of the frontmost app: clipboard set -> synthetic ⌘V -> clipboard restore.
enum TextInserter {
    /// Returns false if insertion was blocked (no Accessibility trust, or secure input) —
    /// text stays on the clipboard so the user can ⌘V manually.
    @discardableResult
    static func insert(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let setCount = pasteboard.changeCount

        // CGEvent.post silently no-ops without Accessibility trust — without this guard
        // we'd report success while nothing pasted, then restore the old clipboard over
        // the transcript.
        guard PermissionsService.accessibilityGranted, !IsSecureEventInputEnabled() else { return false }

        let src = CGEventSource(stateID: .combinedSessionState)
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let vUp = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)

        // Restore the old clipboard once the paste has landed — but only if nothing
        // else has touched the pasteboard since we set it (changeCount still ours).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard pasteboard.changeCount == setCount else { return }
            restore(saved, to: pasteboard)
        }
        return true
    }

    /// Every item and every type on the pasteboard — an image, Finder files, rich text —
    /// not just the plain-string flavor. Saving only the string used to wipe a copied image
    /// or file (and flatten rich text) on every dictation.
    ///
    /// Bounded: file *promises* are skipped (the source app renders them on demand — reading
    /// one can stall the paste on a slow app), and once `maxSnapshotBytes` is reached no
    /// further formats are read. Text and images, the common cases, are far below the cap.
    static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        var budget = maxSnapshotBytes
        return (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types where budget > 0 && !type.rawValue.lowercased().contains("promise") {
                guard let data = item.data(forType: type) else { continue }
                copy.setData(data, forType: type)
                budget -= data.count
            }
            return copy
        }
    }

    private static let maxSnapshotBytes = 64 * 1024 * 1024

    static func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    static func frontmostApp() -> (name: String, bundleID: String) {
        let app = NSWorkspace.shared.frontmostApplication
        return (app?.localizedName ?? "Unknown", app?.bundleIdentifier ?? "unknown")
    }
}
