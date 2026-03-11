import SwiftUI
import PhotosUI

// MARK: - ProfileViewModel

@MainActor
class ProfileViewModel: ObservableObject {
    @Published var nickname = ""
    @Published var bio = ""
    @Published var avatarItem: PhotosPickerItem?
    @Published var showEditProfile = false
    @Published var isSaving = false
    @Published var errorMsg: String?
    @Published var saveSuccess = false

    func populate(from user: User) {
        nickname = user.nickname
        bio = user.bio ?? ""
    }

    func save(appState: AppState) {
        let trimmedNick = nickname.trimmingCharacters(in: .whitespaces)
        guard trimmedNick.count >= 3 else {
            errorMsg = "Юзернейм — минимум 3 символа"
            return
        }
        guard trimmedNick.range(of: "^[a-zA-Z0-9_]+$", options: .regularExpression) != nil else {
            errorMsg = "Юзернейм: только a-z, 0-9, _"
            return
        }
        isSaving = true
        errorMsg = nil
        Task {
            do {
                let updated = try await APIClient.shared.updateMe(
                    nickname: trimmedNick,
                    bio: bio.isEmpty ? nil : bio
                )
                appState.currentUser = updated
                saveSuccess = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.saveSuccess = false
                }
            } catch {
                errorMsg = error.localizedDescription
            }
            isSaving = false
        }
    }

    func uploadAvatar(appState: AppState) {
        guard let item = avatarItem else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else { return }
            do {
                let result = try await APIClient.shared.uploadFile(data: data, filename: "avatar.jpg", mimeType: "image/jpeg")
                let updated = try await APIClient.shared.updateMe(avatar: result.url)
                appState.currentUser = updated
            } catch { errorMsg = error.localizedDescription }
            avatarItem = nil
        }
    }

    func deleteAccount(appState: AppState) {
        Task {
            try? await APIClient.shared.deleteAccount()
            appState.signOut()
        }
    }
}

// MARK: - ProfileView

struct ProfileView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = ProfileViewModel()
    @State private var showDeleteAlert = false
    @State private var showAvatarPicker = false
    @State private var showPremium = false
    @State private var navPath = NavigationPath()

    private var user: User? { appState.currentUser }

    // Settings structure — each item now has a destination
    private var settingsSections: [(title: String, items: [ProfileSettingsItemConfig])] {
        [
            ("Аккаунт", [
                .init(icon: "lock.fill",        color: Color(hex: "5E8CFF"), label: "Конфиденциальность", value: "Высокая",   dest: .privacy),
                .init(icon: "bell.fill",         color: Color(hex: "FF9500"), label: "Уведомления",        value: statusNotif, dest: .notifications),
                .init(icon: "iphone",            color: Color(hex: "30D158"), label: "Устройства",         value: "1 активное", dest: .devices),
            ]),
            ("Внешний вид", [
                .init(icon: "moon.fill",         color: Color(hex: "BF5AF2"), label: "Тема",              value: currentThemeLabel, dest: .appearance),
                .init(icon: "bubble.left.fill",  color: Color(hex: "5E8CFF"), label: "Пузыри чата",       value: "Стекло",    dest: .chatBubbles),
            ]),
            ("H2V", [
                .init(icon: "star.fill",         color: Color(hex: "FFD60A"), label: "H2V Premium",        value: "Попробовать", dest: .premium),
                .init(icon: "shield.fill",       color: Color(hex: "30D158"), label: "Приватность данных", value: "Включена",  dest: .dataPrivacy),
                .init(icon: "info.circle.fill",  color: Color.white.opacity(0.35), label: "О приложении", value: appVersion, dest: .about),
            ]),
        ]
    }

    private var statusNotif: String {
        NotificationManager.shared.isAuthorized ? "Включены" : "Выключены"
    }

    @AppStorage("h2v.colorScheme") private var colorScheme = "dark"
    private var currentThemeLabel: String {
        switch colorScheme {
        case "light":  return "Светлая"
        case "system": return "Системная"
        default:       return "Тёмная"
        }
    }
    private var appVersion: String {
        "v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1")"
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            ZStack {
                Color.appBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        profileHeader
                        Divider().background(Color.white.opacity(0.07))
                        settingsBody
                        dangerZone
                        Spacer().frame(height: 120)
                    }
                }
                .scrollIndicators(.hidden)
            }
            .navigationBarHidden(true)
            .navigationDestination(for: ProfileDestination.self) { dest in
                destinationView(dest)
            }
        }
        .onAppear { user.map { vm.populate(from: $0) } }
        .onChange(of: vm.avatarItem) { _, item in if item != nil { vm.uploadAvatar(appState: appState) } }
        .photosPicker(isPresented: $showAvatarPicker, selection: $vm.avatarItem, matching: .images)
        .sheet(isPresented: $showPremium) { PremiumView() }
        .sheet(isPresented: $vm.showEditProfile) {
            EditProfileSheet(vm: vm, appState: appState)
        }
        .alert("Удалить аккаунт?", isPresented: $showDeleteAlert) {
            Button("Удалить", role: .destructive) { vm.deleteAccount(appState: appState) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Это действие необратимо. Все данные будут удалены.")
        }
    }

    // MARK: Destination Router

    @ViewBuilder
    private func destinationView(_ dest: ProfileDestination) -> some View {
        switch dest {
        case .privacy:       PrivacySettingsView().environmentObject(appState)
        case .notifications: NotificationSettingsView()
        case .devices:       DevicesView()
        case .appearance:    AppearanceSettingsView()
        case .chatBubbles:   ChatBubblesView()
        case .premium:       PremiumView()
        case .dataPrivacy:   DataPrivacyView()
        case .about:         AboutView()
        }
    }

    // MARK: Profile Header

    private var profileHeader: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let url = user?.avatarURL {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let img): img.resizable().scaledToFill()
                                default: avatarInitialsContent
                                }
                            }
                        } else {
                            avatarInitialsContent
                        }
                    }
                    .frame(width: 62, height: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.glassBorder, lineWidth: 0.5)
                    }
                    .onTapGesture { showAvatarPicker = true }

                    Circle()
                        .fill(Color.onlineGreen)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color.appBg, lineWidth: 2))
                        .offset(x: 3, y: 3)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(user?.nickname ?? "")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.textPrimary)
                        .tracking(-0.5)

                    HStack(spacing: 4) {
                        Text("@\(user?.nickname ?? "")")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(hex: "5E8CFF"))
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(hex: "5E8CFF").opacity(0.5))
                    }
                    .onTapGesture {
                        UIPasteboard.general.string = "@\(user?.nickname ?? "")"
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }

                    if let bio = user?.bio, !bio.isEmpty {
                        Text(bio)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.textTertiary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                Button {
                    vm.populate(from: user!)
                    vm.showEditProfile = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Изменить")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Color.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassBackground(cornerRadius: 10, opacity: 0.45)
                }
                .disabled(user == nil)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            // Stats bar
            HStack {
                Spacer()
                statItem(value: "\(appState.onlineUserIds.count)", label: "Онлайн")
                Spacer()
                Rectangle().frame(width: 0.5, height: 28).foregroundStyle(Color.glassBorder)
                Spacer()
                statItem(value: NotificationManager.shared.isAuthorized ? "Вкл" : "Выкл", label: "Уведомления")
                Spacer()
                Rectangle().frame(width: 0.5, height: 28).foregroundStyle(Color.glassBorder)
                Spacer()
                statItem(value: "E2E", label: "Шифрование")
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.glassSurface.opacity(0.2))
            .overlay(alignment: .top) {
                Rectangle().frame(height: 0.5).foregroundStyle(Color.glassBorder)
            }
        }
    }

    private var avatarInitialsContent: some View {
        ZStack {
            avatarColor(for: user?.id ?? "").opacity(0.15)
            Text(user?.initials ?? "")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(avatarColor(for: user?.id ?? ""))
        }
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.textPrimary)
                .tracking(-0.3)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color.textTertiary)
        }
    }

    // MARK: Settings

    private var settingsBody: some View {
        VStack(spacing: 20) {
            ForEach(settingsSections, id: \.title) { section in
                buildSection(title: section.title, items: section.items)
            }
        }
        .padding(.top, 20)
    }

    private func buildSection(title: String, items: [ProfileSettingsItemConfig]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title).padding(.horizontal, 24)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.label) { idx, item in
                    Button {
                        if item.dest == .premium { showPremium = true }
                        else { navPath.append(item.dest) }
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(item.color.opacity(0.18))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(item.color.opacity(0.3), lineWidth: 0.5)
                                    }
                                    .frame(width: 32, height: 32)
                                Image(systemName: item.icon)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(item.color)
                            }
                            Text(item.label)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.88))
                                .tracking(-0.1)
                            Spacer()
                            Text(item.value)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.white.opacity(0.25))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.18))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if idx < items.count - 1 {
                        Divider()
                            .background(Color.white.opacity(0.055))
                            .padding(.leading, 56)
                    }
                }
            }
            .glassBackground(cornerRadius: 18, opacity: 0.38)
            .padding(.horizontal, 20)
        }
    }

    // MARK: Danger Zone

    private var dangerZone: some View {
        VStack(spacing: 10) {
            Button { appState.signOut() } label: {
                Text("Выйти из аккаунта")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.dangerRed)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.dangerRed.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.dangerRed.opacity(0.2), lineWidth: 0.5)
                    }
            }
            Button(role: .destructive) { showDeleteAlert = true } label: {
                Text("Удалить аккаунт")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white.opacity(0.2))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
    }
}

// MARK: - Settings Item Config

struct ProfileSettingsItemConfig {
    let icon: String
    let color: Color
    let label: String
    let value: String
    let dest: ProfileDestination
}

// MARK: - Edit Profile Sheet

struct EditProfileSheet: View {
    @ObservedObject var vm: ProfileViewModel
    var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: EditField?

    enum EditField { case nickname, bio }

    private var nicknameValid: Bool {
        let n = vm.nickname.trimmingCharacters(in: .whitespaces)
        return n.count >= 3 && n.range(of: "^[a-zA-Z0-9_]+$", options: .regularExpression) != nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        // Username field
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "Юзернейм")
                                .padding(.horizontal, 4)
                            HStack(spacing: 0) {
                                Text("@")
                                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color(hex: "5E8CFF"))
                                TextField("username", text: $vm.nickname)
                                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.textPrimary)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .focused($focused, equals: .nickname)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .glassBackground(cornerRadius: 12, opacity: 0.38)

                            // Validation hint
                            HStack(spacing: 6) {
                                if nicknameValid {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.onlineGreen)
                                    Text("Юзернейм свободен (a-z, 0-9, _, мин. 3)")
                                        .foregroundStyle(Color.onlineGreen)
                                } else {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.dangerRed)
                                    Text("Только a-z, 0-9, _, минимум 3 символа")
                                        .foregroundStyle(Color.dangerRed)
                                }
                            }
                            .font(.system(size: 11))
                            .padding(.horizontal, 4)
                            .animation(.easeInOut(duration: 0.15), value: nicknameValid)
                        }
                        .padding(.horizontal, 20)

                        // Bio field
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "О себе")
                                .padding(.horizontal, 4)
                            TextField("Расскажите о себе...", text: $vm.bio, axis: .vertical)
                                .font(.system(size: 15))
                                .foregroundStyle(Color.textPrimary)
                                .lineLimit(1...4)
                                .focused($focused, equals: .bio)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .glassBackground(cornerRadius: 12, opacity: 0.38)

                            Text("\(vm.bio.count)/256")
                                .font(.system(size: 11))
                                .foregroundStyle(vm.bio.count > 256 ? Color.dangerRed : Color.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(.horizontal, 4)
                        }
                        .padding(.horizontal, 20)

                        // Error
                        if let err = vm.errorMsg {
                            HStack(spacing: 8) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Color.dangerRed)
                                Text(err)
                                    .foregroundStyle(Color.dangerRed)
                            }
                            .font(.system(size: 13))
                            .padding(.horizontal, 20)
                        }

                        // Success
                        if vm.saveSuccess {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.onlineGreen)
                                Text("Сохранено!")
                                    .foregroundStyle(Color.onlineGreen)
                            }
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 20)
                            .transition(.scale.combined(with: .opacity))
                        }

                        // Save button
                        Button {
                            vm.save(appState: appState)
                        } label: {
                            HStack(spacing: 8) {
                                if vm.isSaving {
                                    ProgressView().tint(.black).scaleEffect(0.85)
                                }
                                Text(vm.isSaving ? "Сохранение..." : "Сохранить")
                                    .font(.system(size: 16, weight: .bold))
                            }
                            .foregroundStyle(nicknameValid ? .black : Color.textTertiary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(
                                nicknameValid ? Color.white.opacity(0.92) : Color.glassSurface,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.glassBorder, lineWidth: 0.5)
                            }
                            .shadow(color: .white.opacity(nicknameValid ? 0.12 : 0), radius: 12)
                        }
                        .disabled(!nicknameValid || vm.isSaving || vm.bio.count > 256)
                        .padding(.horizontal, 20)

                        infoCard(icon: "at", color: Color(hex: "5E8CFF"),
                                 text: "Юзернейм — это ваш уникальный @адрес. Другие пользователи могут найти вас по нему.\n\nПоле «О себе» видно всем в результатах поиска и в вашем профиле.")
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Редактировать профиль")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.appBg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                        .foregroundStyle(Color.textSecondary)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.saveSuccess)
        .onAppear { focused = .nickname }
    }
}
