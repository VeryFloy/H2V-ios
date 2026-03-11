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
    /// chatId → unread count
    @Published var unreadCounts: [String: Int] = [:]
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

    var currentUserId: String?

    func handleWSEvent(_ event: WSEvent, currentUserId: String?) {
        self.currentUserId = currentUserId
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
            } else {
                // New chat not yet in the list — refresh
                loadChats(refresh: true)
            }
            // Increment unread if message is from another user
            if msg.sender.id != currentUserId {
                unreadCounts[cid, default: 0] += 1
            }
            if let uid = msg.sender.id as String? {
                typingPerChat[cid]?.removeValue(forKey: uid)
            }

        case "chat:new":
            if let chat = event.decode(as: Chat.self) {
                if !chats.contains(where: { $0.id == chat.id }) {
                    chats.insert(chat, at: 0)
                }
            }

        case "chat:deleted":
            if let cid = event.chatId { chats.removeAll { $0.id == cid } }

        case "chat:updated":
            guard let cid = event.chatId ?? (event.rawPayload["id"] as? String),
                  let i = chats.firstIndex(where: { $0.id == cid }) else { return }
            let p = event.rawPayload
            let updated = Chat(
                id: chats[i].id,
                type: chats[i].type,
                name: (p["name"] as? String) ?? chats[i].name,
                avatar: (p["avatar"] as? String) ?? chats[i].avatar,
                description: (p["description"] as? String) ?? chats[i].description,
                createdAt: chats[i].createdAt,
                updatedAt: chats[i].updatedAt,
                members: chats[i].members,
                messages: chats[i].messages
            )
            chats[i] = updated

        case "chat:member-left":
            guard let cid = event.chatId,
                  let uid = event.userId,
                  let i = chats.firstIndex(where: { $0.id == cid }) else { return }
            var updated = chats[i]
            let newMembers = updated.members.filter { $0.userId != uid }
            updated = Chat(id: updated.id, type: updated.type, name: updated.name,
                           avatar: updated.avatar, description: updated.description,
                           createdAt: updated.createdAt, updatedAt: updated.updatedAt,
                           members: newMembers, messages: updated.messages)
            chats[i] = updated

        case "message:deleted":
            // If the deleted message was the preview of a chat row, clear it
            guard let msgId = event.messageId else { return }
            if let i = chats.firstIndex(where: { $0.lastMessage?.id == msgId }) {
                let c = chats[i]
                chats[i] = Chat(id: c.id, type: c.type, name: c.name, avatar: c.avatar,
                                description: c.description, createdAt: c.createdAt,
                                updatedAt: c.updatedAt, members: c.members, messages: nil)
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
    /// Chat ID waiting to be navigated to once chats are loaded
    @State private var pendingNavigateChatId: String? = nil
    @State private var wsSubscriberID: UUID? = nil

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
                Task { vm.loadChats(refresh: true) }
            }
        }
        // When chats reload, check if there's a pending navigation
        .onChange(of: vm.chats) { _, chats in
            if let chatId = pendingNavigateChatId,
               let chat = chats.first(where: { $0.id == chatId }) {
                navPath.append(chat)
                pendingNavigateChatId = nil
            }
        }
        // Handle notification tap → navigate to the target chat
        .onChange(of: appState.pendingOpenChatId) { _, chatId in
            guard let chatId else { return }
            appState.pendingOpenChatId = nil
            if let chat = vm.chats.first(where: { $0.id == chatId }) {
                navPath.append(chat)
            } else {
                pendingNavigateChatId = chatId
                vm.loadChats(refresh: true)
            }
        }
        .onAppear {
            vm.loadChats(refresh: true)
            let uid = appState.currentUser?.id
            wsSubscriberID = WebSocketClient.shared.subscribe { [weak vm] event in
                vm?.handleWSEvent(event, currentUserId: uid)
            }
        }
        .onDisappear {
            if let id = wsSubscriberID {
                WebSocketClient.shared.unsubscribe(id)
                wsSubscriberID = nil
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

                    let unread = vm.unreadCounts[chat.id] ?? 0

                    ChatRowView(chat: chat, currentUserId: uid, isOnline: isOnline,
                                isMuted: isMuted, typingLabel: typingText,
                                groupOnlineCount: onlineCount, unreadCount: unread)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            vm.unreadCounts[chat.id] = 0
                            navPath.append(chat)
                        }
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
    var unreadCount: Int = 0

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
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(timeStr)
                            .font(.system(size: 11))
                            .foregroundStyle(unreadCount > 0 ? Color(hex: "5E8CFF") : Color.textTertiary)
                        if unreadCount > 0 && !isMuted {
                            Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(hex: "5E8CFF"), in: Capsule())
                        } else if unreadCount > 0 && isMuted {
                            Circle()
                                .fill(Color.textTertiary)
                                .frame(width: 8, height: 8)
                        }
                    }
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
