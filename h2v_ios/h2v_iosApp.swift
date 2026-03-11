import SwiftUI
import UIKit

// MARK: - AppDelegate (APNs bridge)

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            NotificationManager.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            NotificationManager.shared.didFailToRegisterForRemoteNotifications(error: error)
        }
    }

    /// Handle silent remote push (content-available:1) to wake the app in background
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        completionHandler(.newData)
    }
}

// MARK: - Message Cache

/// Simple write-through cache: stores last N messages per chat in UserDefaults
/// so ChatView can show them instantly before the network request completes.
final class MessageCache {
    static let shared = MessageCache()
    private let maxPerChat = 50

    func save(_ messages: [Message], for chatId: String) {
        guard let data = try? JSONEncoder().encode(messages.suffix(maxPerChat)) else { return }
        UserDefaults.standard.set(data, forKey: "h2v.msgcache.\(chatId)")
    }

    func load(for chatId: String) -> [Message] {
        guard let data = UserDefaults.standard.data(forKey: "h2v.msgcache.\(chatId)"),
              let msgs = try? JSONDecoder().decode([Message].self, from: data) else { return [] }
        return msgs
    }

    func clear(for chatId: String) {
        UserDefaults.standard.removeObject(forKey: "h2v.msgcache.\(chatId)")
    }
}

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    @Published var isAuthenticated = false
    @Published var currentUser: User?
    @Published var onlineUserIds: Set<String> = []
    /// ID чата, который сейчас открыт — чтобы не слать уведомление из него
    @Published var activeChatId: String? = nil
    /// ID чата, к которому нужно перейти после тапа по уведомлению
    @Published var pendingOpenChatId: String? = nil

    private var wsSubscriberID: UUID?

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
                startListening()
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
        startListening()
    }

    func signOut() {
        stopListening()
        // Unregister device token from server before signing out
        if let rt = TokenStorage.shared.refreshToken {
            Task { await APIClient.shared.logout(refreshToken: rt) }
        }
        if let token = NotificationManager.shared.apnsToken {
            Task { try? await APIClient.shared.unregisterDeviceToken(token) }
        }
        TokenStorage.shared.clear()
        currentUser = nil
        isAuthenticated = false
        onlineUserIds = []
        activeChatId = nil
        pendingOpenChatId = nil
        WebSocketClient.shared.disconnect()
    }

    // MARK: - WS Subscription

    func startListening() {
        guard wsSubscriberID == nil else { return }
        wsSubscriberID = WebSocketClient.shared.subscribe { [weak self] event in
            self?.handlePresence(event: event)
            self?.handleMessageNotification(event: event)
        }
    }

    func stopListening() {
        if let id = wsSubscriberID {
            WebSocketClient.shared.unsubscribe(id)
            wsSubscriberID = nil
        }
    }

    // MARK: - Event Handlers

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
        case "user:updated":
            if let uid = event.userId, uid == currentUser?.id {
                if let nick = event.rawPayload["nickname"] as? String {
                    currentUser = User(
                        id: currentUser!.id,
                        nickname: nick,
                        avatar: event.rawPayload["avatar"] as? String ?? currentUser?.avatar,
                        bio: event.rawPayload["bio"] as? String ?? currentUser?.bio,
                        lastOnline: currentUser?.lastOnline,
                        isOnline: currentUser?.isOnline
                    )
                }
            }
        default: break
        }
    }

    /// Delivers a local notification for new incoming messages
    func handleMessageNotification(event: WSEvent) {
        guard event.type == "message:new" || event.type == "new_message" else { return }
        guard let msg = event.decodeMessage() else { return }
        guard msg.sender.id != currentUser?.id else { return }
        let cid = msg.chatId ?? event.chatId ?? ""
        guard cid != activeChatId else { return }

        let text = msg.text ?? (msg.messageType == .image ? "📷 Фото"
                                : msg.messageType == .audio ? "🎵 Голосовое"
                                : msg.messageType == .video ? "🎬 Видео"
                                : msg.messageType == .file  ? "📎 Файл"
                                : "Новое сообщение")

        NotificationManager.shared.notifyNewMessage(
            senderName: msg.sender.nickname,
            text: text,
            chatId: cid,
            avatarURL: msg.sender.avatarURL
        )
    }
}

// MARK: - App Entry Point

@main
struct h2v_iosApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
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
                    Task { await notifManager.requestPermission() }
                }
                .onChange(of: appState.isAuthenticated) { _, authenticated in
                    if authenticated { NotificationManager.shared.clearBadge() }
                }
                // Navigate to chat on notification tap
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("h2v.openChat"))) { notif in
                    if let chatId = notif.userInfo?["chatId"] as? String {
                        appState.pendingOpenChatId = chatId
                    }
                }
        }
    }
}
