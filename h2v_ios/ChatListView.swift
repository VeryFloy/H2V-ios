import SwiftUI

// MARK: - ChatListViewModel

@MainActor
class ChatListViewModel: ObservableObject {
    @Published var chats: [Chat] = []
    @Published var isLoading = false
    @Published var errorMsg: String?
    @Published var mutedIds: Set<String> = MuteManager.shared.mutedIds
    /// chatId → [userId: nickname] — who's currently typing in each chat
    @Published var typingPerChat: [String: [String: String]] = [:]
    private(set) var hasMore = true
    private var nextCursor: String? = nil

    func loadChats(refresh: Bool = false) {
        guard !isLoading else { return }
        if refresh { nextCursor = nil; hasMore = true }
        guard hasMore else { return }
        isLoading = true
        let cursor = nextCursor
        Task {
            do {
                let result = try await APIClient.shared.getChats(cursor: cursor, limit: 30)
                if refresh { chats = result.chats } else { chats.append(contentsOf: result.chats) }
                nextCursor = result.nextCursor
                hasMore = result.nextCursor != nil
            } catch {
                errorMsg = error.localizedDescription
            }
            isLoading = false
        }
    }

    func loadMore() {
        guard hasMore && !isLoading else { return }
        loadChats()
    }

    func leaveChat(_ chatId: String) {
        Task {
            try? await APIClient.shared.leaveChat(chatId: chatId)
            chats.removeAll { $0.id == chatId }
        }
    }

    func toggleMute(_ chatId: String) {
        MuteManager.shared.toggle(chatId)
        mutedIds = MuteManager.shared.mutedIds
    }

    /// Typing label for a specific chat in the list
    func typingLabel(for chatId: String) -> String? {
        guard let typers = typingPerChat[chatId], !typers.isEmpty else { return nil }
        let names = Array(typers.values)
        switch names.count {
        case 1:  return "\(names[0]) печатает..."
        case 2:  return "\(names[0]) и \(names[1]) печатают..."
        default: return "\(names.count) печатают..."
        }
    }

    func handleWSEvent(_ event: WSEvent, currentUserId: String?) {
        switch event.type {
        case "message:new", "new_message":
            guard let msg = event.decodeMessage() else { return }
            let cid = msg.chatId ?? event.chatId ?? ""
            if let i = chats.firstIndex(where: { $0.id == cid }) {
                var updated = chats[i]
                updated = Chat(id: updated.id, type: updated.type, name: updated.name,
                               avatar: updated.avatar, description: updated.description,
                               createdAt: updated.createdAt, updatedAt: updated.updatedAt,
                               members: updated.members, messages: [msg])
                chats.remove(at: i)
                chats.insert(updated, at: 0)
            }
            // Clear typing for this user+chat (they sent a message)
            if let uid = msg.sender.id as String? {
                typingPerChat[cid]?.removeValue(forKey: uid)
            }

        case "typing:started", "typing:start":
            guard let uid = event.userId, uid != currentUserId else { return }
            guard let cid = event.chatId else { return }
            let nick = event.rawPayload["nickname"] as? String
                ?? chats.first(where: { $0.id == cid })?
                    .members.first(where: { $0.userId == uid })?.user.nickname
                ?? "..."
            if typingPerChat[cid] == nil { typingPerChat[cid] = [:] }
            typingPerChat[cid]?[uid] = nick
            // Auto-clear after 5s
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                typingPerChat[cid]?.removeValue(forKey: uid)
                if typingPerChat[cid]?.isEmpty == true { typingPerChat.removeValue(forKey: cid) }
            }

        case "typing:stopped", "typing:stop":
            guard let uid = event.userId, let cid = event.chatId else { return }
            typingPerChat[cid]?.removeValue(forKey: uid)
            if typingPerChat[cid]?.isEmpty == true { typingPerChat.removeValue(forKey: cid) }

        default: break
        }
    }
}

// MARK: - ChatListView

struct ChatListView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = ChatListViewModel()
    @Binding var showTabBar: Bool
    @State private var searchText = ""
    @State private var showNewChat = false
    @State private var showNewGroup = false
    @State private var navPath = NavigationPath()

    private var filtered: [Chat] {
        let uid = appState.currentUser?.id ?? ""
        guard !searchText.isEmpty else { return vm.chats }
        return vm.chats.filter { $0.displayName(currentUserId: uid).localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            ZStack {
                Color.appBg.ignoresSafeArea()
                VStack(spacing: 0) {
                    headerSection
                    searchSection
                    if vm.isLoading && vm.chats.isEmpty {
                        Spacer()
                        ProgressView().tint(Color.white.opacity(0.4))
                        Spacer()
                    } else if vm.chats.isEmpty {
                        emptyState
                    } else {
                        chatList
                    }
                }
            }
            .navigationDestination(for: Chat.self) { chat in
                ChatView(chat: chat)
            }
        }
        .onChange(of: navPath) { _, path in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                showTabBar = path.isEmpty
            }
            if path.isEmpty {
                // Re-establish WS handler and refresh list on return from chat
                WebSocketClient.shared.onEvent = { [weak vm] event in
                    Task { @MainActor in
                        vm?.handleWSEvent(event, currentUserId: appState.currentUser?.id)
                        appState.handlePresence(event: event)
                        appState.handleMessageNotification(event: event)
                    }
                }
                Task { vm.loadChats(refresh: true) }
            }
        }
        .onAppear {
            vm.loadChats(refresh: true)
            WebSocketClient.shared.onEvent = { [weak vm] event in
                Task { @MainActor in
                    vm?.handleWSEvent(event, currentUserId: appState.currentUser?.id)
                    appState.handlePresence(event: event)
                    appState.handleMessageNotification(event: event)
                }
            }
        }
        .sheet(isPresented: $showNewChat) {
            NewChatView(onCreated: { chat in
                showNewChat = false
                navPath.append(chat)
            })
        }
        .sheet(isPresented: $showNewGroup) {
            CreateGroupView(onCreated: { chat in
                showNewGroup = false
                navPath.append(chat)
            })
        }
    }

    // MARK: Header

    private var headerSection: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Сообщения")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .tracking(-0.8)
            }
            Spacer()
            Menu {
                Button {
                    showNewChat = true
                } label: {
                    Label("Личный чат", systemImage: "person.fill")
                }
                Button {
                    showNewGroup = true
                } label: {
                    Label("Создать группу", systemImage: "person.3.fill")
                }
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 38, height: 38)
                    .glassBackground(cornerRadius: 19, opacity: 0.45)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var searchSection: some View {
        GlassSearchBar(text: $searchText, placeholder: "Поиск")
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
    }

    // MARK: Chat List

    private var chatList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filtered) { chat in
                    let uid = appState.currentUser?.id ?? ""
                    let other = chat.otherUser(currentUserId: uid)
                    let isOnline = other.map { appState.onlineUserIds.contains($0.id) } ?? false
                    let isMuted = vm.mutedIds.contains(chat.id)

                    let typingText = vm.typingLabel(for: chat.id)
                    let onlineCount = chat.type == "GROUP"
                        ? chat.members.filter { appState.onlineUserIds.contains($0.userId) }.count
                        : 0

                    ChatRowView(chat: chat, currentUserId: uid, isOnline: isOnline,
                                isMuted: isMuted, typingLabel: typingText, groupOnlineCount: onlineCount)
                        .contentShape(Rectangle())
                        .onTapGesture { navPath.append(chat) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { vm.leaveChat(chat.id) } label: {
                                Label("Покинуть", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                            Button {
                                vm.toggleMute(chat.id)
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            } label: {
                                Label(isMuted ? "Включить" : "Заглушить",
                                      systemImage: isMuted ? "bell.fill" : "bell.slash.fill")
                            }
                            .tint(isMuted ? Color(hex: "30D158") : Color(hex: "FF9500"))
                        }
                        .contextMenu {
                            Button {
                                vm.toggleMute(chat.id)
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            } label: {
                                Label(isMuted ? "Включить звук" : "Заглушить",
                                      systemImage: isMuted ? "bell.fill" : "bell.slash.fill")
                            }
                            Button(role: .destructive) { vm.leaveChat(chat.id) } label: {
                                Label("Покинуть чат", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        }
                    Divider()
                        .background(Color.white.opacity(0.04))
                        .padding(.leading, 72)
                }
                if vm.hasMore {
                    ProgressView()
                        .tint(Color.white.opacity(0.3))
                        .padding()
                        .onAppear { vm.loadMore() }
                }
            }
            .padding(.bottom, 100)
        }
        .scrollIndicators(.hidden)
        .refreshable { vm.loadChats(refresh: true) }
    }

    // MARK: Empty State

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(Color.white.opacity(0.12))
            Text("Нет чатов")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.25))
            Text("Нажмите ✏️ чтобы начать переписку")
                .font(.system(size: 14))
                .foregroundStyle(Color.white.opacity(0.15))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - ChatRowView

struct ChatRowView: View {
    let chat: Chat
    let currentUserId: String
    let isOnline: Bool
    var isMuted: Bool = false
    var typingLabel: String? = nil
    var groupOnlineCount: Int = 0

    private var isGroup: Bool { chat.type == "GROUP" }

    private var lastMsgText: String {
        guard let m = chat.lastMessage else { return isGroup ? "Группа создана" : "Начните переписку" }
        let t = m.messageType
        if t == .image { return "📷 Фото" }
        if t == .file  { return "📎 Файл" }
        let prefix = isGroup ? "\(m.sender.nickname): " : ""
        return prefix + (m.text ?? "")
    }

    private var timeStr: String {
        guard let m = chat.lastMessage else { return "" }
        return MessageTime.rowTime(from: m.createdAt)
    }

    private var color: Color { avatarColor(for: chat.id) }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if isGroup {
                    groupAvatarView
                } else {
                    AvatarView(
                        url: chat.chatAvatarURL(currentUserId: currentUserId),
                        initials: chat.chatInitials(currentUserId: currentUserId),
                        size: 50,
                        isOnline: isOnline,
                        avatarColorOverride: color
                    )
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    HStack(spacing: 5) {
                        Text(chat.displayName(currentUserId: currentUserId))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.textPrimary)
                            .tracking(-0.2)
                            .lineLimit(1)
                        if isGroup {
                            Image(systemName: "person.2.fill")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Color(hex: "5E8CFF").opacity(0.7))
                        }
                        if isMuted {
                            Image(systemName: "bell.slash.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.textTertiary)
                        }
                    }
                    Spacer()
                    Text(timeStr)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textTertiary)
                }
                // Subtitle: typing > last message > online
                HStack(alignment: .center) {
                    if let typing = typingLabel {
                        Text(typing)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.onlineGreen)
                            .lineLimit(1)
                    } else {
                        Text(lastMsgText)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    // Online badge for groups
                    if isGroup && groupOnlineCount > 0 && typingLabel == nil {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(Color.onlineGreen)
                                .frame(width: 6, height: 6)
                            Text("\(groupOnlineCount)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.onlineGreen)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(Color.clear)
        .animation(.easeInOut(duration: 0.2), value: typingLabel)
    }

    private var groupAvatarView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(color.opacity(0.18))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(color.opacity(0.28), lineWidth: 1)
                }
                .frame(width: 50, height: 50)
            Image(systemName: "person.3.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(color)
        }
    }
}

// MARK: - NewChatView

struct NewChatView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let onCreated: (Chat) -> Void

    @State private var searchText = ""
    @State private var users: [User] = []
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                VStack(spacing: 0) {
                    GlassSearchBar(text: $searchText, placeholder: "Найти пользователя")
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                        .onChange(of: searchText) { _, v in searchUsers(v) }

                    if isLoading {
                        Spacer()
                        ProgressView().tint(Color.white.opacity(0.4))
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(users) { user in
                                    UserSearchRow(user: user)
                                        .contentShape(Rectangle())
                                        .onTapGesture { startChat(with: user) }
                                    Divider()
                                        .background(Color.white.opacity(0.05))
                                        .padding(.leading, 68)
                                }
                            }
                            .padding(.bottom, 40)
                        }
                        .scrollIndicators(.hidden)
                    }
                }
            }
            .navigationTitle("Новый чат")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.appBg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                        .foregroundStyle(Color.white.opacity(0.6))
                }
            }
        }
    }

    private func searchUsers(_ q: String) {
        guard q.count >= 2 else { users = []; return }
        isLoading = true
        Task {
            let result = try? await APIClient.shared.searchUsers(query: q)
            users = (result ?? []).filter { $0.id != appState.currentUser?.id }
            isLoading = false
        }
    }

    private func startChat(with user: User) {
        Task {
            if let chat = try? await APIClient.shared.createDirectChat(targetUserId: user.id) {
                onCreated(chat)
            }
        }
    }
}

struct UserSearchRow: View {
    let user: User
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(
                url: user.avatarURL,
                initials: user.initials,
                size: 44,
                isOnline: user.isOnline ?? false,
                avatarColorOverride: avatarColor(for: user.id)
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(user.nickname)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text("@\(user.nickname)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(hex: "5E8CFF").opacity(0.8))
                if let bio = user.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textSecondary)
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color(hex: "5E8CFF"))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}
