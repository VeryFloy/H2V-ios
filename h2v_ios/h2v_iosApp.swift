import SwiftUI

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    @Published var isAuthenticated = false
    @Published var currentUser: User?
    @Published var onlineUserIds: Set<String> = []
    /// ID чата, который сейчас открыт — чтобы не слать уведомление из него
    @Published var activeChatId: String? = nil

    init() {
        if TokenStorage.shared.accessToken != nil {
            isAuthenticated = true
            Task { await refreshUser() }
        }
    }

    func refreshUser() async {
        do {
            let user = try await APIClient.shared.getMe()
            currentUser = user
            if let token = TokenStorage.shared.accessToken {
                WebSocketClient.shared.connect(token: token)
            }
        } catch NetworkError.unauthorized {
            signOut()
        } catch {}
    }

    func signIn(user: User, tokens: Tokens) {
        TokenStorage.shared.save(tokens: tokens)
        currentUser = user
        isAuthenticated = true
        WebSocketClient.shared.connect(token: tokens.accessToken)
    }

    func signOut() {
        if let rt = TokenStorage.shared.refreshToken {
            Task { await APIClient.shared.logout(refreshToken: rt) }
        }
        TokenStorage.shared.clear()
        currentUser = nil
        isAuthenticated = false
        onlineUserIds = []
        activeChatId = nil
        WebSocketClient.shared.disconnect()
    }

    func handlePresence(event: WSEvent) {
        switch event.type {
        case "presence:snapshot":
            if let ids = event.rawPayload["onlineUserIds"] as? [String] {
                onlineUserIds = Set(ids)
            }
        case "user:online":
            if let uid = event.userId { onlineUserIds.insert(uid) }
        case "user:offline":
            if let uid = event.userId { onlineUserIds.remove(uid) }
        default: break
        }
    }

    /// Проверяет новое WS-сообщение и отправляет локальное уведомление
    func handleMessageNotification(event: WSEvent) {
        guard event.type == "message:new" || event.type == "new_message" else { return }
        guard let msg = event.decodeMessage() else { return }
        guard msg.sender.id != currentUser?.id else { return }  // не от себя
        let cid = msg.chatId ?? event.chatId ?? ""
        guard cid != activeChatId else { return }                // не в активном чате

        let text = msg.text ?? (msg.messageType == .image ? "📷 Фото" : "Новое сообщение")
        NotificationManager.shared.notifyNewMessage(
            senderName: msg.sender.nickname,
            text: text,
            chatId: cid
        )
    }
}

// MARK: - App Entry Point

@main
struct h2v_iosApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var notifManager = NotificationManager.shared

    @AppStorage("h2v.colorScheme") private var colorScheme = "dark"

    private var preferredScheme: ColorScheme? {
        switch colorScheme {
        case "light":  return .light
        case "system": return nil
        default:       return .dark
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(preferredScheme)
                .onAppear {
                    NotificationManager.shared.clearBadge()
                    WebSocketClient.shared.onEvent = { [weak appState] event in
                        Task { @MainActor in
                            appState?.handlePresence(event: event)
                            appState?.handleMessageNotification(event: event)
                        }
                    }
                    Task { await notifManager.requestPermission() }
                }
                .onChange(of: appState.isAuthenticated) { _, authenticated in
                    if authenticated { NotificationManager.shared.clearBadge() }
                }
        }
    }
}
