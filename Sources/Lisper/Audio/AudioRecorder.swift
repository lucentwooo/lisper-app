// Sources/Lisper/Audio/AudioRecorder.swift
import AVFoundation
import LisperKit

/// Captures mic audio while the hotkey is held: native format -> 16k mono Float32.
/// Emits RMS levels for the pill waveform. Audio lives only in memory.
///
/// Every take gets a FRESH `AVAudioEngine`. A reused engine caches its input node's format:
/// after the default input device changes while idle (AirPods connecting at 16 kHz, a 44.1 kHz
/// USB mic), `inputNode.outputFormat` still reports the OLD device's rate, and `installTap`
/// with it raises an Objective-C exception ("Failed to create tap due to format mismatch").
/// Swift can't catch that — AppKit swallowed it mid-`beginRecording`, leaving the Space/Esc
/// tap armed with no take behind it: Space dead, hotkey dead, until relaunch. See
/// DEBUGGING-LOG 2026-10-10.
final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var samples: [Float] = []
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private(set) var isRecording = false
    /// The take has ended but the mic is still open for its stop tail (see `stop(keepingTail:)`).
    private var isFinishing = false
    var onLevel: ((Float) -> Void)?          // RMS 0...1, called on audio thread
    var maxDuration: TimeInterval = 600      // 10-minute cap — keeps the WAV (~32 KB/s) under Groq's 25 MB upload limit
    var onAutoStop: (() -> Void)?            // fired when cap hit (main thread)

    func start() throws {
        guard !isRecording, !isFinishing else { return }
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
        try startEngine()
        isRecording = true
    }

    /// Ends the take at once (`isRecording` is false from here on) but keeps the mic open for
    /// `tail` seconds more, then hands over everything captured plus how long the take was held
    /// (the pipeline judges "too short" on that, not the tail), on the main queue. The stop press
    /// usually lands on the last syllable, and tearing the engine down at once also threw away the
    /// tap buffer already in flight (~100 ms): 80 of 389 saved takes still had speech in their
    /// final 50 ms, and some lost a word that way ("…a list of several", session 3440).
    func stop(keepingTail tail: TimeInterval,
              completion: @escaping (_ audio: CapturedAudio, _ heldSeconds: Double) -> Void) {
        guard isRecording else {
            completion(CapturedAudio(samples: [], sampleRate: targetFormat.sampleRate), 0)
            return
        }
        isRecording = false
        isFinishing = true
        lock.lock()
        let heldSeconds = Double(samples.count) / targetFormat.sampleRate
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + tail) { [weak self] in
            guard let self else { return }
            self.stopEngine()
            self.isFinishing = false
            self.lock.lock()
            let audio = CapturedAudio(samples: self.samples, sampleRate: self.targetFormat.sampleRate)
            self.lock.unlock()
            completion(audio, heldSeconds)
        }
    }

    /// Stops at once and returns everything captured — for a discarded take (Esc, abort).
    func stop() -> CapturedAudio {
        guard isRecording else { return CapturedAudio(samples: [], sampleRate: targetFormat.sampleRate) }
        stopEngine()
        isRecording = false
        lock.lock(); defer { lock.unlock() }
        return CapturedAudio(samples: samples, sampleRate: targetFormat.sampleRate)
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw EngineError.unavailable("no input device")
        }
        // One converter per engine: its resampler state belongs to this device's format.
        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        // Ask for ~30 ms buffers. macOS floors a mic tap at ~100 ms, but without the request
        // a 4096-frame buffer is 256 ms on 16 kHz Bluetooth headphones — the waveform then
        // reacted a quarter-second late. Capture itself is unaffected by the buffer size.
        let bufferFrames = AVAudioFrameCount(max(256, inputFormat.sampleRate * 0.03))
        input.installTap(onBus: 0, bufferSize: bufferFrames, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer: buffer, converter: converter)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        // queue: nil + an async hop, NOT queue: .main. With .main, posting blocks AVAudioEngine's
        // internal queue until our block finishes — and the block tears that very engine down
        // (Apple: never deallocate the engine from within this handler; deadlock risk). The hop
        // returns immediately; the restart runs afterwards on main, only if this engine is
        // still the live one.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self, weak engine] _ in
            DispatchQueue.main.async {
                guard let self, let engine, self.engine === engine else { return }
                self.handleConfigurationChange()
            }
        }
    }

    private func stopEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    /// The input device changed mid-take (AirPods connected, a mic unplugged). AVAudioEngine
    /// stops itself and the tap goes quiet, so the take used to end silently at the switch.
    /// Re-open capture on the new device and keep appending to the same take.
    private func handleConfigurationChange() {
        guard isRecording, engine?.isRunning == false else { return }
        stopEngine()
        do {
            try startEngine()
        } catch {
            // The new device often isn't ready the instant it appears (a Bluetooth headset is
            // still negotiating). Retry once; if it still can't open, keep what was captured —
            // the user's stop press finishes the take with it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.isRecording, self.engine == nil else { return }
                try? self.startEngine()
            }
        }
    }

    private func consume(buffer: AVAudioPCMBuffer, converter: AVAudioConverter?) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard let ch = out.floatChannelData, out.frameLength > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))

        var rms: Float = 0
        for s in chunk { rms += s * s }
        rms = sqrt(rms / Float(max(chunk.count, 1)))
        onLevel?(min(1, rms * 8)) // perceptual boost for the waveform

        lock.lock()
        samples.append(contentsOf: chunk)
        let hitCap = Double(samples.count) / targetFormat.sampleRate >= maxDuration
        lock.unlock()
        if hitCap { DispatchQueue.main.async { [weak self] in self?.onAutoStop?() } }
    }
}
