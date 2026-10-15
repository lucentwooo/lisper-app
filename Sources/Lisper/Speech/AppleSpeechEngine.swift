import Foundation
import Speech
import AVFoundation
import LisperKit

/// Free/offline fallback using Apple's on-device recognizer.
/// Audio is chunked to ≤50s because SFSpeechRecognizer stops tasks over ~1 minute,
/// and every chunk races a timeout so a dropped callback can never hang the pipeline.
struct AppleSpeechEngine: TranscriptionEngine {
    let name = "apple"
    private static let chunkSeconds = 50.0

    func transcribe(audio: CapturedAudio, dictionaryTerms: [String]) async throws -> String {
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else { throw EngineError.unavailable("speech recognition not authorized") }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw EngineError.unavailable("apple recognizer unavailable")
        }

        let chunkFrames = Int(Self.chunkSeconds * audio.sampleRate)
        guard chunkFrames > 0, !audio.samples.isEmpty else { throw EngineError.emptyTranscript }

        var pieces: [String] = []
        var lastError: String?
        var start = 0
        while start < audio.samples.count {
            let end = min(start + chunkFrames, audio.samples.count)
            do {
                let text = try await recognizeChunk(Array(audio.samples[start..<end]),
                                                    sampleRate: audio.sampleRate,
                                                    recognizer: recognizer,
                                                    dictionaryTerms: dictionaryTerms)
                if !text.isEmpty { pieces.append(text) }
            } catch {
                // A silent chunk can error ("no speech detected") without sinking the whole
                // dictation; only fail if nothing at all was recognized.
                lastError = "\(error)"
            }
            start = end
        }

        let joined = pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else {
            if let lastError { throw EngineError.unavailable(lastError) }
            throw EngineError.emptyTranscript
        }
        return joined
    }

    private func recognizeChunk(_ samples: [Float], sampleRate: Double,
                                recognizer: SFSpeechRecognizer,
                                dictionaryTerms: [String]) async throws -> String {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        if !dictionaryTerms.isEmpty { request.contextualStrings = dictionaryTerms }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: 1, interleaved: false)!
        guard !samples.isEmpty else { throw EngineError.emptyTranscript }
        // Feed the audio incrementally in ~2s sub-buffers rather than dumping the whole
        // chunk in one append. SFSpeechAudioBufferRecognitionRequest is a streaming API;
        // handing it one huge buffer then immediately calling endAudio() makes the
        // recognizer finalize before it has consumed the lead-in, which is what ate the
        // first chunk of long takes (the "missing start" reports). Paced appends let it
        // process the whole span.
        let subFrames = max(1, Int(2.0 * sampleRate))
        var off = 0
        while off < samples.count {
            let end = min(off + subFrames, samples.count)
            let slice = Array(samples[off..<end])
            let n = AVAudioFrameCount(slice.count)
            guard n > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { break }
            buffer.frameLength = n
            slice.withUnsafeBufferPointer { src in
                buffer.floatChannelData![0].update(from: src.baseAddress!, count: slice.count)
            }
            request.append(buffer)
            off = end
        }
        request.endAudio()

        // Single-resume guard shared by the recognition callback and the timeout.
        final class ResumeState: @unchecked Sendable {
            let lock = NSLock()
            var finished = false
            var task: SFSpeechRecognitionTask?
        }
        let state = ResumeState()
        let timeout = Double(samples.count) / sampleRate + 10

        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            func finish(_ result: Result<String, Error>) {
                state.lock.lock()
                let alreadyDone = state.finished
                state.finished = true
                state.lock.unlock()
                guard !alreadyDone else { return }
                state.task?.cancel()
                switch result {
                case .success(let s): c.resume(returning: s)
                case .failure(let e): c.resume(throwing: e)
                }
            }

            state.task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    finish(.failure(EngineError.unavailable(error.localizedDescription)))
                } else if let result, result.isFinal {
                    finish(.success(result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(.failure(EngineError.unavailable("apple recognition timed out")))
            }
        }
    }
}
