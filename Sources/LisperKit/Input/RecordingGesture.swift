import Foundation

/// Resolves the Fn→Space "lock race" deterministically, independent of event order.
///
/// Pressing Fn cold-starts the mic engine, which blocks the main thread ~100–300 ms. The
/// user's Space-lock (a CGEventTap event) and Fn-release (an NSEvent flagsChanged) both queue
/// during that freeze and are processed in nondeterministic order. If the release won, the old
/// code finished the take at ~0 s and discarded it silently — the user's speech vanished.
///
/// This makes the outcome order-independent: a release inside `lockWindow` after the press
/// DEFERS (the caller schedules a `graceSeconds` timer) so a racing lock can still win; a
/// release past the window — a genuine hold-to-talk — finishes immediately with no added
/// latency. Pure logic driven by `AppDelegate`; timestamps are injected so it is fully testable.
public final class RecordingGesture {
    public enum ReleaseEffect: Equatable {
        case finish                       // stop capture + transcribe now
        case scheduleFinishAfter(Double)  // defer; caller starts a timer, then calls graceElapsed()
    }

    private let lockWindow: Double
    private let graceSeconds: Double
    private var pressedAt: TimeInterval?   // nil ⇒ not recording
    private var locked = false
    private var pendingFinish = false

    public init(lockWindow: Double = 0.5, graceSeconds: Double = 0.3) {
        self.lockWindow = lockWindow
        self.graceSeconds = graceSeconds
    }

    /// Fn down — a take begins. Resets all per-take state.
    public func begin(at t: TimeInterval) {
        pressedAt = t
        locked = false
        pendingFinish = false
    }

    /// Fn up. Returns what the caller should do, or `nil` to ignore (locked, or not recording).
    public func release(at t: TimeInterval) -> ReleaseEffect? {
        guard let pressedAt else { return nil }     // not recording
        if locked { return nil }                    // hands-free: ignore the release
        if t - pressedAt < lockWindow {
            pendingFinish = true
            return .scheduleFinishAfter(graceSeconds)   // a Space-lock may be racing — wait it out
        }
        self.pressedAt = nil
        return .finish                              // genuine hold — finish immediately
    }

    /// Space pressed to lock hands-free. Returns true if the lock took effect — in which case
    /// the caller must cancel any pending deferred finish it scheduled.
    public func lock() -> Bool {
        guard pressedAt != nil, !locked else { return false }
        locked = true
        pendingFinish = false
        return true
    }

    /// The deferral timer fired. Returns true if the take should finish now (no lock arrived).
    public func graceElapsed() -> Bool {
        guard pendingFinish, !locked else { return false }
        pendingFinish = false
        pressedAt = nil
        return true
    }
}
