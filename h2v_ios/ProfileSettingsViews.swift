import SwiftUI
import UserNotifications

// MARK: - Profile Destination Enum

enum ProfileDestination: Hashable {
    case privacy
    case notifications
    case devices
    case appearance
    case chatBubbles
    case premium
    case dataPrivacy
    case about
}

// MARK: - Privacy Settings

struct PrivacySettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("h2v.showOnline")      private var showOnline      = true
    @AppStorage("h2v.readReceipts")    private var readReceipts    = true
    @AppStorage("h2v.typingIndicator") private var typingIndicator = true
    @AppStorage("h2v.showLastSeen")    private var showLastSeen    = true

    var body: some View {
        SettingsPageView(title: "Конфиденциальность") {
            settingsGroup(title: "Видимость") {
                ToggleRow(icon: "eye.fill", color: Color(hex: "5E8CFF"),
                          label: "Показывать статус онлайн", isOn: $showOnline)
                ToggleRow(icon: "clock.fill", color: Color(hex: "30D158"),
                          label: "Показывать последнее посещение", isOn: $showLastSeen)
            }
            settingsGroup(title: "Сообщения") {
                ToggleRow(icon: "checkmark.message.fill", color: Color(hex: "5E8CFF"),
                          label: "Отметки о прочтении", isOn: $readReceipts)
                ToggleRow(icon: "ellipsis.message.fill", color: Color(hex: "FF9500"),
                          label: "Индикатор набора текста", isOn: $typingIndicator)
            }
            infoCard(
                icon: "lock.shield.fill",
                color: Color(hex: "30D158"),
                text: "Все сообщения зашифрованы по протоколу Signal E2E.\n\n• Статус онлайн: когда выключен — другие видят вас как «недавно был»\n• Отметки о прочтении: когда выключены — собеседник не видит, что вы прочли\n• Индикатор набора: когда выключен — «печатает...» не отображается"
            )
        }
    }
}

// MARK: - Notification Settings

struct NotificationSettingsView: View {
    @StateObject private var nm = NotificationManager.shared
    @AppStorage("h2v.notifMessages") private var notifMessages = true
    @AppStorage("h2v.notifSound")    private var notifSound    = true
    @AppStorage("h2v.notifBadge")    private var notifBadge    = true

    var body: some View {
        SettingsPageView(title: "Уведомления") {
            // System permission block
            settingsGroup(title: "Системные") {
                HStack(spacing: 12) {
                    iconTile(icon: "bell.fill", color: Color(hex: "FF9500"))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Разрешение")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.88))
                        Text(statusText)
                            .font(.system(size: 12))
                            .foregroundStyle(statusColor)
                    }
                    Spacer()
                    if nm.authorizationStatus == .notDetermined || nm.authorizationStatus == .denied {
                        Button(nm.authorizationStatus == .denied ? "Открыть настройки" : "Разрешить") {
                            if nm.authorizationStatus == .denied {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            } else {
                                Task { await nm.requestPermission() }
                            }
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: "5E8CFF"))
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color(hex: "30D158"))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            settingsGroup(title: "Настройки") {
                ToggleRow(icon: "message.fill",   color: Color(hex: "5E8CFF"),
                          label: "Новые сообщения", isOn: $notifMessages)
                ToggleRow(icon: "speaker.wave.2.fill", color: Color(hex: "FF9500"),
                          label: "Звук",           isOn: $notifSound)
                ToggleRow(icon: "app.badge.fill",  color: Color(hex: "FF3B30"),
                          label: "Бейдж на иконке", isOn: $notifBadge)
            }

            infoCard(icon: "bell.badge.fill", color: Color(hex: "FF9500"),
                     text: "Уведомления приходят о новых сообщениях в чатах, которые не заглушены.")
        }
        .task { await nm.refresh() }
    }

    private var statusText: String {
        switch nm.authorizationStatus {
        case .authorized:        return "Включено"
        case .denied:            return "Заблокировано"
        case .notDetermined:     return "Не задано"
        case .provisional:       return "Временное разрешение"
        case .ephemeral:         return "Временное"
        @unknown default:        return "Неизвестно"
        }
    }

    private var statusColor: Color {
        switch nm.authorizationStatus {
        case .authorized: return Color(hex: "30D158")
        case .denied:     return Color(hex: "FF3B30")
        default:          return Color.white.opacity(0.35)
        }
    }
}

// MARK: - Devices View

struct DevicesView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        SettingsPageView(title: "Устройства") {
            settingsGroup(title: "Активная сессия") {
                HStack(spacing: 12) {
                    iconTile(icon: "iphone", color: Color(hex: "30D158"))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(deviceName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.9))
                        Text("Эта сессия · сейчас активна")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(hex: "30D158"))
                    }
                    Spacer()
                    Circle()
                        .fill(Color(hex: "30D158"))
                        .frame(width: 8, height: 8)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            settingsGroup(title: "Аккаунт") {
                HStack(spacing: 12) {
                    iconTile(icon: "person.fill", color: Color(hex: "5E8CFF"))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(appState.currentUser?.nickname ?? "")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.9))
                        Text("ID: \(appState.currentUser?.id.prefix(8) ?? "")...")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.3))
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            Button {
                Task {
                    if let rt = TokenStorage.shared.refreshToken {
                        await APIClient.shared.logout(refreshToken: rt)
                    }
                    appState.signOut()
                }
            } label: {
                Text("Завершить все сессии")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hex: "FF3B30"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .glassBackground(cornerRadius: 14, opacity: 0.3)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color(hex: "FF3B30").opacity(0.2), lineWidth: 0.5)
                    }
            }
            .padding(.horizontal, 20)
        }
    }

    private var deviceName: String {
        UIDevice.current.name
    }
}

// MARK: - Appearance Settings

struct AppearanceSettingsView: View {
    @AppStorage("h2v.colorScheme") private var colorScheme = "dark"
    @AppStorage("h2v.fontSize")    private var fontSize: Double = 15

    let themes: [(id: String, label: String, icon: String)] = [
        ("dark",   "Тёмная",   "moon.fill"),
        ("light",  "Светлая",  "sun.max.fill"),
        ("system", "Системная","circle.lefthalf.filled"),
    ]

    var body: some View {
        SettingsPageView(title: "Внешний вид") {
            settingsGroup(title: "Тема оформления") {
                VStack(spacing: 0) {
                    ForEach(themes, id: \.id) { theme in
                        Button {
                            colorScheme = theme.id
                        } label: {
                            HStack(spacing: 12) {
                                iconTile(icon: theme.icon,
                                         color: theme.id == "dark" ? Color(hex: "BF5AF2") :
                                                theme.id == "light" ? Color(hex: "FFD60A") :
                                                Color(hex: "5E8CFF"))
                                Text(theme.label)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.88))
                                Spacer()
                                if colorScheme == theme.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color(hex: "5E8CFF"))
                                        .font(.system(size: 16))
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if theme.id != "system" {
                            Divider().background(Color.white.opacity(0.055)).padding(.leading, 56)
                        }
                    }
                }
            }

            settingsGroup(title: "Размер шрифта") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Размер")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.88))
                        Spacer()
                        Text("\(Int(fontSize))pt")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                    Slider(value: $fontSize, in: 12...20, step: 1)
                        .tint(Color(hex: "5E8CFF"))
                    Text("Привет, вот так выглядит текст сообщения")
                        .font(.system(size: fontSize))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }
}

// MARK: - Chat Bubbles Style

struct ChatBubblesView: View {
    @AppStorage("h2v.bubbleStyle") private var bubbleStyle = "glass"

    let styles: [(id: String, label: String, desc: String)] = [
        ("glass",    "Стекло",   "Полупрозрачный стеклянный фон"),
        ("solid",    "Тёмные",   "Тёмно-синие плотные пузыри"),
        ("gradient", "Градиент", "Синий градиент для своих"),
    ]

    var body: some View {
        SettingsPageView(title: "Пузыри чата") {
            settingsGroup(title: "Стиль") {
                VStack(spacing: 0) {
                    ForEach(styles, id: \.id) { style in
                        Button { bubbleStyle = style.id } label: {
                            HStack(spacing: 12) {
                                // Mini bubble preview
                                bubblePreview(for: style.id)
                                    .frame(width: 38, height: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(style.label)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(Color.textPrimary)
                                    Text(style.desc)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.textSecondary)
                                }
                                Spacer()
                                if bubbleStyle == style.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color(hex: "5E8CFF"))
                                        .font(.system(size: 18))
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if style.id != "gradient" {
                            Divider().background(Color.glassBorder).padding(.leading, 70)
                        }
                    }
                }
            }

            infoCard(icon: "bubble.left.and.bubble.right.fill", color: Color(hex: "5E8CFF"),
                     text: "Стиль применяется ко всем сообщениям в чатах. Изменение вступает в силу сразу.")
        }
    }

    @ViewBuilder
    private func bubblePreview(for style: String) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(previewFill(for: style))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(previewBorder(for: style), lineWidth: 1)
            }
    }

    private func previewFill(for style: String) -> AnyShapeStyle {
        switch style {
        case "solid":
            return AnyShapeStyle(Color(hex: "1E3A5F"))
        case "gradient":
            return AnyShapeStyle(LinearGradient(
                colors: [Color(hex: "4A7CFF"), Color(hex: "7A4AFF")],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
        default:
            return AnyShapeStyle(Color.bubbleMe)
        }
    }

    private func previewBorder(for style: String) -> Color {
        switch style {
        case "solid":    return Color(hex: "2E5A9C").opacity(0.5)
        case "gradient": return Color(hex: "4A7CFF").opacity(0.4)
        default:         return Color.glassBorder
        }
    }
}

// MARK: - About View

struct AboutView: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
    private let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    var body: some View {
        SettingsPageView(title: "О приложении") {
            // Logo
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color(hex: "4A7CFF"), Color(hex: "7A4AFF")],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 64, height: 64)
                    Text("H")
                        .font(.system(size: 30, weight: .black))
                        .foregroundStyle(.white)
                }
                Text("H2V Messenger")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                Text("v\(version) (build \(build))")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.3))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)

            settingsGroup(title: "Информация") {
                infoRow(label: "Версия",        value: "\(version) (\(build))")
                Divider().background(Color.white.opacity(0.055)).padding(.leading, 20)
                infoRow(label: "Платформа",     value: "iOS \(UIDevice.current.systemVersion)")
                Divider().background(Color.white.opacity(0.055)).padding(.leading, 20)
                infoRow(label: "Устройство",    value: UIDevice.current.model)
                Divider().background(Color.white.opacity(0.055)).padding(.leading, 20)
                infoRow(label: "Шифрование",    value: "Signal Protocol E2E")
            }

            settingsGroup(title: "Ссылки") {
                linkRow(icon: "globe", color: Color(hex: "5E8CFF"), label: "Веб-сайт", url: "https://h2v.app")
                Divider().background(Color.white.opacity(0.055)).padding(.leading, 56)
                linkRow(icon: "doc.text.fill", color: Color(hex: "FF9500"), label: "Политика конфиденциальности", url: "https://h2v.app/privacy")
                Divider().background(Color.white.opacity(0.055)).padding(.leading, 56)
                linkRow(icon: "envelope.fill", color: Color(hex: "30D158"), label: "Поддержка", url: "mailto:support@h2v.app")
            }

            infoCard(icon: "heart.fill", color: Color(hex: "FF3B30"),
                     text: "Сделано с ❤️ командой H2V. Приложение находится в стадии активной разработки.")
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.88))
            Spacer()
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.3))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func linkRow(icon: String, color: Color, label: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) { UIApplication.shared.open(u) }
        } label: {
            HStack(spacing: 12) {
                iconTile(icon: icon, color: color)
                Text(label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.88))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.25))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Premium View

struct PremiumView: View {
    @Environment(\.dismiss) private var dismiss

    let features = [
        (icon: "star.fill",         color: Color(hex: "FFD60A"), title: "Приоритетная поддержка",  desc: "Ответ в течение 1 часа"),
        (icon: "photo.stack.fill",  color: Color(hex: "5E8CFF"), title: "Неограниченное медиа",     desc: "Без ограничений по размеру"),
        (icon: "waveform",          color: Color(hex: "BF5AF2"), title: "Голосовые сообщения",      desc: "До 10 минут"),
        (icon: "checkmark.shield",  color: Color(hex: "30D158"), title: "Верифицированный аккаунт", desc: "Значок ✓ рядом с именем"),
        (icon: "paintpalette.fill", color: Color(hex: "FF9500"), title: "Кастомные темы",           desc: "Эксклюзивные дизайны"),
    ]

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    // Header gradient
                    ZStack {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Color(hex: "4A7CFF").opacity(0.3), Color(hex: "7A4AFF").opacity(0.3)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ))
                            .frame(height: 200)
                        VStack(spacing: 8) {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(Color(hex: "FFD60A"))
                            Text("H2V Premium")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(.white)
                            Text("Разблокируй все возможности")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.white.opacity(0.5))
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white.opacity(0.5))
                                .frame(width: 30, height: 30)
                                .background(Color.white.opacity(0.1), in: Circle())
                        }
                        .padding(16)
                    }
                    .padding(.horizontal, 20)

                    // Features
                    VStack(spacing: 12) {
                        ForEach(features, id: \.title) { feature in
                            HStack(spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(feature.color.opacity(0.18))
                                        .frame(width: 40, height: 40)
                                    Image(systemName: feature.icon)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(feature.color)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(feature.title)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Color.white.opacity(0.9))
                                    Text(feature.desc)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.white.opacity(0.35))
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .glassBackground(cornerRadius: 14, opacity: 0.38)
                        }
                    }
                    .padding(.horizontal, 20)

                    // CTA
                    VStack(spacing: 10) {
                        Button {
                            // TODO: StoreKit purchase
                        } label: {
                            Text("Попробовать бесплатно — 7 дней")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(Color(hex: "FFD60A"), in: RoundedRectangle(cornerRadius: 16))
                                .shadow(color: Color(hex: "FFD60A").opacity(0.35), radius: 16)
                        }
                        Text("Затем 299₽/месяц. Отмена в любой момент.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(0.3))
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                }
                .padding(.top, 20)
            }
            .scrollIndicators(.hidden)
        }
    }
}

// MARK: - Data Privacy View

struct DataPrivacyView: View {
    var body: some View {
        SettingsPageView(title: "Приватность данных") {
            infoCard(icon: "lock.shield.fill", color: Color(hex: "30D158"),
                     text: "Все сообщения зашифрованы по Signal Protocol (E2E). Ключи хранятся только на вашем устройстве.")

            settingsGroup(title: "Что мы храним") {
                DataRow(icon: "person.fill",      color: Color(hex: "5E8CFF"),  label: "Профиль",     value: "Имя, аватар, bio")
                Divider().background(Color.white.opacity(0.055)).padding(.leading, 56)
                DataRow(icon: "message.fill",     color: Color(hex: "FF9500"),  label: "Сообщения",   value: "Зашифрованы E2E")
                Divider().background(Color.white.opacity(0.055)).padding(.leading, 56)
                DataRow(icon: "photo.fill",       color: Color(hex: "BF5AF2"),  label: "Медиа",       value: "На серверах H2V")
                Divider().background(Color.white.opacity(0.055)).padding(.leading, 56)
                DataRow(icon: "clock.fill",       color: Color(hex: "30D158"),  label: "Логи сессий", value: "30 дней")
            }

            settingsGroup(title: "Ваши права") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(["Экспорт данных", "Удаление аккаунта", "Отзыв согласия"], id: \.self) { right in
                        HStack(spacing: 8) {
                            Circle().fill(Color(hex: "30D158")).frame(width: 6, height: 6)
                            Text(right)
                                .font(.system(size: 14))
                                .foregroundStyle(Color.white.opacity(0.75))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }
}

struct DataRow: View {
    let icon: String; let color: Color; let label: String; let value: String
    var body: some View {
        HStack(spacing: 12) {
            iconTile(icon: icon, color: color)
            Text(label).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.white.opacity(0.88))
            Spacer()
            Text(value).font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.3))
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}

// MARK: - Reusable Components for Settings

struct SettingsPageView<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    content()
                    Spacer().frame(height: 40)
                }
                .padding(.top, 16)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.appBg, for: .navigationBar)
    }
}

func settingsGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        SectionHeader(title: title).padding(.horizontal, 24)
        VStack(spacing: 0) { content() }
            .glassBackground(cornerRadius: 18, opacity: 0.38)
            .padding(.horizontal, 20)
    }
}

func iconTile(icon: String, color: Color) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(color.opacity(0.18))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.3), lineWidth: 0.5) }
            .frame(width: 32, height: 32)
        Image(systemName: icon)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(color)
    }
}

func infoCard(icon: String, color: Color, text: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
        Image(systemName: icon)
            .font(.system(size: 16))
            .foregroundStyle(color)
            .padding(.top, 1)
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Color.white.opacity(0.5))
            .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .glassBackground(cornerRadius: 14, opacity: 0.25)
    .padding(.horizontal, 20)
}

// MARK: - Toggle Row

struct ToggleRow: View {
    let icon: String
    let color: Color
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            iconTile(icon: icon, color: color)
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.88))
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Color(hex: "5E8CFF"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
