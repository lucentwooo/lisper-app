import Testing
@testable import LisperKit

@Suite struct WavEncoderTests {

    @Test func testHeaderAndSize() {
        let audio = CapturedAudio(samples: [0, 0.5, -0.5, 1.0, -1.0])
        let data = WavEncoder.encode(audio)
        #expect(data.count == 44 + 5 * 2) // header + 16-bit samples
        #expect(String(data: data[0..<4], encoding: .ascii) == "RIFF")
        #expect(String(data: data[8..<12], encoding: .ascii) == "WAVE")
        // sample rate little-endian at offset 24
        let rate = data[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(rate == 16_000)
    }

    @Test func testClipping() {
        let audio = CapturedAudio(samples: [2.0, -2.0])
        let data = WavEncoder.encode(audio)
        let s0 = data[44..<46].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
        let s1 = data[46..<48].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
        #expect(s0 == Int16.max)
        #expect(s1 == Int16.min)
    }

    @Test func testEncodeDecodeRoundTrip() {
        let samples: [Float] = [0, 0.5, -0.5, 0.25, -0.25]
        let wav = WavEncoder.encode(CapturedAudio(samples: samples))
        let back = WavEncoder.decodeToSamples(wav)
        #expect(back.count == samples.count)
        for (a, b) in zip(samples, back) { #expect(abs(a - b) < 0.001) }
    }
}
