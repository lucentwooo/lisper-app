import Foundation

/// Bridges the mic's buffer rate to the pill's steady display clock. The recorder `feed`s
/// a level per audio buffer (any thread); the pill `tick`s on its own fixed timer. Without
/// it the waveform scrolled at the mic's buffer rate — every 85 ms on the MacBook mic but
/// every 256 ms on 16 kHz Bluetooth headphones, which looked laggy.
public final class LevelMeter: @unchecked Sendable {
    /// Per tick with no new audio (after the first), the bar eases down to this fraction of
    /// its last height.
    public static let decay: Float = 0.6

    private let lock = NSLock()
    private var peakSinceTick: Float?
    private var last: Float = 0
    private var emptyTicks = 0

    public init() {}

    public func feed(_ level: Float) {
        lock.lock(); defer { lock.unlock() }
        peakSinceTick = max(peakSinceTick ?? 0, level)
    }

    /// The loudest level fed since the previous tick. With no new audio: one empty tick is
    /// clock/buffer jitter, so the bar holds (dipping it stuttered every ~5th bar); after that
    /// it eases down — real silence, or the mic stalled.
    public func tick() -> Float {
        lock.lock(); defer { lock.unlock() }
        if let peak = peakSinceTick {
            last = peak
            emptyTicks = 0
        } else {
            emptyTicks += 1
            if emptyTicks > 1 { last *= Self.decay }
        }
        peakSinceTick = nil
        return last
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        peakSinceTick = nil
        last = 0
        emptyTicks = 0
    }
}
