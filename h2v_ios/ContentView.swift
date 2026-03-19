import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: AppTab = .chats

    private var inChat: Bool { appState.activeChatId != nil }

    var body: some View {
        Group {
            if appState.isCheckingSession {
                splashScreen
            } else if appState.isAuthenticated {
                TabView(selection: $selectedTab) {
                    ChatListView()
                        .tag(AppTab.chats)
                        .tabItem {
                            Image(systemName: "message.fill")
                            Text("Чаты")
                        }

                    NavigationStack {
                        ProfileView()
                    }
                    .tag(AppTab.profile)
                    .tabItem {
                        Image(systemName: "person.fill")
                        Text("Профиль")
                    }
                }
                .tint(Color.h2vAccent)
                .toolbar(inChat ? .hidden : .visible, for: .tabBar)
                .animation(.none, value: inChat)
            } else {
                AuthView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.isAuthenticated)
        .animation(.easeInOut(duration: 0.2), value: appState.isCheckingSession)
    }

    private var splashScreen: some View {
        ZStack {
            Color.bgApp.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("H2V")
                    .font(.system(size: 40, weight: .black, design: .rounded))
                    .foregroundStyle(LinearGradient.accentGradient)
                ProgressView()
                    .tint(.h2vAccent)
                    .scaleEffect(1.1)
            }
        }
    }
}

enum AppTab {
    case chats, profile
}
