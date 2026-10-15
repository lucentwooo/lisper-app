// Sources/Lisper/Audio/UISounds.swift
import AppKit
import LisperKit

/// Minimal, tactile UI cues — soft "taps" matched to Lisper's dark, cinematic
/// brand: a filtered soft transient (the tactile body) layered with a short
/// low tonal core, low-pass filtered dark, almost dry. Barely-there, felt more
/// than heard (spec 2026-06-13-style-modes-and-ui-sounds).
///
///   start  — one soft low tap with a faint tonal core.
///   lock   — two quick taps, the second a fifth up: "locked / confirmed".
///   cancel — one muted tap with a downward pitch drop: dismissed.
///
/// Rendered once at first use at 48 kHz as in-memory WAVs, peak-normalized
/// quiet, and played via NSSound at low volume. The voice is the "muted-darkest"
/// candidate chosen at audition: dark filter, softened click, long enough decay
/// to ring out rather than cut off. `--render-sounds` (see main.swift) re-renders
/// the three cues to WAVs for re-tuning by ear.
enum UISounds {
    private static let volume: Float = 0.6
    private static let rate = 48_000.0

    // Voice — the chosen "muted-darkest" tap.
    private static let baseFreq = 128.0   // start-cue tonal core; others derive from it
    private static let cutoff = 820.0     // dark one-pole low-pass (Hz)
    private static let noiseGain = 0.22   // soft tactile transient, mostly tone
    private static let roomMix = 0.03     // a whisper of early-reflection air

    static let start: NSSound? = wrap(renderStart())
    static let stop: NSSound? = wrap(renderStop())
    static let lock: NSSound? = wrap(renderLock())
    static let cancel: NSSound? = wrap(renderCancel())

    static func playStart() { play(start) }
    static func playStop() { play(stop) }
    static func playLock() { play(lock) }
    static func playCancel() { play(cancel) }

    private static func play(_ sound: NSSound?) {
        guard let sound else { return }
        sound.stop()          // restart cleanly if still tailing off
        sound.volume = volume
        sound.play()
    }

    // MARK: - Voice

    /// One soft tap: a sine "tonal core" + a filtered-noise transient, summed
    /// and low-passed dark. `freqEnd` (when set) glides the pitch for cancel.
    struct Tap {
        var freq: Double          // tonal-core fundamental (Hz)
        var freqEnd: Double?      // optional pitch-glide target
        var toneGain: Double
        var noiseGain: Double
        var toneDecay: Double     // 1/s (slower — the body)
        var noiseDecay: Double    // 1/s (faster — the click transient)
        var cutoff: Double        // overall one-pole low-pass (Hz)
        var attack: Double        // soft onset (s) — avoids a hard click
        var dur: Double           // seconds
    }

    /// The shared tap shape at a given tonal-core frequency. Softer onset and a
    /// gentle noise decay — muted, not clicky. `dur` is long enough for the
    /// tonal core to decay to silence before the buffer ends, so the cue rings
    /// out instead of cutting off abruptly.
    private static func tap(freq: Double) -> Tap {
        Tap(freq: freq, freqEnd: nil, toneGain: 0.62, noiseGain: noiseGain,
            toneDecay: 24, noiseDecay: 65, cutoff: cutoff, attack: 0.007, dur: 0.30)
    }

    // MARK: - The three cues

    private static func renderStart() -> [Float] {
        var buf = [Float](repeating: 0, count: Int(rate * 0.36))
        place(tap(freq: baseFreq), into: &buf, at: 0.0)
        return finished(room(buf, roomMix))
    }

    /// Deactivate cue — one soft tap a touch below the start pitch: the take has
    /// settled / closed. Distinct from cancel (no dark filter, no downward glide),
    /// so "stopped & transcribing" reads differently from "dismissed".
    private static func renderStop() -> [Float] {
        var buf = [Float](repeating: 0, count: Int(rate * 0.36))
        place(tap(freq: baseFreq * 0.84), into: &buf, at: 0.0)
        return finished(room(buf, roomMix))
    }

    private static func renderLock() -> [Float] {
        var buf = [Float](repeating: 0, count: Int(rate * 0.42))
        place(tap(freq: baseFreq * 1.18), into: &buf, at: 0.00, amp: 0.85)
        place(tap(freq: baseFreq * 1.50), into: &buf, at: 0.075)   // a fifth up — "confirmed"
        return finished(room(buf, roomMix))
    }

    private static func renderCancel() -> [Float] {
        // Darker + a downward pitch drop = dismissed.
        var t = tap(freq: baseFreq * 1.12)
        t.freqEnd = baseFreq * 0.75
        t.cutoff = cutoff * 0.8
        var buf = [Float](repeating: 0, count: Int(rate * 0.34))
        place(t, into: &buf, at: 0.0)
        return finished(room(buf, roomMix * 0.5))
    }

    // MARK: - DSP

    /// Reproducible white noise in [-1, 1] from a sample index (no RNG state, so
    /// every render is identical).
    private static func noise(_ i: Int) -> Double {
        var x = UInt64(bitPattern: Int64(i &+ 1)) &* 0x9E3779B97F4A7C15
        x ^= x >> 30; x &*= 0xBF58476D1CE4E5B9; x ^= x >> 27
        return Double(x % 4000) / 2000.0 - 1.0
    }

    /// Render one tap (tone + filtered-noise transient), low-passed dark.
    private static func renderTap(_ t: Tap) -> [Float] {
        let n = Int(rate * t.dur)
        var raw = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let time = Double(i) / rate
            let f = t.freqEnd.map { t.freq + ($0 - t.freq) * (time / t.dur) } ?? t.freq
            let attack = min(1.0, time / t.attack)
            let tone = sin(2 * .pi * f * time) * exp(-time * t.toneDecay) * t.toneGain
            let click = noise(i) * exp(-time * t.noiseDecay) * t.noiseGain
            raw[i] = (tone + click) * attack
        }
        // One-pole low-pass — softens the noise and removes brightness.
        let dt = 1.0 / rate
        let rc = 1.0 / (2 * .pi * t.cutoff)
        let a = dt / (rc + dt)
        var lp = 0.0
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { lp += a * (raw[i] - lp); out[i] = Float(lp) }
        return out
    }

    private static func place(_ t: Tap, into buf: inout [Float], at offset: Double, amp: Double = 1.0) {
        let s = renderTap(t)
        let start = Int(offset * rate)
        for i in 0..<s.count where start + i < buf.count {
            buf[start + i] += s[i] * Float(amp)
        }
    }

    /// A whisper of room: two quiet, short early reflections summed in. Minimal
    /// by design — tactile cues want air, not a tail.
    private static func room(_ dry: [Float], _ wet: Double) -> [Float] {
        guard wet > 0 else { return dry }
        let taps: [(delay: Double, gain: Float)] = [(0.013, 0.6), (0.027, 0.32)]
        var out = dry + [Float](repeating: 0, count: Int(rate * 0.05))
        for tap in taps {
            let d = Int(rate * tap.delay)
            for (i, v) in dry.enumerated() { out[i + d] += v * tap.gain * Float(wet) }
        }
        return out
    }

    /// Peak-normalize to ≈ −20 dBFS (quiet) and fade the last 30 ms to zero
    /// with a smooth (raised-cosine) ramp so the tail never ends on a step.
    private static func finished(_ samples: [Float]) -> [Float] {
        var out = samples
        let peak = out.map(abs).max() ?? 0
        if peak > 0 {
            let target: Float = 0.18   // ≈ −15 dBFS — quiet, but actually audible
            for i in 0..<out.count { out[i] *= target / peak }
        }
        let n = min(out.count, Int(rate * 0.030))
        for k in 0..<n {
            let p = Double(k + 1) / Double(n)
            out[out.count - n + k] *= Float(0.5 * (1 + cos(.pi * p)))   // 1 → 0, smooth
        }
        return out
    }

    private static func wrap(_ samples: [Float]) -> NSSound? {
        NSSound(data: WavEncoder.encode(CapturedAudio(samples: samples, sampleRate: rate)))
    }

    // MARK: - Audition

    /// Re-renders the three shipped cues as WAVs for tuning by ear
    /// (`Lisper --render-sounds [dir]`). Same synthesis code that ships.
    static func renderAuditionWAVs(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cues: [(String, [Float])] = [
            ("start", renderStart()),
            ("stop", renderStop()),
            ("lock", renderLock()),
            ("cancel", renderCancel()),
        ]
        for (name, samples) in cues {
            let data = WavEncoder.encode(CapturedAudio(samples: samples, sampleRate: rate))
            try data.write(to: dir.appendingPathComponent("\(name).wav"))
        }
    }
}
