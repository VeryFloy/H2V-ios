import SwiftUI

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    @Published var isAuthenticated = false
    @Published var isCheckingSession = true
    @Published var currentUser: User?
    @Published var onlineUserIds: Set<String> = []
    @Published var activeChatId: String?
    @Published var typingUsers: [String: Set<String>] = [:]

    init() {
        checkSession()
    }

    func checkSession() {
        isCheckingSession = true
        Task {
            do {
                let user = try await APIClient.shared.getMe()
                currentUser = user
                isAuthenticated = true
                WebSocketClient.shared.connect()
            } catch {
                isAuthenticated = false
            }
            isCheckingSession = false
        }
    }

    func signIn(user: User) {
        currentUser = user
        isAuthenticated = true
        WebSocketClient.shared.connect()
    }

    func signOut() {
        Task {
            try? await APIClient.shared.logout()
        }
        currentUser = nil
        isAuthenticated = false
        onlineUserIds = []
        activeChatId = nil
        typingUsers = [:]
        WebSocketClient.shared.disconnect()
        clearCookies()
        CacheManager.shared.clearAll()
        SecretChatSessionStore.shared.rotateSession()
    }

    private func clearCookies() {
        let storage = HTTPCookieStorage.shared
        if let cookies = storage.cookies(for: URL(string: Config.baseURL)!) {
            for cookie in cookies { storage.deleteCookie(cookie) }
        }
    }

    func handleWSEvent(_ event: WSEvent) {
        switch event.event {
        case "presence:snapshot":
            if let ids = event.payload["onlineUserIds"] as? [String] {
                onlineUserIds = Set(ids)
            }
        case "user:online":
            if let uid = event.userId { onlineUserIds.insert(uid) }
        case "user:offline":
            if let uid = event.userId { onlineUserIds.remove(uid) }
        case "typing:started":
            if let chatId = event.chatId, let uid = event.userId {
                typingUsers[chatId, default: []].insert(uid)
            }
        case "typing:stopped":
            if let chatId = event.chatId, let uid = event.userId {
                typingUsers[chatId]?.remove(uid)
            }
        case "user:updated":
            if let uid = event.userId, uid == currentUser?.id {
                if let name = event.payload["nickname"] as? String { currentUser?.nickname = name }
                if let avatar = event.payload["avatar"] as? String { currentUser?.avatar = avatar }
                if let bio = event.payload["bio"] as? String { currentUser?.bio = bio }
            }
        default: break
        }
    }

    func isUserOnline(_ userId: String) -> Bool {
        onlineUserIds.contains(userId)
    }

    func typingNicknames(chatId: String) -> [String] {
        guard let uids = typingUsers[chatId] else { return [] }
        return Array(uids.filter { $0 != currentUser?.id })
    }
}

// MARK: - App Entry

@main
struct h2v_iosApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
                .onAppear {
                    WebSocketClient.shared.onEvent = { [weak appState] event in
                        Task { @MainActor in
                            appState?.handleWSEvent(event)
                            NotificationManager.shared.handleMessage(event: event, appState: appState)
                        }
                    }
                    Task { await NotificationManager.shared.requestPermission() }
                }
        }
    }
}
