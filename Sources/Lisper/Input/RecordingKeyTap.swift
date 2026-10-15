// Sources/Lisper/Input/RecordingKeyTap.swift
import AppKit

/// Intercepts Esc (cancel) and Space (lock) while a recording is in flight, swallowing
/// the keystroke so it never reaches the frontmost app. Also reports every other keyDown
/// via `onOtherKey`, without swallowing it — used to detect a foreign key joining the
/// hold (see `RecordingAbortDecision`) while still letting the shortcut it belongs to
/// (e.g. ⌃C) reach the frontmost app. Started on record start and stopped on
/// finish/cancel — outside a recording no tap exists at all.
///
/// A handler set to nil lets that key pass through unmodified (e.g. once a recording
/// is locked, Space should type spaces again). A handler returns whether it consumed the
/// key — `false` passes it through too, so a tap left armed with no take behind it can never
/// eat the user's Space/Esc (DEBUGGING-LOG 2026-10-10). Requires Accessibility trust; if the
/// tap can't be created the keys simply behave normally.
final class RecordingKeyTap {
    var onEscape: (() -> Bool)?
    var onSpace: (() -> Bool)?
    /// Any keyDown that is not Esc or Space, while a recording is in flight. Unlike those
    /// two the event is NOT swallowed — a shortcut the user meant must still reach the app.
    var onOtherKey: ((Int64) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private static let escapeKey: Int64 = 53
    private static let spaceKey: Int64 = 49

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        // Attached to the main run loop, so the callback runs on the main thread and
        // handler reads/writes never race.
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<RecordingKeyTap>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                me.reenable()
                return Unmanaged.passUnretained(event)
            }
            guard type == .keyDown else { return Unmanaged.passUnretained(event) }
            switch event.getIntegerValueField(.keyboardEventKeycode) {
            case RecordingKeyTap.escapeKey:
                guard let handler = me.onEscape, handler() else { break }
                return nil   // swallowed
            case RecordingKeyTap.spaceKey:
                guard let handler = me.onSpace, handler() else { break }
                return nil   // swallowed
            default:
                me.onOtherKey?(event.getIntegerValueField(.keyboardEventKeycode))
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        tap = nil
        onEscape = nil
        onSpace = nil
        onOtherKey = nil
    }

    private func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }
}
