import SwiftUI
import CoreGraphics

/// One-time generated film-grain tile. Carries its own alpha so it reads on ANY
/// surface — a gray tile on `.overlay` blend mathematically vanishes on near-black,
/// which is why the old grain never looked grainy. Specks are full-range gray at
/// low random alpha, drawn with normal blending.
enum NoiseTexture {
    static let shared: NSImage = generate(size: 256)

    private static func generate(size: Int) -> NSImage {
        var rng = SystemRandomNumberGenerator()
        var pixels = [UInt8](repeating: 0, count: size * size * 2) // gray + alpha
        for i in stride(from: 0, to: pixels.count, by: 2) {
            pixels[i] = UInt8.random(in: 0...255, using: &rng)     // speck brightness
            pixels[i + 1] = UInt8.random(in: 0...56, using: &rng)  // sparse, matte alpha
        }
        let data = CFDataCreate(nil, pixels, pixels.count)!
        let provider = CGDataProvider(data: data)!
        let cg = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 16,
                         bytesPerRow: size * 2, space: CGColorSpaceCreateDeviceGray(),
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false,
                         intent: .defaultIntent)!
        return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
    }
}

struct GrainOverlay: View {
    var opacity: Double = Theme.grain
    var body: some View {
        Image(nsImage: NoiseTexture.shared)
            .resizable(resizingMode: .tile)
            .opacity(opacity)
            .allowsHitTesting(false)
    }
}
