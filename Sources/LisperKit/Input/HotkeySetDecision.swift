// Sources/LisperKit/Input/HotkeySetDecision.swift

/// Pure, testable arbitration for a SET of simultaneously-enabled hotkeys.
///
/// Generalises the original Fn-only key decision from "is this the Fn key" to "is this one of my enabled
/// keys", and adds ownership.
///
/// Ownership is the load-bearing part. Every historical hotkey bug in this app is a
/// *phantom release* — an unrelated event interpreted as "the key went up", ending a take
/// that was still in progress (DEBUGGING-LOG 2026-06-14c, 2026-06-29, 2026-06-30).
/// Enabling several keys at once multiplies exactly that risk, so the first key down owns
/// the take and every other enabled key is ignored until the owner releases. A non-owning
/// key is structurally incapable of ending someone else's take.
///
/// Held-state is the *other* half, and answers a different question. Ownership answers
/// "whose take is this?"; `heldKeys` answers "is this key already physically down?".
/// Collapsing the two opened the mirror-image bug — a phantom *press*: `clearOwner()`
/// (Esc cancel, or a lock confirmed by a fresh press) drops ownership mid-hold, and the
/// Fn key's spurious `.function` events then read as a brand-new press on a key the user
/// never let go of, resurrecting a take they just cancelled (DEBUGGING-LOG 2026-08-03).
/// `isARepeat` covers this for F13–F15 only; `flagsChanged` has no such flag, so the
/// modifier hotkeys need the dedup here.
public struct HotkeySetDecision {
    public let enabled: Set<UInt16>
    public private(set) var owner: UInt16?

    /// Keycodes believed to be physically down right now. A key stranded in here
    /// blockades that hotkey (every press is deduped away), so ONLY a release or a
    /// `reset()` may remove one — and `HotkeyMonitor`'s watchdog polls the real physical
    /// key state for every held key, so a release the event monitors never saw still
    /// clears it.
    public private(set) var heldKeys: Set<UInt16> = []

    public init(enabled: Set<UInt16>) {
        self.enabled = enabled
    }

    /// Is this keycode one of the configured trigger keys?
    public func isEnabled(_ keyCode: UInt16) -> Bool {
        enabled.contains(keyCode)
    }

    /// - Returns: true when this press should START a take.
    public mutating func press(keyCode: UInt16) -> Bool {
        guard isEnabled(keyCode) else { return false }
        // Already down: an auto-repeat, or a spurious modifier event mid-hold. Not an edge,
        // and deliberately checked BEFORE ownership so it still holds after `clearOwner()`.
        guard !heldKeys.contains(keyCode) else { return false }
        heldKeys.insert(keyCode)
        guard owner == nil else { return false }   // a non-owning key
        owner = keyCode
        return true
    }

    /// - Returns: true when this release should END the take. Only the owner can.
    ///
    /// Held-state is dropped unconditionally (before the owner check) so a non-owning key
    /// — or a key whose take was already cancelled — can never strand itself.
    public mutating func release(keyCode: UInt16) -> Bool {
        heldKeys.remove(keyCode)
        guard isEnabled(keyCode), keyCode == owner else { return false }
        owner = nil
        return true
    }

    /// The take ended by some other route (Esc, a lock finished elsewhere) — drop ownership
    /// so the next press starts cleanly.
    ///
    /// Deliberately does NOT touch `heldKeys`: the key the user is still holding must not
    /// be able to start a second take before they let go. That coupling *was* the phantom
    /// press. Use `reset()` when held-state genuinely can't be trusted any more.
    public mutating func clearOwner() {
        owner = nil
    }

    /// Forget everything, including held-state. For when the event monitors are being torn
    /// down: after that, key-ups can be missed entirely, so believing a key is still held
    /// would blockade it — better to risk one phantom press than a permanently dead hotkey.
    public mutating func reset() {
        owner = nil
        heldKeys.removeAll()
    }

    /// Pressed-state for a modifier hotkey event.
    ///
    /// - Returns: nil when the event is not this key and must be IGNORED. Never treat nil
    ///   as a release — that is precisely the phantom-release bug.
    ///
    /// A key counts as down when EITHER its modifier flag OR its physical key state says
    /// so: the Fn/Globe `.function` flag clears spuriously while the key is still held.
    public static func isDown(eventKeyCode: UInt16, hotkeyCode: UInt16,
                              flagSet: Bool, physicallyDown: Bool) -> Bool? {
        guard eventKeyCode == hotkeyCode else { return nil }
        return flagSet || physicallyDown
    }

    /// Should the watchdog synthesise a release for a key it believes is HELD?
    ///
    /// Only when NEITHER signal still says down — the exact negation of `isDown`, so the
    /// watchdog and the event path can never disagree about what "held" means.
    ///
    /// Physical state alone is not enough. `CGEventSource.keyState` never reports Right ⌘
    /// (keycode 54) as down on this hardware — the press arrives with `flag=true phys=false`
    /// — so a physical-only watchdog fired ~0.5 s into every Right-⌘ take and killed it as
    /// `tooShort` (DEBUGGING-LOG 2026-08-03b). The modifier flag is the surviving down
    /// signal there, exactly as physical state is the surviving one for Fn, whose
    /// `.function` flag clears spuriously mid-hold.
    ///
    /// Callers pass `flagSet: false` for non-modifier hotkeys (F13–F15), which have no flag
    /// and whose physical state does read correctly.
    public static func shouldSynthesizeRelease(physicallyDown: Bool, flagSet: Bool) -> Bool {
        !(physicallyDown || flagSet)
    }
}
