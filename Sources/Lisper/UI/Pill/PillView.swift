import SwiftUI

enum PillPhase: Equatable {
    case hidden, listening, processing, success, error(String)
}

final class PillModel: ObservableObject {
    @Published var phase: PillPhase = .hidden
    @Published var levels: [Float] = Array(repeating: 0.05, count: 14)
    @Published var locked = false
    @Published var processingText: String = "Polishing…"

    func push(level: Float) {
        levels.removeFirst()
        levels.append(max(0.05, level))
    }
}

struct PillView: View {
    @ObservedObject var model: PillModel

    var body: some View {
        HStack(spacing: 6) {
            switch model.phase {
            case .listening:
                if model.locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9)).foregroundColor(Theme.glowCore)
                }
                waveform
            case .processing:
                ProgressView().controlSize(.mini).tint(Theme.glowCore)
                Text(model.processingText).font(.system(size: 10, weight: .medium)).foregroundColor(Theme.textSecondary)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11)).foregroundColor(Theme.glowCore)
            case .error(let msg):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundColor(Theme.destructive)
                Text(msg).font(.system(size: 10, weight: .medium)).foregroundColor(Theme.textSecondary)
                    .lineLimit(1).frame(maxWidth: 200)
            case .hidden:
                EmptyView()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            Capsule().fill(Color.black.opacity(0.82))
                .overlay(Capsule().fill(
                    RadialGradient(colors: [Theme.glowDeep.opacity(model.phase == .listening ? 0.5 : 0.25), .clear],
                                   center: .bottomLeading, startRadius: 0, endRadius: 70)))
                .overlay(GrainOverlay(opacity: Theme.grainStrong).clipShape(Capsule()))
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                .shadow(color: Theme.glowDeep.opacity(0.3), radius: 10, y: 3)
        )
        .animation(.easeOut(duration: 0.25), value: model.phase)
    }

    private var waveform: some View {
        HStack(spacing: 2) {
            ForEach(Array(model.levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(LinearGradient(colors: [Theme.glowCore, Theme.glowDeep],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 2, height: 2.5 + CGFloat(level) * 9)
                    .animation(.spring(response: 0.18, dampingFraction: 0.7), value: level)
            }
        }
        .frame(height: 12)
    }
}
