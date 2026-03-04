import SwiftUI

struct FloatingTabBar: View {
    @Binding var selectedTab: Int

    private let items: [(icon: String, label: String)] = [
        ("iphone",     "Simulator"),
        ("brain",      "Session"),
        ("hammer",     "Build"),
        ("gearshape",  "Settings"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<items.count, id: \.self) { i in
                tabButton(index: i)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func tabButton(index i: Int) -> some View {
        let selected = selectedTab == i
        Button {
            withAnimation(.spring(duration: 0.25)) { selectedTab = i }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: items[i].icon)
                    .font(.system(size: 17, weight: selected ? .semibold : .regular))
                Text(items[i].label)
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? .white : .white.opacity(0.45))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background {
                if selected {
                    Capsule().fill(.white.opacity(0.18))
                }
            }
            .padding(.horizontal, 3)
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.25), value: selected)
    }
}
