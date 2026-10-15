// Sources/Lisper/Input/HotkeyMonitor.swift
import AppKit
import Carbon.HIToolbox
import LisperKit

/// Watches the configured keys globally (and locally when Lisper is frontmost).
/// Every enabled key is live at once; the first one down owns the take (HotkeySetDecision).
/// hold mode: onPress when key goes down, onRelease when it goes up.
/// toggle mode: onPress on every key-down — the delegate starts or stops from its state.
final class HotkeyMonitor {
    var onPress: (() -> Bool)?
    var onRelease: (() -> Bool)?

    private var globalMonitors: [Any] = []
    private var localMonitors: [Any] = []
    private(set) var hotkeyCodes: [UInt16] = [KeyCatalog.fn]
    private var decision = HotkeySetDecision(enabled: [KeyCatalog.fn])
    private(set) var mode: HotkeyMode = .hold
    /// The user's menu-bar "Pause Hotkey" toggle. Deliberately independent of `isCapturing`
    /// below — see DEBUGGING-LOG 2026-08-03 finding #3: sharing one Bool let the Settings
    /// key-capture notifications and the menu-bar item clobber each other's state.
    var isPaused = false
    /// Set for the duration of a Settings hotkey-capture (see AppDelegate's
    /// `lisperHotkeyCaptureBegan`/`Ended` observers). Kept separate from `isPaused` so pausing
    /// the monitor from the menu bar and pausing it for capture can't desync one another —
    /// each reason clears only its own flag.
    var isCapturing = false
    private var watchdog: Timer?

    /// The watchdog polls the real physical key state for every key the decision believes
    /// is HELD — not just the owner of the current take. Two reasons:
    ///  - a release can be missed entirely (swallowed by a secure-input field, or arriving
    ///    while `isPaused` or `isCapturing`), and a key stranded in `heldKeys` blockades that
    ///    hotkey forever
    ///    since `press()` dedups it — strictly worse than the phantom press it guards;
    ///  - held keys outlive ownership by design (Esc-cancel clears the owner mid-hold, and
    ///    toggle mode clears it on the press edge), so an owner-gated watchdog would switch
    ///    itself off exactly when the stranding risk starts.
    /// `owner != nil` implies its key is in `heldKeys`, so this strictly covers the old gate.
    ///
    /// It polls BOTH down-signals (physical state and, for modifiers, the live flag) and
    /// only synthesises a release when neither says down — see
    /// `HotkeySetDecision.shouldSynthesizeRelease`. Physical state alone is a lie for
    /// Right ⌘/⌥, which never read as physically down at all.
    private func startWatchdog() {
        guard watchdog == nil else { return }   // idempotent: don't reset the interval
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            for keyCode in self.decision.heldKeys {
                let physical = CGEventSource.keyState(.combinedSessionState, key: keyCode)
                let flagSet = self.currentFlagSet(forKeyCode: keyCode)
                guard HotkeySetDecision.shouldSynthesizeRelease(physicallyDown: physical,
                                                               flagSet: flagSet) else { continue }
                HotkeyTrace.log("watchdog: key \(keyCode) released (phys=\(physical) flag=\(flagSet)) -> synth release")
                self.transition(keyCode: keyCode, down: false)
            }
            self.syncWatchdog()
        }
        // .common (not the default mode) so menu tracking or a modal panel can't stall the
        // one mechanism that un-strands a held key.
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    /// Run the watchdog exactly while some key is believed held.
    private func syncWatchdog() {
        if decision.heldKeys.isEmpty { stopWatchdog() } else { startWatchdog() }
    }

    /// Is this hotkey's modifier flag set RIGHT NOW (not "in some event we received")?
    ///
    /// `NSEvent.modifierFlags` is device-INdependent: Left and Right variants (e.g. ⌘) share
    /// one flag, so holding Left ⌘ reads as "Right ⌘ still down". That errs toward keeping
    /// the take alive, which is the safe direction — the real flagsChanged release still ends
    /// it, and the next poll un-strands the key once ⌘ is fully up.
    /// Non-modifier hotkeys (F13–F15) have no flag; their physical state reads correctly.
    private func currentFlagSet(forKeyCode keyCode: UInt16) -> Bool {
        guard let mod = KeyCatalog.modifier(for: keyCode) else { return false }
        return NSEvent.modifierFlags.contains(mod.flagName.nsFlag)
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    /// The session ended outside the normal press/release flow (e.g. Esc cancel or
    /// a lock finished by a fresh press) — make the next key-down start a new one.
    /// Ownership only: the key the user is STILL holding must not restart a take they
    /// just cancelled. Held-state is cleared by its own release (or the watchdog).
    func noteSessionEnded() {
        decision.clearOwner()
    }

    func configure(hotkeyCodes: [UInt16], mode: HotkeyMode) {
        self.hotkeyCodes = hotkeyCodes.isEmpty ? [KeyCatalog.fn] : hotkeyCodes
        self.decision = HotkeySetDecision(enabled: Set(self.hotkeyCodes))
        self.mode = mode
        stop(); start()
    }

    func start() {
        let flagsHandler: (NSEvent) -> Void = { [weak self] e in self?.handleFlags(e) }
        let keyHandler: (NSEvent, Bool) -> Void = { [weak self] e, down in self?.handleKey(e, down: down) }

        // Global monitors require Accessibility trust; WITHOUT it they register fine but
        // silently receive nothing. The app gates on PermissionsService.accessibilityGranted.
        globalMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsHandler) as Any)
        globalMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { keyHandler($0, true) } as Any)
        globalMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { keyHandler($0, false) } as Any)
        localMonitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in flagsHandler(e); return e } as Any)
        localMonitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in keyHandler(e, true); return e } as Any)
        localMonitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyUp) { e in keyHandler(e, false); return e } as Any)
    }

    func stop() {
        (globalMonitors + localMonitors).forEach { NSEvent.removeMonitor($0) }
        globalMonitors.removeAll(); localMonitors.removeAll()
        // FULL reset, not just clearOwner(): with the monitors gone, a key-up can be missed
        // entirely, so held-state is no longer trustworthy and keeping it would blockade the
        // hotkey. (`configure()` additionally builds a fresh decision, which resets anyway.)
        decision.reset()
        stopWatchdog()
    }

    // The Globe/Fn key fires unreliable flagsChanged events (unrelated modifier changes, and
    // `.function` clears while still held) that used to cause phantom releases — a 0.0s recording
    // discarded as "tooShort", so the pill only flashed. `HotkeySetDecision.isDown` filters events
    // that aren't this key (nil == ignore, NEVER a release) and treats the key as down on flag OR
    // physical state; the watchdog backstops a missed release. See HotkeySetDecisionTests and
    // DEBUGGING-LOG 2026-06-14c.
    private func handleFlags(_ event: NSEvent) {
        guard !isPaused, !isCapturing else { return }
        // Only modifier hotkeys arrive as flagsChanged.
        guard decision.isEnabled(event.keyCode),
              let mod = KeyCatalog.modifier(for: event.keyCode) else { return }
        let physical = CGEventSource.keyState(.combinedSessionState, key: event.keyCode)
        // The device-DEPENDENT mask is what distinguishes Left ⌃ from Right ⌃ in the raw
        // flags. Fn has no such mask and is identified by `.function` alone.
        let flagSet: Bool
        if let mask = mod.deviceMask {
            flagSet = event.modifierFlags.rawValue & mask != 0
        } else {
            flagSet = event.modifierFlags.contains(.function)
        }
        guard let isDown = HotkeySetDecision.isDown(eventKeyCode: event.keyCode,
                                                    hotkeyCode: event.keyCode,
                                                    flagSet: flagSet, physicallyDown: physical)
        else { return }   // not ours — ignore, never a release
        HotkeyTrace.log("flags key=\(KeyCatalog.label(for: event.keyCode)) code=\(event.keyCode) flag=\(flagSet) phys=\(physical) -> down=\(isDown)")
        transition(keyCode: event.keyCode, down: isDown)
    }

    private func handleKey(_ event: NSEvent, down: Bool) {
        guard !isPaused, !isCapturing else { return }
        // Auto-repeat must never reach `press()`. `noteSessionEnded()` clears ownership mid-hold
        // (Esc cancel), where the old `keyIsDown` flag stayed true and swallowed the repeats — so
        // a still-held F13's next repeat would silently start a fresh take.
        guard !event.isARepeat else { return }
        guard decision.isEnabled(event.keyCode),
              KeyCatalog.modifier(for: event.keyCode) == nil else { return }
        transition(keyCode: event.keyCode, down: down)
    }

    private func transition(keyCode: UInt16, down: Bool) {
        HotkeyTrace.log("transition code=\(keyCode) down=\(down) owner=\(String(describing: decision.owner)) mode=\(mode)")
        switch mode {
        case .hold:
            if down, decision.press(keyCode: keyCode) {
                HotkeyTrace.log("  -> PRESS edge"); _ = onPress?()
            } else if !down, decision.release(keyCode: keyCode) {
                HotkeyTrace.log("  -> RELEASE edge"); _ = onRelease?()
            } else {
                HotkeyTrace.log("  -> no edge (ignored)")
            }
        case .toggle:
            if down, decision.press(keyCode: keyCode) {
                HotkeyTrace.log("  -> TOGGLE edge")
                decision.clearOwner()   // in toggle mode a press is an edge, not a hold
                // Every press goes to onPress, which starts or stops from the live recording
                // state. A local on/off flag desynced whenever a start was refused (while
                // "Polishing…", a mic error, after the 10-min auto-stop) — then the next
                // press went to onRelease, did nothing, and a take needed two presses.
                _ = onPress?()
            } else {
                if !down { _ = decision.release(keyCode: keyCode) }   // drop held-state
                HotkeyTrace.log("  -> no edge (ignored)")
            }
        }
        // Held-state, not ownership, decides whether the watchdog must run — a held key
        // outlives its take (Esc cancel, toggle's press edge) and only the watchdog can
        // un-strand it if its release is never delivered.
        syncWatchdog()
    }
}
