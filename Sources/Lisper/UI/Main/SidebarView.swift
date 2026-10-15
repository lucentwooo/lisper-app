import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                OrbMark(size: 20)
                Text("Lisper").font(.system(size: 16, weight: .semibold)).kerning(-0.2)
                    .foregroundColor(Theme.textPrimary)
            }
            .padding(.bottom, 24).padding(.top, 36).padding(.leading, 10)

            ForEach(MainTab.allCases) { tab in
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { model.tab = tab }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tab.icon).frame(width: 18)
                        Text(tab.rawValue).font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .foregroundColor(model.tab == tab ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(model.tab == tab ? Color.white.opacity(0.07) : .clear))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(width: 180)
    }
}
