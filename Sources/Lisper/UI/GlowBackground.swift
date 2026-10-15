import SwiftUI

/// The cinematic canvas: near-black with a single confident blue bloom rising
/// from low-center (the reference grainy sunset, in blue) and two soft organic
/// blobs for mesh depth. Heavy film grain over everything. Slow drift.
struct GlowBackground: View {
    @State private var drift = false

    var body: some View {
        ZStack {
            Theme.canvas
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    // The bloom — low-center, the light source of the brand
                    RadialGradient(
                        colors: [Theme.glowCore.opacity(0.85), Theme.glowMid.opacity(0.55),
                                 Theme.glowDeep.opacity(0.35), Theme.glowAbyss.opacity(0.4), .clear],
                        center: .center, startRadius: 0, endRadius: max(w, h) * 0.78)
                        .frame(width: w * 1.7, height: h * 1.7)
                        .position(x: drift ? w * 0.52 : w * 0.46, y: drift ? h * 1.02 : h * 1.12)
                        .blur(radius: 60)
                    // Organic blob, lower-left
                    RadialGradient(colors: [Theme.glowMid.opacity(0.30), .clear],
                                   center: .center, startRadius: 0, endRadius: max(w, h) * 0.45)
                        .frame(width: w, height: h)
                        .position(x: drift ? w * 0.12 : w * 0.05, y: h * 1.05)
                        .blur(radius: 70)
                    // Cool ocean edge, lower-right
                    RadialGradient(colors: [Theme.glowTeal.opacity(0.30), .clear],
                                   center: .center, startRadius: 0, endRadius: max(w, h) * 0.5)
                        .frame(width: w, height: h)
                        .position(x: drift ? w * 0.92 : w * 0.82, y: h * 1.12)
                        .blur(radius: 80)
                }
                .animation(.easeInOut(duration: 32).repeatForever(autoreverses: true), value: drift)
            }
            GrainOverlay()
        }
        .ignoresSafeArea()
        .onAppear { drift = true }
    }
}
