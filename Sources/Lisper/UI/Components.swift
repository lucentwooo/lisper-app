import SwiftUI

/// Barely-there frosted surface — almost transparent so the cinematic canvas
/// reads straight through; a brighter top hairline and baked grain do the work.
/// Reserve for ONE elevated moment per screen; repeated content is a
/// hairline-divided list, never a stack of cards.
struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(22)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Color.white.opacity(0.028))
                    .background(.ultraThinMaterial.opacity(0.5),
                                in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    .overlay(GrainOverlay().clipShape(
                        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                        .strokeBorder(LinearGradient(
                            colors: [Theme.hairlineTop, Theme.hairline],
                            startPoint: .top, endPoint: .bottom), lineWidth: 1))
                    .shadow(color: .black.opacity(0.55), radius: 35, y: 12)
            )
    }
}

/// Page header: tiny accent eyebrow over a heavy poster masthead and a quiet subtitle.
struct Masthead: View {
    let eyebrow: String
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow).eyebrow()
            Text(title).font(Theme.masthead()).kerning(-1.6).foregroundColor(Theme.textPrimary)
            if let subtitle {
                Text(subtitle).font(.system(size: 13)).foregroundColor(Theme.textSecondary)
            }
        }
    }
}

/// Native-style settings section: label + description on the left, controls on
/// the right, divided from the previous section by a hairline. No card.
struct HairlineSection<Content: View>: View {
    let label: String
    var desc: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(Theme.hairline)
            HStack(alignment: .top, spacing: 40) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(label).sectionLabel()
                    if let desc {
                        Text(desc).font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: 200, alignment: .leading)
                VStack(alignment: .leading, spacing: 16) { content }
                    .frame(maxWidth: 460, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.top, 24)
        }
    }
}

/// Big light-weight stat numeral with a label underneath.
struct StatBlock: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(Theme.statNumeral())
                .foregroundColor(Theme.textPrimary)
                .kerning(-1)
                .monospacedDigit()
            Text(label).sectionLabel()
        }
    }
}

/// Accent: a grainy deep-blue capsule with the glow rising from the bottom —
/// the same light as the canvas — and a blue bloom shadow. Press dims, never scales.
struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.white)
            .shadow(color: Theme.glowAbyss.opacity(0.5), radius: 1, y: 1)
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(
                ZStack {
                    RadialGradient(
                        colors: [Theme.glowCore, Theme.glowMid, Theme.glowDeep, Color(hex: 0x123A86)],
                        center: UnitPoint(x: 0.5, y: 1.3),
                        startRadius: 0, endRadius: 130)
                    GrainOverlay(opacity: Theme.grainStrong * 0.8)
                }
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1))
                .overlay(Capsule().trim(from: 0, to: 0.5)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
                    .blur(radius: 0.4))
            )
            .shadow(color: Theme.accent.opacity(0.45), radius: 11, y: 4)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Ghost: a near-black grainy capsule with a hairline (like "Skip").
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Theme.textPrimary)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(
                ZStack {
                    RadialGradient(
                        colors: [Theme.accent.opacity(0.16), Theme.panel.opacity(0.9)],
                        center: UnitPoint(x: 0.5, y: 1.3),
                        startRadius: 0, endRadius: 110)
                    GrainOverlay(opacity: Theme.grainStrong * 0.57)
                }
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Quiet: text-only, for tertiary actions.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(Theme.textSecondary)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
