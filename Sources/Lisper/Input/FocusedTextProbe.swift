// Sources/Lisper/Input/FocusedTextProbe.swift
import AppKit
import ApplicationServices
import LisperKit

/// Reads what is focused in the frontmost app right before a paste, for PasteTargetDecision.
/// Best-effort: any AX failure reads as "no focused element", which still pastes.
enum FocusedTextProbe {
    static func facts() -> FocusFacts {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return FocusFacts(hasFocusedElement: false, role: nil, hasTextCursor: false, isChromiumBased: false)
        }
        let chromium = isChromiumBased(app)
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.25)   // a hung app must not stall the paste
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return FocusFacts(hasFocusedElement: false, role: nil, hasTextCursor: false, isChromiumBased: chromium)
        }
        let element = value as! AXUIElement
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        var range: CFTypeRef?
        var settable: DarwinBoolean = false
        let hasCursor = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success
            || (AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
                && settable.boolValue)
        return FocusFacts(hasFocusedElement: true, role: role as? String, hasTextCursor: hasCursor,
                          isChromiumBased: chromium)
    }

    private static var chromiumCache: [String: Bool] = [:]

    /// Electron apps ship "Electron Framework"; Chromium browsers ship "<Name> Framework"
    /// (Google Chrome Framework, Brave Browser Framework, …) or CEF.
    static func isChromiumBased(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL else { return false }
        if let cached = chromiumCache[url.path] { return cached }
        let frameworks = (try? FileManager.default.contentsOfDirectory(
            atPath: url.appendingPathComponent("Contents/Frameworks").path)) ?? []
        let result = frameworks.contains { name in
            name.hasSuffix(" Framework.framework") || name.contains("Electron")
                || name.contains("Chromium") || name.contains("ArcCore")
        }
        chromiumCache[url.path] = result
        return result
    }
}
