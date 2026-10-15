// Sources/Lisper/Input/FocusProbeDebugHook.swift
#if DEBUG
import AppKit
import LisperKit

/// DEBUG builds only: a test harness for the paste-target logic, which needs a process with
/// Accessibility trust (Lisper has it; a terminal usually doesn't). Post the distributed
/// notification `lisper.debug.probeFocus` with a marker string as its object, and Lisper logs
/// what it sees in the frontmost app to /tmp/lisper-hotkey.log:
///   swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("lisper.debug.probeFocus"), object: "MARKER", userInfo: nil, deliverImmediately: true)'
enum FocusProbeDebugHook {
    static func install() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("lisper.debug.probeFocus"), object: nil, queue: .main
        ) { note in
            let marker = note.object as? String ?? ""
            let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            let facts = FocusedTextProbe.facts()
            let decision = PasteTargetDecision.decide(facts)
            let text = FocusedTextProbe.focusedText()
            let offer = PasteLandedCheck.offerCopy(hasElement: text.hasElement, role: text.role,
                                                   value: text.value, pasted: marker)
            HotkeyTrace.log("probe app=\(app) role=\(facts.role ?? "none") cursor=\(facts.hasTextCursor) chromium=\(facts.isChromiumBased) valueReadable=\(text.value != nil) -> before=\(decision) afterPasteOfferCopy=\(offer)")
        }
    }
}
#endif
