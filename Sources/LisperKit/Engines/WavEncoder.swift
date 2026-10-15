import Foundation

/// Encodes mono Float32 PCM as 16-bit PCM WAV (what the Groq endpoint expects).
public enum WavEncoder {
    public static func encode(_ audio: CapturedAudio) -> Data {
        let sampleRate = UInt32(audio.sampleRate)
        let numSamples = audio.samples.count
        let dataSize = UInt32(numSamples * 2)
        var d = Data(capacity: 44 + numSamples * 2)

        func append(_ s: String) { d.append(contentsOf: s.utf8) }
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

        append("RIFF"); append32(36 + dataSize); append("WAVE")
        append("fmt "); append32(16); append16(1) /*PCM*/; append16(1) /*mono*/
        append32(sampleRate); append32(sampleRate * 2) /*byte rate*/
        append16(2) /*block align*/; append16(16) /*bits*/
        append("data"); append32(dataSize)

        for sample in audio.samples {
            let safe = sample.isNaN ? 0 : sample
            let scaled = safe * 32768
            let value = Int16(max(Float(Int16.min), min(Float(Int16.max), scaled)))
            withUnsafeBytes(of: value.littleEndian) { d.append(contentsOf: $0) }
        }
        return d
    }

    /// Decodes WAV data produced by `encode(_:)` back to Float samples.
    /// Assumes the canonical 44-byte PCM WAV header written by `encode`, with
    /// little-endian Int16 mono samples scaled by 32 768.
    public static func decodeToSamples(_ wav: Data) -> [Float] {
        guard wav.count > 44 else { return [] }
        let body = wav.subdata(in: 44..<wav.count)
        var out = [Float](); out.reserveCapacity(body.count / 2)
        body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let count = raw.count / 2
            for i in 0..<count {
                let lo = UInt16(raw[i * 2]); let hi = UInt16(raw[i * 2 + 1])
                let s = Int16(bitPattern: lo | (hi << 8))
                out.append(Float(s) / 32_768.0)
            }
        }
        return out
    }
}
