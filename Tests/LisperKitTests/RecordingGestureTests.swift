import Testing
@testable import LisperKit

/// The Fn→Space "lock race": pressing Fn cold-starts the mic engine, which blocks the
/// main thread ~100–300 ms. The user's Space-lock and Fn-release both queue during that
/// freeze and run in nondeterministic order. If the release is processed first, the old
/// code finished the take at ~0 s and discarded it silently. RecordingGesture makes the
/// outcome order-independent: a release inside the lock window defers briefly so a racing
/// lock always wins; a genuine long hold finishes immediately.
struct RecordingGestureTests {
    private func gesture() -> RecordingGesture {
        RecordingGesture(lockWindow: 0.5, graceSeconds: 0.3)
    }

    // Normal lock ordering: Space-lock is processed BEFORE the Fn release.
    // The release while locked is ignored — recording continues hands-free.
    @Test func lockBeforeReleaseKeepsRecording() {
        let g = gesture()
        g.begin(at: 0)
        #expect(g.lock() == true)
        #expect(g.release(at: 0.2) == nil)   // locked → ignore the release
    }

    // THE RACE: the Fn release is processed BEFORE the Space-lock (out of order, during
    // cold-start). The release must DEFER, then the racing lock wins — the take is NOT lost.
    @Test func releaseBeforeLockDefersThenLockWins() {
        let g = gesture()
        g.begin(at: 0)
        #expect(g.release(at: 0.15) == .scheduleFinishAfter(0.3))  // defer, do NOT finish
        #expect(g.lock() == true)                                  // lock arrives a hair later
        #expect(g.graceElapsed() == false)                         // timer fires but locked → keep recording
    }

    // A genuine quick tap with no lock: defer briefly, then finish when no lock arrives.
    @Test func quickTapWithoutLockFinishesAfterGrace() {
        let g = gesture()
        g.begin(at: 0)
        #expect(g.release(at: 0.15) == .scheduleFinishAfter(0.3))
        #expect(g.graceElapsed() == true)    // no lock → finish
    }

    // A genuine long hold-to-talk: release is well past the lock window → finish immediately,
    // never adding deferral latency to normal dictation.
    @Test func longHoldFinishesImmediately() {
        let g = gesture()
        g.begin(at: 0)
        #expect(g.release(at: 3.0) == .finish)
    }

    // Lock cannot be re-applied or applied when idle.
    @Test func lockOnlyAppliesWhileRecordingAndOnce() {
        let g = gesture()
        #expect(g.lock() == false)           // idle → no-op
        g.begin(at: 0)
        #expect(g.lock() == true)
        #expect(g.lock() == false)           // already locked → no-op
    }

    // A fresh press resets state even if a prior deferral never resolved.
    @Test func beginResetsState() {
        let g = gesture()
        g.begin(at: 0)
        _ = g.release(at: 0.15)              // leaves a pending deferral
        g.begin(at: 10)                      // new take
        #expect(g.release(at: 13.0) == .finish)   // fresh long hold finishes normally
    }
}
