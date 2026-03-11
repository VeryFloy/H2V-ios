import UserNotifications
import UIKit
import SwiftUI

// MARK: - NotificationManager

@MainActor
final class NotificationManager: NSObject, ObservableObject {
    static let shared = NotificationManager()

    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined

    var isAuthorized: Bool { authorizationStatus == .authorized }

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        Task { await refresh() }
    }

    func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    func requestPermission() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            authorizationStatus = granted ? .authorized : .denied
        } catch {}
    }

    /// Sends a local notification for a new message (respects mute + user toggles).
    func notifyNewMessage(senderName: String, text: String, chatId: String) {
        guard isAuthorized else { return }
        guard !MuteManager.shared.isMuted(chatId) else { return }

        let ud = UserDefaults.standard
        guard ud.object(forKey: "h2v.notifMessages") == nil
              || ud.bool(forKey: "h2v.notifMessages") else { return }

        let content = UNMutableNotificationContent()
        content.title = senderName
        content.body = text.isEmpty ? "Новое сообщение" : text

        let soundEnabled = ud.object(forKey: "h2v.notifSound") == nil || ud.bool(forKey: "h2v.notifSound")
        content.sound = soundEnabled ? .default : nil

        let badgeEnabled = ud.object(forKey: "h2v.notifBadge") == nil || ud.bool(forKey: "h2v.notifBadge")
        if badgeEnabled {
            content.badge = 1
        }

        content.userInfo = ["chatId": chatId]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.05, repeats: false)
        let req = UNNotificationRequest(identifier: "msg-\(UUID().uuidString)", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(req)
    }

    func clearBadge() {
        UNUserNotificationCenter.current().setBadgeCount(0)
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    // Show banner even when app is in foreground
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completion([.banner, .sound, .badge])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completion: @escaping () -> Void
    ) {
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
