import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.isAuthenticated {
                MainTabView()
            } else {
                AuthView()
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Main Tab View

struct MainTabView: View {
    @State private var selectedTab: AppTab = .chats
    @State private var showTabBar = true

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.appBg.ignoresSafeArea()

            Group {
                switch selectedTab {
                case .chats:   ChatListView(showTabBar: $showTabBar)
                case .profile: ProfileView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showTabBar {
                GlassTabBar(selected: $selectedTab)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showTabBar)
    }
}

// MARK: - Tab Definition

enum AppTab: String, CaseIterable {
    case chats   = "chats"
    case profile = "profile"

    var icon: String {
        switch self {
        case .chats:   return "message"
        case .profile: return "person"
        }
    }

    var label: String {
        switch self {
        case .chats:   return "Чаты"
        case .profile: return "Профиль"
        }
    }
}

// MARK: - Glass Tab Bar

struct GlassTabBar: View {
    @Binding var selected: AppTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                TabBarItem(tab: tab, isActive: selected == tab)
                    .onTapGesture {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) {
                            selected = tab
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background {
            // Outer glass pill
            Capsule()
                .fill(Color.glassSurface.opacity(0.52))
                .overlay {
                    // Top highlight line
                    Capsule()
                        .stroke(
                            LinearGradient(
                                colors: [.clear, .white.opacity(0.32), .white.opacity(0.22), .clear],
                                startPoint: .leading, endPoint: .trailing
                            ),
                            lineWidth: 0.5
                        )
                }
                .shadow(color: .black.opacity(0.4), radius: 24, x: 0, y: 8)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }
}

struct TabBarItem: View {
    let tab: AppTab
    let isActive: Bool

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: isActive ? "\(tab.icon).fill" : tab.icon)
                .font(.system(size: 22, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.white.opacity(0.95) : Color.white.opacity(0.3))
            Text(tab.label)
                .font(.system(size: 10, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.white.opacity(0.88) : Color.white.opacity(0.28))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.13))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.22), lineWidth: 0.5)
                    }
            }
        }
    }
}
