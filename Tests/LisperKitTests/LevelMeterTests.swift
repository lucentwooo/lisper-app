import Testing
@testable import LisperKit

/// The pill waveform ticks on its own steady clock and pulls from this meter, so it scrolls
/// at the same speed on every mic — the mic's own buffer rate (every 256 ms on 16 kHz
/// Bluetooth headphones) made it crawl.
@Suite struct LevelMeterTests {
    @Test func tickReturnsLoudestLevelSinceLastTick() {
        let m = LevelMeter()
        m.feed(0.2); m.feed(0.7); m.feed(0.4)
        #expect(m.tick() == 0.7)
    }

    /// Mic buffers arrive every ~100 ms and the display clock can't stay perfectly in phase,
    /// so one empty tick is timing jitter: HOLD the bar (a dip there was a visible stutter on
    /// every ~5th bar). Only a run of empty ticks — real silence or a stalled mic — eases down.
    @Test func oneEmptyTickHoldsThenRepeatedEmptyTicksDecay() {
        let m = LevelMeter()
        m.feed(0.8)
        #expect(m.tick() == 0.8)
        #expect(m.tick() == 0.8)   // jitter: hold
        let decayed = m.tick()
        #expect(decayed < 0.8)
        #expect(decayed > 0.3)
    }

    @Test func newAudioEndsTheHold() {
        let m = LevelMeter()
        m.feed(0.8); _ = m.tick(); _ = m.tick()
        m.feed(0.2)
        #expect(m.tick() == 0.2)
    }

    @Test func resetClearsState() {
        let m = LevelMeter()
        m.feed(0.9)
        m.reset()
        #expect(m.tick() == 0)
    }
}
