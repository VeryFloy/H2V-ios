import SwiftUI
import PhotosUI

// MARK: - Profile (My Profile)

struct ProfileView: View {
    @EnvironmentObject var appState: AppState
    @State private var showSettings = false
    @State private var showSessions = false
    @State private var showContacts = false
    @State private var showEditProfile = false
    @State private var showLogoutConfirm = false
    @State private var selectedAvatar: PhotosPickerItem?

    private var user: User? { appState.currentUser }

    var body: some View {
        ZStack {
            Color.bgApp.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    avatarSection
                    menuSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("Профиль")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Настройки") { showSettings = true }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.h2vAccent)
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .environmentObject(appState)
            }
        }
        .sheet(isPresented: $showEditProfile) {
            NavigationStack {
                EditProfileView()
                    .environmentObject(appState)
            }
        }
        .sheet(isPresented: $showSessions) {
            NavigationStack { SessionsView() }
        }
        .sheet(isPresented: $showContacts) {
            NavigationStack {
                ContactsView()
                    .environmentObject(appState)
            }
        }
        .alert("Выйти из аккаунта?", isPresented: $showLogoutConfirm) {
            Button("Отмена", role: .cancel) {}
            Button("Выйти", role: .destructive) { appState.signOut() }
        }
    }

    private var avatarSection: some View {
        VStack(spacing: 12) {
            PhotosPicker(selection: $selectedAvatar, matching: .images) {
                AvatarView(url: user?.avatarURL, initials: user?.initials ?? "?",
                           size: 88, id: user?.id ?? "")
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                            .frame(width: 28, height: 28)
                            .background(Color.h2vAccent, in: Circle())
                            .overlay(Circle().stroke(Color.bgApp, lineWidth: 2))
                    }
            }
            .onChange(of: selectedAvatar) { _, item in
                guard let item else { return }
                uploadAvatar(item)
            }

            VStack(spacing: 4) {
                Text(user?.displayName ?? "")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.textPrimary)
                Text("@\(user?.nickname ?? "")")
                    .font(.system(size: 14))
                    .foregroundColor(.textSecondary)
                if let bio = user?.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.system(size: 13))
                        .foregroundColor(.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }
        }
        .padding(.vertical, 16)
    }

    private func uploadAvatar(_ item: PhotosPickerItem) {
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else { return }
            do {
                let result = try await APIClient.shared.upload(
                    fileData: data, filename: "avatar.jpg", mimeType: "image/jpeg"
                )
                let updated = try await APIClient.shared.updateMe(data: ["avatar": result.url])
                appState.currentUser = updated
            } catch {}
        }
    }

    private var menuSection: some View {
        VStack(spacing: 2) {
            menuItem(icon: "pencil", title: "Редактировать профиль", color: .h2vAccent) {
                showEditProfile = true
            }

            Divider().background(Color.borderPrimary).padding(.leading, 56)

            menuItem(icon: "gearshape", title: "Основные", color: .h2vAccent) {
                showSettings = true
            }

            Divider().background(Color.borderPrimary).padding(.leading, 56)

            menuItem(icon: "person.2", title: "Контакты", color: .h2vAccent) {
                showContacts = true
            }

            Divider().background(Color.borderPrimary).padding(.leading, 56)

            menuItem(icon: "iphone", title: "Активные сессии", color: .h2vAccent) {
                showSessions = true
            }

            Divider().background(Color.borderPrimary).padding(.vertical, 8)

            menuItem(icon: "rectangle.portrait.and.arrow.right", title: "Выйти", color: .danger) {
                showLogoutConfirm = true
            }
        }
        .cardBackground(radius: 16)
    }

    private func menuItem(icon: String, title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(color)
                    .frame(width: 32)
                Text(title)
                    .font(.system(size: 15))
                    .foregroundColor(color == .danger ? .danger : .textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
    }
}

// MARK: - Edit Profile

struct EditProfileView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var bio = ""
    @State private var nickname = ""
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        ZStack {
            Color.bgApp.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    inputRow(title: "Имя", text: $firstName, placeholder: "Имя")
                    inputRow(title: "Фамилия", text: $lastName, placeholder: "Фамилия")
                    inputRow(title: "Юзернейм", text: $nickname, placeholder: "username")

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("О себе")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.textSecondary)
                            Spacer()
                            Text("\(bio.count)/70")
                                .font(.system(size: 11))
                                .foregroundColor(bio.count > 70 ? .danger : .textTertiary)
                        }
                        TextField("", text: $bio, prompt: Text("Расскажите о себе").foregroundColor(.textTertiary), axis: .vertical)
                            .foregroundColor(.textPrimary)
                            .font(.system(size: 15))
                            .lineLimit(2...3)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .inputStyle(radius: 10)
                            .onChange(of: bio) { _, val in
                                if val.count > 70 { bio = String(val.prefix(70)) }
                            }
                    }

                    if let error {
                        Text(error).font(.system(size: 12)).foregroundColor(.danger)
                    }

                    AccentButton(title: "Сохранить", isLoading: isSaving) { save() }
                }
                .padding(16)
            }
        }
        .navigationTitle("Редактировать")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Отмена") { dismiss() }.foregroundColor(.textSecondary)
            }
        }
        .onAppear {
            if let user = appState.currentUser {
                firstName = user.firstName ?? ""
                lastName = user.lastName ?? ""
                bio = user.bio ?? ""
                nickname = user.nickname
            }
        }
    }

    private func inputRow(title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.textSecondary)
            TextField("", text: text, prompt: Text(placeholder).foregroundColor(.textTertiary))
                .foregroundColor(.textPrimary)
                .font(.system(size: 15))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .inputStyle(radius: 10)
        }
    }

    private func save() {
        isSaving = true; error = nil
        Task {
            do {
                var data: [String: Any] = [
                    "firstName": firstName,
                    "lastName": lastName,
                    "bio": bio
                ]
                if nickname != appState.currentUser?.nickname { data["nickname"] = nickname }
                let updated = try await APIClient.shared.updateMe(data: data)
                appState.currentUser = updated
                dismiss()
            } catch let e as NetworkError { error = e.localizedDescription }
            catch { self.error = error.localizedDescription }
            isSaving = false
        }
    }
}

// MARK: - Settings (FULL with sub-pages like frontend)

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    @AppStorage("h2v.theme") private var theme = "dark"
    @AppStorage("h2v.notifSound") private var notifSound = true
    @AppStorage("h2v.sendByEnter") private var sendByEnter = true
    @AppStorage("h2v.fontSize") private var fontSize = "medium"
    @AppStorage("h2v.chatWallpaper") private var chatWallpaper = "default"
    @AppStorage("h2v.mediaAutoDownload") private var mediaAutoDownload = true
    @AppStorage("h2v.showOnlineStatus") private var showOnlineStatus = "all"
    @AppStorage("h2v.showReadReceipts") private var showReadReceipts = "all"
    @AppStorage("h2v.showAvatar") private var showAvatar = "all"
    @AppStorage("h2v.allowGroupInvites") private var allowGroupInvites = "all"
    @AppStorage("h2v.autoDeleteMonths") private var autoDeleteMonths = "never"

    @State private var currentPage: SettingsPage = .main
    @State private var showDeleteConfirm = false
    @State private var deleteConfirmText = ""
    @State private var showBlacklist = false
    @State private var showLogoutConfirm = false
    @State private var cacheSizeMB: Double = 0

    private var cacheSizeText: String {
        if cacheSizeMB < 1 { return String(format: "%.0f КБ", cacheSizeMB * 1024) }
        return String(format: "%.1f МБ", cacheSizeMB)
    }

    enum SettingsPage: String, CaseIterable {
        case main, general, notifications, chat, privacy, sessions
    }

    var body: some View {
        ZStack {
            Color.bgApp.ignoresSafeArea()

            switch currentPage {
            case .main:      mainMenu.transition(.move(edge: .leading))
            case .general:   generalPage.transition(.move(edge: .trailing))
            case .notifications: notificationsPage.transition(.move(edge: .trailing))
            case .chat:      chatPage.transition(.move(edge: .trailing))
            case .privacy:   privacyPage.transition(.move(edge: .trailing))
            case .sessions:  sessionsPage.transition(.move(edge: .trailing))
            }
        }
        .navigationTitle(pageTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if currentPage == .main {
                    Button("Закрыть") { dismiss() }.foregroundColor(.textSecondary)
                } else {
                    Button { withAnimation(.easeInOut(duration: 0.25)) { currentPage = .main } } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                            Text("Назад")
                        }.foregroundColor(.h2vAccent)
                    }
                }
            }
        }
        .onAppear { loadSettings(); cacheSizeMB = CacheManager.shared.totalSizeMB() }
        .sheet(isPresented: $showBlacklist) {
            NavigationStack { BlacklistView() }
        }
        .alert("Удалить аккаунт?", isPresented: $showDeleteConfirm) {
            TextField("Введите DELETE", text: $deleteConfirmText)
            Button("Отмена", role: .cancel) { deleteConfirmText = "" }
            Button("Удалить навсегда", role: .destructive) {
                guard deleteConfirmText == "DELETE" else { return }
                Task { try? await APIClient.shared.deleteMe(); appState.signOut() }
            }
        } message: {
            Text("Это действие необратимо. Все данные будут удалены.\nВведите DELETE для подтверждения.")
        }
        .alert("Выйти из аккаунта?", isPresented: $showLogoutConfirm) {
            Button("Отмена", role: .cancel) {}
            Button("Выйти", role: .destructive) { dismiss(); appState.signOut() }
        }
    }

    private var pageTitle: String {
        switch currentPage {
        case .main: return "Настройки"
        case .general: return "Основные"
        case .notifications: return "Уведомления"
        case .chat: return "Чаты"
        case .privacy: return "Приватность"
        case .sessions: return "Сессии"
        }
    }

    private func navigateTo(_ page: SettingsPage) {
        withAnimation(.easeInOut(duration: 0.25)) { currentPage = page }
    }

    // MARK: - Main Menu

    private var mainMenu: some View {
        ScrollView {
            VStack(spacing: 2) {
                settingsMenuItem(icon: "gearshape", title: "Основные", subtitle: "Тема, язык, шрифт") {
                    navigateTo(.general)
                }
                Divider().background(Color.borderPrimary).padding(.leading, 56)

                settingsMenuItem(icon: "bell", title: "Уведомления", subtitle: "Звук, push") {
                    navigateTo(.notifications)
                }
                Divider().background(Color.borderPrimary).padding(.leading, 56)

                settingsMenuItem(icon: "bubble.left.and.bubble.right", title: "Настройки чатов", subtitle: "Обои, шрифт, медиа") {
                    navigateTo(.chat)
                }
                Divider().background(Color.borderPrimary).padding(.leading, 56)

                settingsMenuItem(icon: "lock.shield", title: "Приватность и безопасность", subtitle: "Онлайн, прочтение, блокировки") {
                    navigateTo(.privacy)
                }
                Divider().background(Color.borderPrimary).padding(.leading, 56)

                settingsMenuItem(icon: "iphone.and.arrow.forward", title: "Сессии", subtitle: "Активные устройства") {
                    navigateTo(.sessions)
                }

                Divider().background(Color.borderPrimary).padding(.vertical, 8)

                Button { showLogoutConfirm = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 16)).foregroundColor(.warning).frame(width: 32)
                        Text("Выйти").font(.system(size: 15, weight: .medium)).foregroundColor(.warning)
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 13)
                }
            }
            .cardBackground(radius: 16)
            .padding(16)
        }
    }

    private func settingsMenuItem(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(.h2vAccent)
                    .frame(width: 32, height: 32)
                    .background(Color.h2vAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .medium)).foregroundColor(.textPrimary)
                    Text(subtitle).font(.system(size: 12)).foregroundColor(.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium)).foregroundColor(.textTertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    // MARK: - General Page

    private var generalPage: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("ТЕМА")
                    themeSegment.cardBackground(radius: 14)
                }

                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("РАЗМЕР ШРИФТА")
                    fontSizeSegment.cardBackground(radius: 14)
                }

                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("КЕШ")
                    Button {
                        CacheManager.shared.clearAll()
                        cacheSizeMB = 0
                    } label: {
                        HStack {
                            Image(systemName: "trash").font(.system(size: 15)).foregroundColor(.h2vAccent)
                            Text("Очистить кеш").font(.system(size: 15)).foregroundColor(.textPrimary)
                            Spacer()
                            Text(cacheSizeText)
                                .font(.system(size: 13)).foregroundColor(.textTertiary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 13)
                    }
                    .cardBackground(radius: 14)
                }

                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("СБРОС")
                    Button {
                        theme = "dark"; fontSize = "medium"; notifSound = true
                        sendByEnter = true; chatWallpaper = "default"; mediaAutoDownload = true
                        showOnlineStatus = "all"; showReadReceipts = "all"
                        showAvatar = "all"; allowGroupInvites = "all"
                        autoDeleteMonths = "never"
                        syncSettings()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.counterclockwise").font(.system(size: 15)).foregroundColor(.warning)
                            Text("Сбросить настройки").font(.system(size: 15)).foregroundColor(.warning)
                            Spacer()
                        }
                        .padding(.horizontal, 14).padding(.vertical, 13)
                    }
                    .cardBackground(radius: 14)
                }
            }
            .padding(16)
        }
    }

    private var themeSegment: some View {
        HStack(spacing: 0) {
            themeBtn("Тёмная", value: "dark")
            themeBtn("Светлая", value: "light")
            themeBtn("Система", value: "system")
        }
        .padding(4)
    }

    private func themeBtn(_ title: String, value: String) -> some View {
        let active = theme == value
        return Button { theme = value; syncSettings() } label: {
            Text(title)
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundColor(active ? .textPrimary : .textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(active ? Color.bgElevated : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var fontSizeSegment: some View {
        HStack(spacing: 0) {
            fontBtn("Маленький", value: "small")
            fontBtn("Средний", value: "medium")
            fontBtn("Большой", value: "large")
        }
        .padding(4)
    }

    private func fontBtn(_ title: String, value: String) -> some View {
        let active = fontSize == value
        return Button { fontSize = value; syncSettings() } label: {
            Text(title)
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundColor(active ? .textPrimary : .textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(active ? Color.bgElevated : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: - Notifications Page

    private var notificationsPage: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 0) {
                    Toggle(isOn: $notifSound) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Звук уведомлений").font(.system(size: 15)).foregroundColor(.textPrimary)
                            Text("Воспроизводить звук при получении").font(.system(size: 12)).foregroundColor(.textSecondary)
                        }
                    }
                    .tint(.h2vAccent)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .onChange(of: notifSound) { _, _ in syncSettings() }
                }
                .cardBackground(radius: 14)
            }
            .padding(16)
        }
    }

    // MARK: - Chat Page

    private var chatPage: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 0) {
                    Toggle(isOn: $sendByEnter) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Отправка по Enter").font(.system(size: 15)).foregroundColor(.textPrimary)
                            Text(sendByEnter ? "Enter — отправить, Shift+Enter — новая строка" : "Enter — новая строка, кнопка — отправить")
                                .font(.system(size: 12)).foregroundColor(.textSecondary)
                        }
                    }
                    .tint(.h2vAccent)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .onChange(of: sendByEnter) { _, _ in syncSettings() }

                    Divider().background(Color.borderPrimary).padding(.leading, 14)

                    settingsRow(icon: "photo.on.rectangle", title: "Обои чата") {
                        Menu {
                            ForEach(["default", "dark", "dots", "gradient"], id: \.self) { wp in
                                Button {
                                    chatWallpaper = wp; syncSettings()
                                } label: {
                                    HStack {
                                        Text(wallpaperLabel(wp))
                                        if chatWallpaper == wp { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        } label: {
                            Text(wallpaperLabel(chatWallpaper))
                                .font(.system(size: 13, weight: .medium)).foregroundColor(.h2vAccent)
                        }
                    }

                    Divider().background(Color.borderPrimary).padding(.leading, 14)

                    Toggle(isOn: $mediaAutoDownload) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Автозагрузка медиа").font(.system(size: 15)).foregroundColor(.textPrimary)
                            Text("Автоматически скачивать фото и видео").font(.system(size: 12)).foregroundColor(.textSecondary)
                        }
                    }
                    .tint(.h2vAccent)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .onChange(of: mediaAutoDownload) { _, _ in syncSettings() }
                }
                .cardBackground(radius: 14)
            }
            .padding(16)
        }
    }

    private func wallpaperLabel(_ wp: String) -> String {
        switch wp {
        case "dark": return "Тёмные"
        case "dots": return "Точки"
        case "gradient": return "Градиент"
        default: return "По умолчанию"
        }
    }

    // MARK: - Privacy Page

    private var privacyPage: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("КТО МОЖЕТ ВИДЕТЬ")

                    VStack(spacing: 0) {
                        privacyRow(icon: "circle.fill", title: "Статус онлайн", desc: "Кто видит что вы в сети", value: $showOnlineStatus)
                        Divider().background(Color.borderPrimary).padding(.leading, 14)
                        privacyRow(icon: "checkmark.circle", title: "Статус прочтения", desc: "Синие галочки", value: $showReadReceipts)
                        Divider().background(Color.borderPrimary).padding(.leading, 14)
                        privacyRow(icon: "person.crop.circle", title: "Аватар", desc: "Кто видит ваш аватар", value: $showAvatar)
                        Divider().background(Color.borderPrimary).padding(.leading, 14)
                        privacyRow(icon: "person.3", title: "Приглашение в группы", desc: "Кто может добавить в группу", value: $allowGroupInvites)
                    }
                    .cardBackground(radius: 14)
                }

                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("БЛОКИРОВКИ")

                    Button { showBlacklist = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "hand.raised").font(.system(size: 15)).foregroundColor(.danger).frame(width: 26)
                            Text("Чёрный список").font(.system(size: 15)).foregroundColor(.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium)).foregroundColor(.textTertiary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 13)
                    }
                    .cardBackground(radius: 14)
                }

                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("АККАУНТ")

                    VStack(spacing: 0) {
                        settingsRow(icon: "clock.arrow.circlepath", title: "Автоудаление при неактивности") {
                            Menu {
                                ForEach(["never", "1", "3", "6", "12"], id: \.self) { val in
                                    Button {
                                        autoDeleteMonths = val; syncSettings()
                                    } label: {
                                        HStack {
                                            Text(autoDeleteLabel(val))
                                            if autoDeleteMonths == val { Image(systemName: "checkmark") }
                                        }
                                    }
                                }
                            } label: {
                                Text(autoDeleteLabel(autoDeleteMonths))
                                    .font(.system(size: 13, weight: .medium)).foregroundColor(.h2vAccent)
                            }
                        }

                        Divider().background(Color.borderPrimary).padding(.leading, 14)

                        Button { showDeleteConfirm = true } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle").font(.system(size: 15)).foregroundColor(.danger).frame(width: 26)
                                Text("Удалить аккаунт").font(.system(size: 15)).foregroundColor(.danger)
                                Spacer()
                            }
                            .padding(.horizontal, 14).padding(.vertical, 13)
                        }
                    }
                    .cardBackground(radius: 14)
                }
            }
            .padding(16)
        }
    }

    private func autoDeleteLabel(_ val: String) -> String {
        switch val {
        case "1": return "1 месяц"
        case "3": return "3 месяца"
        case "6": return "6 месяцев"
        case "12": return "12 месяцев"
        default: return "Никогда"
        }
    }

    private func privacyRow(icon: String, title: String, desc: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14)).foregroundColor(.h2vAccent).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15)).foregroundColor(.textPrimary)
                    Text(desc).font(.system(size: 12)).foregroundColor(.textSecondary)
                }
                Spacer()
            }

            HStack(spacing: 0) {
                privacyBtn("Все", val: "all", current: value)
                privacyBtn("Контакты", val: "contacts", current: value)
                privacyBtn("Никто", val: "nobody", current: value)
            }
            .padding(3)
            .background(Color.bgElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.leading, 36)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func privacyBtn(_ title: String, val: String, current: Binding<String>) -> some View {
        let active = current.wrappedValue == val
        return Button { current.wrappedValue = val; syncSettings() } label: {
            Text(title)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .foregroundColor(active ? .textPrimary : .textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(active ? Color.bgCard : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    // MARK: - Sessions Page (inline)

    @State private var sessions: [SessionInfo] = []
    @State private var sessionsLoading = true

    private var sessionsPage: some View {
        ScrollView {
            VStack(spacing: 16) {
                if sessionsLoading {
                    ProgressView().padding(.top, 40)
                } else if sessions.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "iphone.slash")
                            .font(.system(size: 40)).foregroundColor(.textTertiary)
                        Text("Нет активных сессий")
                            .font(.system(size: 15)).foregroundColor(.textSecondary)
                    }.padding(.top, 40)
                } else {
                    if let current = sessions.first(where: { $0.isCurrent }) {
                        VStack(alignment: .leading, spacing: 10) {
                            sectionHeader("ТЕКУЩЕЕ УСТРОЙСТВО")
                            sessionRow(current, isCurrent: true).cardBackground(radius: 14)
                        }
                    }

                    let others = sessions.filter { !$0.isCurrent }
                    if !others.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            sectionHeader("АКТИВНЫЕ СЕССИИ")
                            VStack(spacing: 0) {
                                ForEach(Array(others.enumerated()), id: \.element.id) { idx, session in
                                    sessionRow(session, isCurrent: false)
                                    if idx < others.count - 1 {
                                        Divider().background(Color.borderPrimary).padding(.leading, 56)
                                    }
                                }
                            }
                            .cardBackground(radius: 14)
                        }

                        Button {
                            Task {
                                try? await APIClient.shared.terminateOtherSessions()
                                sessions.removeAll { !$0.isCurrent }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "xmark.circle").font(.system(size: 15))
                                Text("Завершить все другие сессии").font(.system(size: 14, weight: .medium))
                            }
                            .foregroundColor(.danger)
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                            .cardBackground(radius: 12)
                        }
                    }
                }
            }
            .padding(16)
        }
        .onAppear {
            Task {
                do { sessions = try await APIClient.shared.getSessions() } catch {}
                sessionsLoading = false
            }
        }
    }

    private func sessionRow(_ session: SessionInfo, isCurrent: Bool) -> some View {
        HStack(spacing: 12) {
            let isMobile = session.deviceName?.lowercased().contains("mobile") == true ||
                           session.deviceName?.lowercased().contains("iphone") == true ||
                           session.deviceName?.lowercased().contains("android") == true ||
                           session.deviceName?.lowercased().contains("ios") == true
            Image(systemName: isMobile ? "iphone" : "desktopcomputer")
                .font(.system(size: 20))
                .foregroundColor(isCurrent ? .h2vAccent : .textSecondary)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.deviceName ?? "Неизвестное устройство")
                        .font(.system(size: 14, weight: .medium)).foregroundColor(.textPrimary)
                    if isCurrent {
                        Text("Текущая")
                            .font(.system(size: 10, weight: .bold)).foregroundColor(.success)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.success.opacity(0.15), in: Capsule())
                    }
                }
                if let loc = session.location {
                    Text(loc).font(.system(size: 12)).foregroundColor(.textSecondary)
                }
                Text(DateHelper.chatRow(session.lastActiveAt))
                    .font(.system(size: 11)).foregroundColor(.textTertiary)
            }

            Spacer()

            if !isCurrent {
                Button {
                    Task {
                        try? await APIClient.shared.terminateSession(id: session.id)
                        sessions.removeAll { $0.id == session.id }
                    }
                } label: {
                    Image(systemName: "xmark.circle").font(.system(size: 18)).foregroundColor(.danger)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.textTertiary)
            .tracking(0.9)
    }

    private func settingsRow<Content: View>(icon: String, title: String, @ViewBuilder trailing: () -> Content) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 15)).foregroundColor(.h2vAccent).frame(width: 26)
            Text(title).font(.system(size: 15)).foregroundColor(.textPrimary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    // MARK: - Sync

    private func loadSettings() {
        Task {
            let s = try? await APIClient.shared.getSettings()
            guard let s else { return }
            if let v = s["notifSound"] as? Bool { notifSound = v }
            if let v = s["sendByEnter"] as? Bool { sendByEnter = v }
            if let v = s["fontSize"] as? String { fontSize = v }
            if let v = s["chatWallpaper"] as? String { chatWallpaper = v }
            if let v = s["mediaAutoDownload"] as? Bool { mediaAutoDownload = v }
            if let v = s["showOnlineStatus"] as? String { showOnlineStatus = v }
            if let v = s["showReadReceipts"] as? String { showReadReceipts = v }
            if let v = s["showAvatar"] as? String { showAvatar = v }
            if let v = s["allowGroupInvites"] as? String { allowGroupInvites = v }
            if let v = s["autoDeleteMonths"] as? String { autoDeleteMonths = v }
            if let v = s["theme"] as? String { theme = v }
        }
    }

    private func syncSettings() {
        Task {
            try? await APIClient.shared.updateSettings(data: [
                "notifSound": notifSound,
                "sendByEnter": sendByEnter,
                "fontSize": fontSize,
                "chatWallpaper": chatWallpaper,
                "mediaAutoDownload": mediaAutoDownload,
                "showOnlineStatus": showOnlineStatus,
                "showReadReceipts": showReadReceipts,
                "showAvatar": showAvatar,
                "allowGroupInvites": allowGroupInvites,
                "autoDeleteMonths": autoDeleteMonths,
                "theme": theme
            ])
        }
    }
}

// MARK: - Blacklist View

struct BlacklistView: View {
    @Environment(\.dismiss) var dismiss
    @State private var blockedIds: [String] = []
    @State private var blockedUsers: [User] = []
    @State private var isLoading = true

    var body: some View {
        ZStack {
            Color.bgApp.ignoresSafeArea()

            if isLoading {
                ProgressView()
            } else if blockedUsers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "hand.raised.slash")
                        .font(.system(size: 40))
                        .foregroundColor(.textTertiary)
                    Text("Чёрный список пуст")
                        .font(.system(size: 15))
                        .foregroundColor(.textSecondary)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(blockedUsers) { user in
                            HStack(spacing: 12) {
                                AvatarView(url: user.avatarURL, initials: user.initials, size: 44, id: user.id)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(user.displayName).font(.system(size: 15, weight: .medium)).foregroundColor(.textPrimary)
                                    Text("@\(user.nickname)").font(.system(size: 12)).foregroundColor(.textSecondary)
                                }
                                Spacer()
                                Button("Разблокировать") {
                                    Task {
                                        try? await APIClient.shared.unblockUser(id: user.id)
                                        blockedUsers.removeAll { $0.id == user.id }
                                    }
                                }
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.danger)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                        }
                    }
                    .cardBackground(radius: 16)
                    .padding(16)
                }
            }
        }
        .navigationTitle("Чёрный список")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Закрыть") { dismiss() }.foregroundColor(.textSecondary)
            }
        }
        .onAppear { load() }
    }

    private func load() {
        Task {
            do {
                let ids = try await APIClient.shared.getBlockedUsers()
                var users: [User] = []
                for id in ids {
                    if let u = try? await APIClient.shared.getUser(id: id) {
                        users.append(u)
                    }
                }
                blockedUsers = users
            } catch {}
            isLoading = false
        }
    }
}

// MARK: - Sessions View

struct SessionsView: View {
    @Environment(\.dismiss) var dismiss
    @State private var sessions: [SessionInfo] = []
    @State private var isLoading = true
    @State private var showTerminateAll = false

    var body: some View {
        ZStack {
            Color.bgApp.ignoresSafeArea()

            if isLoading {
                ProgressView()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(sessions) { session in
                            HStack(spacing: 12) {
                                Image(systemName: session.deviceName?.lowercased().contains("mobile") == true ? "iphone" : "desktopcomputer")
                                    .font(.system(size: 20))
                                    .foregroundColor(session.isCurrent ? .h2vAccent : .textSecondary)
                                    .frame(width: 36)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(session.deviceName ?? "Неизвестное устройство")
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundColor(.textPrimary)
                                        if session.isCurrent {
                                            Text("Текущая")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundColor(.success)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.success.opacity(0.15), in: Capsule())
                                        }
                                    }
                                    if let location = session.location {
                                        Text(location)
                                            .font(.system(size: 12))
                                            .foregroundColor(.textSecondary)
                                    }
                                    Text(DateHelper.chatRow(session.lastActiveAt))
                                        .font(.system(size: 11))
                                        .foregroundColor(.textTertiary)
                                }

                                Spacer()

                                if !session.isCurrent {
                                    Button {
                                        Task {
                                            try? await APIClient.shared.terminateSession(id: session.id)
                                            sessions.removeAll { $0.id == session.id }
                                        }
                                    } label: {
                                        Image(systemName: "xmark.circle")
                                            .font(.system(size: 18))
                                            .foregroundColor(.danger)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)

                            if session.id != sessions.last?.id {
                                Divider().background(Color.borderPrimary).padding(.leading, 64)
                            }
                        }
                    }
                    .cardBackground(radius: 16)
                    .padding(16)

                    if sessions.filter({ !$0.isCurrent }).count > 0 {
                        Button {
                            Task {
                                try? await APIClient.shared.terminateOtherSessions()
                                sessions.removeAll { !$0.isCurrent }
                            }
                        } label: {
                            Text("Завершить все другие сессии")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.danger)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .cardBackground(radius: 12)
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
        .navigationTitle("Активные сессии")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Закрыть") { dismiss() }.foregroundColor(.textSecondary)
            }
        }
        .onAppear { load() }
    }

    private func load() {
        Task {
            do { sessions = try await APIClient.shared.getSessions() } catch {}
            isLoading = false
        }
    }
}

// MARK: - Contacts View

struct ContactsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var contacts: [ContactInfo] = []
    @State private var isLoading = true
    @State private var searchText = ""

    private var filtered: [ContactInfo] {
        if searchText.isEmpty { return contacts }
        let q = searchText.lowercased()
        return contacts.filter {
            $0.nickname.lowercased().contains(q) ||
            ($0.firstName?.lowercased().contains(q) ?? false) ||
            ($0.lastName?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        ZStack {
            Color.bgApp.ignoresSafeArea()

            if isLoading {
                ProgressView()
            } else {
                VStack(spacing: 0) {
                    SearchBar(text: $searchText, placeholder: "Поиск контактов...")
                        .padding(.horizontal, 14).padding(.vertical, 8)

                    if filtered.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "person.2")
                                .font(.system(size: 40))
                                .foregroundColor(.textTertiary)
                            Text(contacts.isEmpty ? "Нет контактов" : "Не найдено")
                                .font(.system(size: 15))
                                .foregroundColor(.textSecondary)
                        }
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(filtered) { contact in
                                    HStack(spacing: 12) {
                                        AvatarView(
                                            url: contact.avatar.flatMap { URL(string: ($0.hasPrefix("http") ? $0 : Config.baseURL + $0)) },
                                            initials: String(contact.nickname.prefix(1)).uppercased(),
                                            size: 44, isOnline: contact.isOnline, id: contact.id
                                        )

                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 4) {
                                                Text(contact.displayName)
                                                    .font(.system(size: 15, weight: .medium))
                                                    .foregroundColor(.textPrimary)
                                                if contact.isMutual {
                                                    Image(systemName: "arrow.left.arrow.right")
                                                        .font(.system(size: 10))
                                                        .foregroundColor(.h2vAccent)
                                                }
                                            }
                                            if contact.isOnline {
                                                Text("онлайн").font(.system(size: 12)).foregroundColor(.success)
                                            } else {
                                                Text(DateHelper.lastSeen(contact.lastOnline))
                                                    .font(.system(size: 12)).foregroundColor(.textSecondary)
                                            }
                                        }

                                        Spacer()

                                        Button {
                                            Task {
                                                try? await APIClient.shared.removeContact(userId: contact.id)
                                                contacts.removeAll { $0.id == contact.id }
                                            }
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 12))
                                                .foregroundColor(.textTertiary)
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                }
                            }
                            .cardBackground(radius: 16)
                            .padding(16)
                        }
                    }
                }
            }
        }
        .navigationTitle("Контакты")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Закрыть") { dismiss() }.foregroundColor(.textSecondary)
            }
        }
        .onAppear { load() }
    }

    private func load() {
        Task {
            do { contacts = try await APIClient.shared.getContacts() } catch {}
            isLoading = false
        }
    }
}

// MARK: - User Profile View (Other user)

struct UserProfileView: View {
    let user: User
    var chatId: String? = nil
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var isContact = false
    @State private var isBlocked = false
    @State private var activeTab: SharedMediaTab = .media
    @State private var mediaMessages: [Message] = []
    @State private var fileMessages: [Message] = []
    @State private var voiceMessages: [Message] = []
    @State private var isLoadingMedia = false
    @State private var mediaViewerCtx: MediaViewerContext?

    enum SharedMediaTab: String, CaseIterable {
        case media = "Медиа"
        case files = "Файлы"
        case voice = "Голосовые"
    }

    var body: some View {
        ZStack {
            Color.bgApp.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    AvatarView(url: user.avatarURL, initials: user.initials,
                               size: 96, isOnline: appState.isUserOnline(user.id), id: user.id)
                        .padding(.top, 20)

                    VStack(spacing: 4) {
                        Text(user.displayName)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.textPrimary)
                        Text("@\(user.nickname)")
                            .font(.system(size: 14))
                            .foregroundColor(.textSecondary)

                        if appState.isUserOnline(user.id) {
                            Text("онлайн").font(.system(size: 13)).foregroundColor(.success)
                        } else {
                            Text(DateHelper.lastSeen(user.lastOnline))
                                .font(.system(size: 13)).foregroundColor(.textSecondary)
                        }

                        if let bio = user.bio, !bio.isEmpty {
                            Text(bio)
                                .font(.system(size: 14))
                                .foregroundColor(.textSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.top, 8)
                        }
                    }

                    actionsCard
                    sharedMediaSection
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Закрыть") { dismiss() }.foregroundColor(.textSecondary)
            }
        }
        .fullScreenCover(item: $mediaViewerCtx) { ctx in
            MediaViewerView(urls: ctx.urls, startIndex: ctx.startIndex)
        }
        .task { await loadSharedMedia() }
    }

    private func loadSharedMedia() async {
        guard let chatId else { return }
        isLoadingMedia = true
        async let mediaReq = APIClient.shared.getSharedMedia(chatId: chatId, type: "IMAGE")
        async let fileReq = APIClient.shared.getSharedMedia(chatId: chatId, type: "FILE")
        async let voiceReq = APIClient.shared.getSharedMedia(chatId: chatId, type: "AUDIO")
        do {
            let (m, f, v) = try await (mediaReq, fileReq, voiceReq)
            mediaMessages = m.messages
            let videoData = try? await APIClient.shared.getSharedMedia(chatId: chatId, type: "VIDEO")
            if let vids = videoData?.messages { mediaMessages += vids }
            mediaMessages.sort { ($0.createdAt) > ($1.createdAt) }
            fileMessages = f.messages
            voiceMessages = v.messages
        } catch {}
        isLoadingMedia = false
    }

    private var actionsCard: some View {
        VStack(spacing: 0) {
            Button {
                Task {
                    if isContact {
                        try? await APIClient.shared.removeContact(userId: user.id)
                        isContact = false
                    } else {
                        try? await APIClient.shared.addContact(userId: user.id)
                        isContact = true
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isContact ? "person.badge.minus" : "person.badge.plus")
                    Text(isContact ? "Удалить из контактов" : "Добавить в контакты")
                }
                .font(.system(size: 15)).foregroundColor(.h2vAccent)
                .frame(maxWidth: .infinity).padding(.vertical, 13)
            }

            Divider().background(Color.borderPrimary)

            Button {
                Task {
                    if isBlocked {
                        try? await APIClient.shared.unblockUser(id: user.id)
                        isBlocked = false
                    } else {
                        try? await APIClient.shared.blockUser(id: user.id)
                        isBlocked = true
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised")
                    Text(isBlocked ? "Разблокировать" : "Заблокировать")
                }
                .font(.system(size: 15)).foregroundColor(.danger)
                .frame(maxWidth: .infinity).padding(.vertical, 13)
            }
        }
        .cardBackground(radius: 16)
        .padding(.horizontal, 16)
    }

    // MARK: - Shared Media

    private var sharedMediaSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                ForEach(SharedMediaTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { activeTab = tab }
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: activeTab == tab ? .semibold : .regular))
                            .foregroundColor(activeTab == tab ? .h2vAccent : .textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(activeTab == tab ? Color.h2vAccent.opacity(0.1) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
            .padding(3)
            .cardBackground(radius: 12)
            .padding(.horizontal, 16)

            Group {
                switch activeTab {
                case .media: mediaGrid
                case .files: filesList
                case .voice: voiceList
                }
            }
            .animation(.easeInOut(duration: 0.2), value: activeTab)
            .padding(.horizontal, 16)
        }
    }

    private var mediaGrid: some View {
        Group {
            if isLoadingMedia {
                ProgressView().padding(.top, 30)
            } else if mediaMessages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 32))
                        .foregroundColor(.textTertiary.opacity(0.5))
                    Text("Нет медиа").font(.system(size: 13)).foregroundColor(.textTertiary)
                }
                .padding(.top, 30)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 2),
                                    GridItem(.flexible(), spacing: 2),
                                    GridItem(.flexible(), spacing: 2)], spacing: 2) {
                    ForEach(mediaMessages) { msg in
                        if let url = msg.mediaFullURL {
                            ZStack {
                                CachedAsyncImage(url: url) { img in
                                    img.resizable().scaledToFill()
                                } placeholder: {
                                    Color.bgCard
                                }
                                .frame(height: 110).clipped()

                                if msg.type == .video {
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 28))
                                        .foregroundColor(.white.opacity(0.9))
                                        .shadow(radius: 3)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .contentShape(Rectangle())
                            .onTapGesture { openMediaViewer(tapped: url) }
                        }
                    }
                }
            }
        }
    }

    private func openMediaViewer(tapped: URL) {
        let allURLs = mediaMessages.compactMap { $0.mediaFullURL }
        let idx = allURLs.firstIndex(of: tapped) ?? 0
        mediaViewerCtx = MediaViewerContext(urls: allURLs, startIndex: idx)
    }

    private var filesList: some View {
        Group {
            if isLoadingMedia {
                ProgressView().padding(.top, 30)
            } else if fileMessages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 32))
                        .foregroundColor(.textTertiary.opacity(0.5))
                    Text("Нет файлов").font(.system(size: 13)).foregroundColor(.textTertiary)
                }
                .padding(.top, 30)
            } else {
                VStack(spacing: 0) {
                    ForEach(fileMessages) { msg in
                        HStack(spacing: 10) {
                            Image(systemName: fileIcon(msg.mediaName))
                                .font(.system(size: 20)).foregroundColor(.h2vAccent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(msg.mediaName ?? "Файл")
                                    .font(.system(size: 14, weight: .medium)).foregroundColor(.textPrimary).lineLimit(1)
                                HStack(spacing: 6) {
                                    if let size = msg.mediaSize {
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                            .font(.system(size: 12)).foregroundColor(.textTertiary)
                                    }
                                    Text(DateHelper.chatRow(msg.createdAt))
                                        .font(.system(size: 11)).foregroundColor(.textTertiary)
                                }
                            }
                            Spacer()
                            if let url = msg.mediaFullURL {
                                Button {
                                    Task {
                                        if let (data, _) = try? await APIClient.shared.downloadData(from: url) {
                                            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(msg.mediaName ?? "file")
                                            try? data.write(to: tempURL)
                                            await MainActor.run {
                                                let av = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
                                                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                                                   let vc = scene.windows.first?.rootViewController {
                                                    vc.present(av, animated: true)
                                                }
                                            }
                                        }
                                    }
                                } label: {
                                    Image(systemName: "arrow.down.circle")
                                        .font(.system(size: 18))
                                        .foregroundColor(.h2vAccent.opacity(0.7))
                                }
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        if msg.id != fileMessages.last?.id {
                            Divider().background(Color.borderPrimary).padding(.leading, 44)
                        }
                    }
                }
                .cardBackground(radius: 12)
            }
        }
    }

    private func fileIcon(_ name: String?) -> String {
        guard let ext = name?.split(separator: ".").last?.lowercased() else { return "doc.fill" }
        switch ext {
        case "pdf": return "doc.richtext.fill"
        case "zip", "rar", "7z": return "doc.zipper"
        case "doc", "docx": return "doc.text.fill"
        case "xls", "xlsx": return "tablecells.fill"
        case "ppt", "pptx": return "rectangle.fill.on.rectangle.fill"
        default: return "doc.fill"
        }
    }

    private var voiceList: some View {
        Group {
            if isLoadingMedia {
                ProgressView().padding(.top, 30)
            } else if voiceMessages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "mic")
                        .font(.system(size: 32))
                        .foregroundColor(.textTertiary.opacity(0.5))
                    Text("Нет голосовых").font(.system(size: 13)).foregroundColor(.textTertiary)
                }
                .padding(.top, 30)
            } else {
                VStack(spacing: 0) {
                    ForEach(voiceMessages) { msg in
                        HStack(spacing: 10) {
                            Button {
                                if let url = msg.mediaFullURL { AudioPlayerManager.shared.play(url: url) }
                            } label: {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.white)
                                    .frame(width: 32, height: 32)
                                    .background(LinearGradient.accentGradient, in: Circle())
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(msg.sender?.displayName ?? "")
                                    .font(.system(size: 13, weight: .medium)).foregroundColor(.textPrimary)
                                Text(DateHelper.chatRow(msg.createdAt))
                                    .font(.system(size: 11)).foregroundColor(.textTertiary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        if msg.id != voiceMessages.last?.id {
                            Divider().background(Color.borderPrimary).padding(.leading, 52)
                        }
                    }
                }
                .cardBackground(radius: 12)
            }
        }
    }

}

// MARK: - ContactInfo displayName helper

extension ContactInfo {
    var displayName: String {
        let parts = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
        return parts.isEmpty ? nickname : parts
    }
}
