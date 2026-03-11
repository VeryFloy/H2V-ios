import UserNotifications
import UIKit
import SwiftUI

// MARK: - NotificationManager

@MainActor
final class NotificationManager: NSObject, ObservableObject {
    static let shared = NotificationManager()

    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published var apnsToken: String? = nil

    var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional
    }

    private var badgeCount = 0
    private var avatarCache: [String: URL] = [:]   // senderName → local file URL

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        Task { await refresh() }
    }

    func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    // MARK: - Permission + APNs Registration

    func requestPermission() async {
        do {
            // No .provisional — we need .authorized so banners and sounds are shown.
            // Provisional silently drops to Notification Center with no banner/sound
            // AND sets status to .provisional (not .authorized), breaking isAuthorized.
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            authorizationStatus = granted ? .authorized : .denied
            if granted {
                await MainActor.run {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        } catch {}
    }

    /// Called by AppDelegate-adapter when APNs gives us the device token.
    func didRegisterForRemoteNotifications(deviceToken: Data) {
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        apnsToken = tokenString
        Task {
            try? await APIClient.shared.registerDeviceToken(tokenString)
        }
    }

    /// Called when APNs registration fails (e.g. simulator).
    func didFailToRegisterForRemoteNotifications(error: Error) {
        print("[APNs] Registration failed: \(error.localizedDescription)")
    }

    // MARK: - Local notification (from WebSocket while app is active)

    func notifyNewMessage(senderName: String, text: String, chatId: String,
                          avatarURL: URL? = nil) {
        guard isAuthorized else { return }
        guard !MuteManager.shared.isMuted(chatId) else { return }

        let ud = UserDefaults.standard
        guard ud.object(forKey: "h2v.notifMessages") == nil
              || ud.bool(forKey: "h2v.notifMessages") else { return }

        badgeCount += 1

        let content = UNMutableNotificationContent()
        content.title = senderName
        content.body = text.isEmpty ? "Новое сообщение" : text
        content.badge = NSNumber(value: badgeCount)
        content.userInfo = ["chatId": chatId]
        content.threadIdentifier = chatId          // groups notifications by chat

        let soundEnabled = ud.object(forKey: "h2v.notifSound") == nil
            || ud.bool(forKey: "h2v.notifSound")
        content.sound = soundEnabled ? .default : nil

        // If we already have the avatar cached, attach it immediately
        if let localURL = avatarURL.flatMap({ avatarCache[$0.absoluteString] }) {
            attachAvatarAndSchedule(content: content, avatarPath: localURL, chatId: chatId)
        } else if let remoteURL = avatarURL {
            // Download avatar in background, then schedule
            Task {
                let localURL = await downloadAvatar(from: remoteURL)
                attachAvatarAndSchedule(content: content, avatarPath: localURL, chatId: chatId)
            }
        } else {
            scheduleNotification(content: content, chatId: chatId)
        }
    }

    // MARK: - Badge

    func clearBadge() {
        badgeCount = 0
        UNUserNotificationCenter.current().setBadgeCount(0)
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    func decrementBadge(by amount: Int = 1) {
        badgeCount = max(0, badgeCount - amount)
        UNUserNotificationCenter.current().setBadgeCount(badgeCount)
    }

    // MARK: - Private helpers

    private func downloadAvatar(from url: URL) async -> URL? {
        // Return cached file URL if already downloaded
        if let cached = avatarCache[url.absoluteString] {
            return cached
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".jpg")
            try data.write(to: tmpURL)
            avatarCache[url.absoluteString] = tmpURL
            return tmpURL
        } catch {
            return nil
        }
    }

    private func attachAvatarAndSchedule(content: UNMutableNotificationContent,
                                          avatarPath: URL?, chatId: String) {
        if let path = avatarPath,
           let attachment = try? UNNotificationAttachment(identifier: "avatar",
                                                          url: path,
                                                          options: nil) {
            content.attachments = [attachment]
        }
        scheduleNotification(content: content, chatId: chatId)
    }

    private func scheduleNotification(content: UNMutableNotificationContent, chatId: String) {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.05, repeats: false)
        let req = UNNotificationRequest(
            identifier: "msg-\(chatId)-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(req)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    // Show banner even when app is in foreground
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completion([.banner, .sound, .badge])
    }

    // Navigate to chat on notification tap
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completion: @escaping () -> Void
    ) {
        if let chatId = response.notification.request.content.userInfo["chatId"] as? String {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Notification.Name("h2v.openChat"),
                    object: nil,
                    userInfo: ["chatId": chatId]
                )
            }
        }
        completion()
    }
}

// MARK: - MuteManager

final class MuteManager {
    static let shared = MuteManager()
    private let key = "h2v.mutedChats"

    var mutedIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: key) }
    }

    func isMuted(_ id: String) -> Bool { mutedIds.contains(id) }

    func toggle(_ id: String) {
        var ids = mutedIds
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        mutedIds = ids
    }
}

// MARK: - AppPreferences

final class AppPreferences {
    static let shared = AppPreferences()

    @AppStorage("h2v.colorScheme")    var colorScheme: String = "dark"
    @AppStorage("h2v.fontSize")       var fontSize: Double = 15
    @AppStorage("h2v.showOnline")     var showOnlineStatus: Bool = true
    @AppStorage("h2v.readReceipts")   var sendReadReceipts: Bool = true
    @AppStorage("h2v.typingIndicator") var sendTypingIndicator: Bool = true

    var preferredColorScheme: ColorScheme? {
        switch colorScheme {
        case "light":  return .light
        case "system": return nil
        default:       return .dark
        }
    }
}
