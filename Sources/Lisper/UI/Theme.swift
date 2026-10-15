import SwiftUI

/// Design tokens — "cinematic Apple" v2 (design-system handoff 2026-06-13).
/// A single confident blue light source blooming low-center on near-black,
/// heavy film grain on every frame, poster-weight mastheads against light
/// stat numerals. Dark-only.
enum Theme {
    // Canvas
    static let canvas = Color(hex: 0x04060B)
    static let canvas2 = Color(hex: 0x060912)
    static let panel = Color(hex: 0x0A0E16)
    // The blue light source (sunset-blue ramp)
    static let glowBright = Color(hex: 0x9CC6FF)   // specular highlight / orb hot-spot
    static let glowCore = Color(hex: 0x5AA0FF)     // the bloom core
    static let glowMid = Color(hex: 0x2E72E6)
    static let glowDeep = Color(hex: 0x1E5FD0)
    static let glowTeal = Color(hex: 0x14618F)     // cool deep "ocean" edge (legacy name kept)
    static let glowAbyss = Color(hex: 0x0A1E3F)    // where the bloom meets black
    // Accents
    static let accent = Color(hex: 0x2E7BFF)
    static let accentBright = Color(hex: 0x5AA0FF)
    static let success = Color(hex: 0x34D399)
    static let destructive = Color(hex: 0xFF5247)
    // Text
    static let textPrimary = Color(hex: 0xF4F7FB)
    static let textSecondary = Color(hex: 0xE9F0FA).opacity(0.58)
    static let textTertiary = Color(hex: 0xE9F0FA).opacity(0.34)
    static let textFaint = Color(hex: 0xE9F0FA).opacity(0.20)
    // Hairlines & radii
    static let hairline = Color.white.opacity(0.07)
    static let hairlineStrong = Color.white.opacity(0.13)
    static let hairlineTop = Color.white.opacity(0.12)  // brighter top edge catching the glow
    static let cardRadius: CGFloat = 20
    // Grain — a feature, not a whisper
    static let grain: Double = 0.5         // every frame
    static let grainStrong: Double = 0.7   // buttons, pill, hero moments

    /// Light (300) stat numerals — tight tracking, tabular.
    static func statNumeral(_ size: CGFloat = 56) -> Font {
        .system(size: size, weight: .light, design: .default)
    }
    /// Heavy (800) page masthead — cinematic poster type.
    static func masthead(_ size: CGFloat = 38) -> Font {
        .system(size: size, weight: .heavy)
    }
    /// Black (900) hero masthead.
    static func mastheadBlack(_ size: CGFloat = 56) -> Font {
        .system(size: size, weight: .black)
    }
    static var label: Font { .system(size: 11, weight: .medium) }
    static var eyebrowFont: Font { .system(size: 11, weight: .bold) }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

extension View {
    /// Uppercase tracked section label (spec §8 typography).
    func sectionLabel() -> some View {
        font(Theme.label).foregroundColor(Theme.textSecondary)
            .textCase(.uppercase).kerning(1.6)
    }

    /// Tiny accent-blue uppercase eyebrow above a masthead.
    func eyebrow() -> some View {
        font(Theme.eyebrowFont).foregroundColor(Theme.accent)
            .textCase(.uppercase).kerning(2.4)
    }
}

/// The brand mark: a grainy blue gradient orb — a soft sphere lit from the
/// upper-left, reading as an ambient light source. Deliberately not a waveform.
struct OrbMark: View {
    var size: CGFloat = 20
    var glow: Bool = true

    var body: some View {
        Circle()
            .fill(RadialGradient(
                colors: [Theme.glowBright, Theme.glowCore, Theme.glowDeep, Theme.glowAbyss],
                center: UnitPoint(x: 0.34, y: 0.30),
                startRadius: 0, endRadius: size * 0.72))
            .overlay(GrainOverlay(opacity: Theme.grain).clipShape(Circle()))
            .shadow(color: glow ? Theme.accent.opacity(0.55) : .clear, radius: size * 0.7)
            .frame(width: size, height: size)
    }
}
