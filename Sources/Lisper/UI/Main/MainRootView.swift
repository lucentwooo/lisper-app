import SwiftUI
import LisperKit

struct MainRootView: View {
    @StateObject var model: MainViewModel

    var body: some View {
        ZStack {
            GlowBackground()
            if model.settings.onboardingComplete {
                HStack(spacing: 0) {
                    SidebarView(model: model)
                    Divider().overlay(Theme.hairline)
                    Group {
                        switch model.tab {
                        case .home: HomeView(model: model)
                        case .insights: InsightsView(model: model)
                        case .dictionary: DictionaryView(model: model)
                        case .settings: SettingsView(model: model)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                }
            } else {
                OnboardingView(model: model)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .preferredColorScheme(.dark)
    }
}
