// Sources/Lisper/Input/CorrectionWatcher.swift
import AppKit
import ApplicationServices
import LisperKit

/// After a paste lands, quietly watches the destination text field (via the
/// Accessibility API) for the user's manual fixes — "grok" retyped as "Groq" —
/// and reports them so AppDelegate can learn them into the dictionary (with Undo). Two snapshots, one diff, no polling:
/// the field is read once right after the paste and once ~20s later. Reading
/// fails harmlessly in apps with poor AX support (some web views); we just
/// learn nothing from that dictation.
final class CorrectionWatcher {
    var onSuggestions: (([WordCorrection]) -> Void)?

    private var element: AXUIElement?
    private var baseline: String?
    private var insertedText = ""
    private var knownTerms: [String] = []
    private var generation = 0   // a new dictation cancels the previous watch

    func beginWatch(insertedText: String, knownTerms: [String]) {
        guard PermissionsService.accessibilityGranted else { return }
        generation += 1
        let gen = generation
        self.insertedText = insertedText
        self.knownTerms = knownTerms
        // Give the synthetic ⌘V a beat to land, then snapshot the field.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.generation == gen else { return }
            guard let focused = Self.focusedElement(),
                  let value = Self.stringValue(of: focused),
                  value.contains(self.insertedText.prefix(40)) else { return }
            self.element = focused
            self.baseline = value
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                self?.compare(generation: gen)
            }
        }
    }

    private func compare(generation gen: Int) {
        guard generation == gen, let element, let baseline,
              let current = Self.stringValue(of: element),
              current != baseline,
              let (oldSeg, newSeg) = Self.changedSegments(old: baseline, new: current)
        else { return }

        let lowerInserted = insertedText.lowercased()
        let found = CorrectionDetector.corrections(original: oldSeg, edited: newSeg,
                                                   knownTerms: knownTerms)
            // only learn from fixes to words WE produced, not the user's own prose
            .filter { lowerInserted.contains($0.original.lowercased()) }
        if !found.isEmpty { onSuggestions?(found) }
    }

    // MARK: diff window

    /// Trims the common prefix/suffix of the two snapshots and expands the
    /// changed region to word boundaries, so the detector sees whole words.
    static func changedSegments(old: String, new: String) -> (String, String)? {
        guard old != new else { return nil }
        let o = Array(old), n = Array(new)
        var p = 0
        while p < o.count, p < n.count, o[p] == n[p] { p += 1 }
        var s = 0
        while s < o.count - p, s < n.count - p, o[o.count - 1 - s] == n[n.count - 1 - s] { s += 1 }

        var start = p
        while start > 0, !o[start - 1].isWhitespace { start -= 1 }
        var oEnd = o.count - s, nEnd = n.count - s
        while oEnd < o.count, !o[oEnd].isWhitespace { oEnd += 1 }
        while nEnd < n.count, !n[nEnd].isWhitespace { nEnd += 1 }
        guard start <= oEnd, start <= nEnd else { return nil }
        return (String(o[start..<oEnd]), String(n[start..<nEnd]))
    }

    // MARK: AX plumbing

    private static func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                            kAXFocusedUIElementAttribute as CFString,
                                            &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func stringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString,
                                            &value) == .success else { return nil }
        return value as? String
    }
}
