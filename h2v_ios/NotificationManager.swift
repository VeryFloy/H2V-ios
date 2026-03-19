import Foundation
import UserNotifications
import UIKit

@MainActor
final class NotificationManager: ObservableObject {
    static let shared = NotificationManager()

    @Published var hasPermission = false
    private var deviceToken: String?

    func requestPermission() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            hasPermission = granted
            if granted {
                await MainActor.run {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        } catch {}
    }

    func registerToken(_ token: Data) {
        let tokenString = token.map { String(format: "%02x", $0) }.joined()
        deviceToken = tokenString
        Task {
            try? await APIClient.shared.registerDeviceToken(token: tokenString)
        }
    }

    func handleMessage(event: WSEvent, appState: AppState?) {
        guard event.event == "message:new" else { return }
        guard let msg = event.decodeMessage() else { return }
        guard let me = appState?.currentUser, msg.sender?.id != me.id else { return }

        guard let chatId = msg.chatId else { return }
        guard chatId != appState?.activeChatId else { return }

        let senderName = msg.sender?.displayName ?? "Новое сообщение"
        let text: String
        switch msg.type {
        case .image: text = msg.text ?? "📷 Фото"
        case .video: text = msg.text ?? "🎬 Видео"
        case .audio: text = "🎤 Голосовое сообщение"
        case .file:  text = "📎 \(msg.mediaName ?? "Файл")"
        case .system: text = msg.text ?? ""
        default:
            if msg.ciphertext != nil { text = "🔒 Зашифрованное сообщение" }
            else { text = msg.text ?? "Новое сообщение" }
        }

        sendLocal(title: senderName, body: text, chatId: chatId)
    }

    func sendLocal(title: String, body: String, chatId: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["chatId": chatId]
        content.threadIdentifier = chatId

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func clearBadge() {
        UNUserNotificationCenter.current().setBadgeCount(0)
    }
}
