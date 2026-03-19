import SwiftUI

// MARK: - Muted Store

final class MutedStore {
    static let shared = MutedStore()
    private let key = "h2v_muted"
    private var ids: Set<String>

    init() {
        if let arr = UserDefaults.standard.array(forKey: key) as? [String] {
            ids = Set(arr)
        } else { ids = [] }
    }

    func isMuted(_ id: String) -> Bool { ids.contains(id) }
    func toggle(_ id: String) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        UserDefaults.standard.set(Array(ids), forKey: key)
    }
}

// MARK: - ChatListViewModel

@MainActor
class ChatListViewModel: ObservableObject {
    @Published var chats: [Chat] = []
    @Published var archivedChats: [Chat] = []
    @Published var isLoading = false
    @Published var searchText = ""
    @Published var searchResults: [User] = []
    @Published var isSearching = false
    @Published var showArchive = false

    private var wsSubscribed = false
    private var searchTask: Task<Void, Never>?

    private func filterSecretChats(_ list: [Chat]) -> [Chat] {
        list.filter { $0.type != .secret || SecretChatSessionStore.shared.isAllowed($0.id) }
    }

    func load() {
        let cached = CacheManager.shared.loadChats()
        if !cached.isEmpty && chats.isEmpty {
            chats = sortedChats(filterSecretChats(cached))
        }
        let cachedArchived = CacheManager.shared.loadArchivedChats()
        if !cachedArchived.isEmpty && archivedChats.isEmpty {
            archivedChats = filterSecretChats(cachedArchived)
        }

        guard !isLoading else { return }
        isLoading = true
        Task {
            do {
                var fetched = filterSecretChats(try await APIClient.shared.getChats().chats)
                for id in recentlyReadChatIds {
                    if let idx = fetched.firstIndex(where: { $0.id == id }) {
                        fetched[idx].unread = 0
                    }
                }
                chats = sortedChats(fetched)
                CacheManager.shared.saveChats(chats)
            } catch {}
            isLoading = false
            loadArchived()
        }
    }

    func loadArchived() {
        Task {
            do {
                let data = try await APIClient.shared.getArchivedChats()
                archivedChats = data.chats
                CacheManager.shared.saveArchivedChats(data.chats)
            } catch {}
        }
    }

    func subscribeWS() {
        guard !wsSubscribed else { return }
        wsSubscribed = true
        WebSocketClient.shared.addListener(id: "chatList") { [weak self] event in
            Task { @MainActor [weak self] in self?.handleEvent(event) }
        }
    }

    func unsubscribeWS() {
        WebSocketClient.shared.removeListener(id: "chatList")
        wsSubscribed = false
    }

    private func handleEvent(_ event: WSEvent) {
        switch event.event {
        case "message:new":
            guard let msg = event.decodeMessage(), let msgChatId = msg.chatId else { return }
            if let idx = chats.firstIndex(where: { $0.id == msgChatId }) {
                chats[idx].lastMessage = msg
                let isActiveChat = activeChatId == msgChatId
                let isMyMessage = msg.sender?.id == currentUserId
                if !isActiveChat && !isMyMessage {
                    chats[idx].unread = (chats[idx].unread ?? 0) + 1
                }
                chats = sortedChats(chats)
            } else {
                Task { await reloadChat(id: msgChatId) }
            }
        case "chat:new":
            if let chat = event.decode(as: Chat.self),
               !chats.contains(where: { $0.id == chat.id }) {
                if chat.type == .secret {
                    SecretChatSessionStore.shared.registerSecretChat(chat.id)
                }
                chats.insert(chat, at: 0)
                chats = sortedChats(chats)
            }
        case "chat:updated":
            if let chat = event.decode(as: Chat.self),
               let idx = chats.firstIndex(where: { $0.id == chat.id }) {
                let unread = chats[idx].unread
                chats[idx] = chat
                chats[idx].unread = unread
            }
        case "chat:deleted":
            if let chatId = event.chatId {
                chats.removeAll { $0.id == chatId }
                archivedChats.removeAll { $0.id == chatId }
            }
        case "message:deleted":
            if let chatId = event.chatId,
               let idx = chats.firstIndex(where: { $0.id == chatId }),
               let newLast = event.payload["newLastMessage"] {
                if let data = try? JSONSerialization.data(withJSONObject: newLast),
                   let msg = try? JSONDecoder().decode(Message.self, from: data) {
                    chats[idx].lastMessage = msg
                }
            }
        case "message:edited":
            if let msg = event.decodeMessage(),
               let idx = chats.firstIndex(where: { $0.id == msg.chatId }),
               chats[idx].lastMessage?.id == msg.id {
                chats[idx].lastMessage = msg
            }
        case "message:read":
            if let chatId = event.chatId,
               let idx = chats.firstIndex(where: { $0.id == chatId }),
               let readBy = event.payload["readBy"] as? String {
                if let myId = currentUserId, readBy == myId {
                    chats[idx].unread = 0
                    recentlyReadChatIds.remove(chatId)
                    CacheManager.shared.saveChats(chats)
                }
            }
        case "draft:updated":
            if let chatId = event.chatId,
               let idx = chats.firstIndex(where: { $0.id == chatId }) {
                let text = event.payload["text"] as? String
                let replyId = event.payload["replyToId"] as? String
                chats[idx].draft = (text != nil && !text!.isEmpty)
                    ? ChatDraft(text: text!, replyToId: replyId) : nil
            }
        default: break
        }
    }

    var currentUserId: String?
    var activeChatId: String?
    private var recentlyReadChatIds: Set<String> = []

    func clearUnread(chatId: String) {
        if let idx = chats.firstIndex(where: { $0.id == chatId }) {
            chats[idx].unread = 0
        }
        recentlyReadChatIds.insert(chatId)
        CacheManager.shared.saveChats(chats)
    }

    private func reloadChat(id: String) async {
        do {
            let chat = try await APIClient.shared.getChat(id: id)
            if !chats.contains(where: { $0.id == chat.id }) {
                chats.insert(chat, at: 0)
                chats = sortedChats(chats)
            }
        } catch {}
    }

    func sortedChats(_ list: [Chat]) -> [Chat] {
        list.sorted { a, b in
            let pinA = a.members.contains(where: { $0.pinnedAt != nil })
            let pinB = b.members.contains(where: { $0.pinnedAt != nil })
            if pinA != pinB { return pinA }
            let dateA = a.lastMessage?.createdAt ?? a.createdAt
            let dateB = b.lastMessage?.createdAt ?? b.createdAt
            return dateA > dateB
        }
    }

    func search(query: String) {
        searchTask?.cancel()
        guard !query.isEmpty else { searchResults = []; isSearching = false; return }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            do { searchResults = try await APIClient.shared.searchUsers(query: query) } catch {}
            isSearching = false
        }
    }

    func pinChat(_ chat: Chat) {
        Task { try? await APIClient.shared.pinChat(id: chat.id, pinned: true); load() }
    }

    func unpinChat(_ chat: Chat) {
        Task { try? await APIClient.shared.pinChat(id: chat.id, pinned: false); load() }
    }

    func muteChat(_ chat: Chat) {
        MutedStore.shared.toggle(chat.id)
        objectWillChange.send()
    }

    func archiveChat(_ chat: Chat) {
        Task {
            try? await APIClient.shared.archiveChat(id: chat.id, archived: true)
            chats.removeAll { $0.id == chat.id }
            archivedChats.append(chat)
        }
    }

    func unarchiveChat(_ chat: Chat) {
        Task {
            try? await APIClient.shared.archiveChat(id: chat.id, archived: false)
            archivedChats.removeAll { $0.id == chat.id }
            chats.insert(chat, at: 0)
            chats = sortedChats(chats)
        }
    }

    func deleteChat(_ chat: Chat) {
        Task {
            if chat.type == .group {
                try? await APIClient.shared.leaveChat(id: chat.id)
            } else {
                try? await APIClient.shared.deleteChat(id: chat.id)
            }
            chats.removeAll { $0.id == chat.id }
        }
    }
}

// MARK: - ChatListView

struct ChatListView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = ChatListViewModel()
    @State private var showCreateGroup = false
    @State private var showSecretChat = false
    @State private var showDeleteConfirm: Chat?
    @State private var navPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navPath) {
            ZStack {
                Color.bgApp.ignoresSafeArea()

                VStack(spacing: 0) {
                    header

                    SearchBar(text: $vm.searchText, placeholder: "Найти пользователя...")
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                        .onChange(of: vm.searchText) { _, q in vm.search(query: q) }

                    if vm.showArchive {
                        archiveList
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing),
                                removal: .move(edge: .trailing)
                            ))
                    } else if !vm.searchText.isEmpty {
                        searchResultsList
                    } else {
                        chatsList
                            .transition(.asymmetric(
                                insertion: .move(edge: .leading),
                                removal: .move(edge: .leading)
                            ))
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Chat.self) { chat in
                ChatView(chat: chat)
                    .environmentObject(appState)
                    .onAppear {
                        appState.activeChatId = chat.id
                        vm.clearUnread(chatId: chat.id)
                    }
                    .onDisappear {
                        appState.activeChatId = nil
                        vm.clearUnread(chatId: chat.id)
                    }
            }
        }
        .onAppear {
            vm.currentUserId = appState.currentUser?.id
            vm.activeChatId = appState.activeChatId
            vm.load()
            vm.subscribeWS()
        }
        .onChange(of: appState.activeChatId) { _, newVal in
            vm.activeChatId = newVal
            if let chatId = newVal {
                vm.clearUnread(chatId: chatId)
            }
        }
        .refreshable { vm.load() }
        .sheet(isPresented: $showCreateGroup) {
            NavigationStack {
                CreateGroupView { chat in
                    showCreateGroup = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        navPath.append(chat)
                    }
                }
                .environmentObject(appState)
            }
        }
        .sheet(isPresented: $showSecretChat) {
            NavigationStack {
                SecretChatView { chat in
                    showSecretChat = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        navPath.append(chat)
                    }
                }
                .environmentObject(appState)
            }
        }
        .alert("Удалить чат?", isPresented: Binding(
            get: { showDeleteConfirm != nil },
            set: { if !$0 { showDeleteConfirm = nil } }
        )) {
            Button("Отмена", role: .cancel) {}
            Button("Удалить", role: .destructive) {
                if let chat = showDeleteConfirm { vm.deleteChat(chat) }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            if vm.showArchive {
                Button { withAnimation(.easeInOut(duration: 0.3)) { vm.showArchive = false } } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.h2vAccent)
                }
                Text("Архив")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.textPrimary)
            } else {
                Text("Чаты")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.textPrimary)
            }

            Spacer()

            if !WebSocketClient.shared.isConnected {
                HStack(spacing: 4) {
                    ProgressView().scaleEffect(0.7)
                    Text("Подключение...")
                        .font(.system(size: 11))
                        .foregroundColor(.textTertiary)
                }
            }

            if !vm.showArchive {
                Menu {
                    Button { showCreateGroup = true } label: {
                        Label("Новая группа", systemImage: "person.3")
                    }
                    Button { showSecretChat = true } label: {
                        Label("Секретный чат", systemImage: "lock.fill")
                    }
                    Divider()
                    Button {
                        Task {
                            if let chat = try? await APIClient.shared.getSavedMessages() {
                                navPath.append(chat)
                            }
                        }
                    } label: {
                        Label("Избранное", systemImage: "bookmark")
                    }
                    if !vm.archivedChats.isEmpty {
                        Button { withAnimation(.easeInOut(duration: 0.3)) { vm.showArchive = true } } label: {
                            Label("Архив (\(vm.archivedChats.count))", systemImage: "archivebox")
                        }
                    }
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.h2vAccent)
                        .frame(width: 36, height: 36)
                        .background(Color.h2vAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Chat List

    private var chatsList: some View {
        List {
            if !vm.archivedChats.isEmpty {
                Button { withAnimation(.easeInOut(duration: 0.3)) { vm.showArchive = true } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "archivebox.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.h2vAccent)
                            .frame(width: 52, height: 52)
                            .background(Color.h2vAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Архив")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.textPrimary)
                            Text("\(vm.archivedChats.count) чатов")
                                .font(.system(size: 13))
                                .foregroundColor(.textSecondary)
                        }
                        Spacer()
                    }
                }
                .listRowBackground(Color.bgApp)
                .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
            }

            if vm.isLoading && vm.chats.isEmpty {
                ForEach(0..<6, id: \.self) { _ in chatRowSkeleton }
                    .listRowBackground(Color.bgApp)
            } else if vm.chats.isEmpty {
                emptyState.listRowBackground(Color.bgApp)
            } else {
                ForEach(vm.chats) { chat in
                    NavigationLink(value: chat) {
                        ChatRow(chat: chat, myId: appState.currentUser?.id ?? "",
                                isOnline: isOtherOnline(chat),
                                typingNames: appState.typingNicknames(chatId: chat.id),
                                isMuted: MutedStore.shared.isMuted(chat.id))
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { showDeleteConfirm = chat } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                        Button { vm.archiveChat(chat) } label: {
                            Label("Архив", systemImage: "archivebox")
                        }.tint(.orange)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { vm.muteChat(chat) } label: {
                            Label(MutedStore.shared.isMuted(chat.id) ? "Вкл. звук" : "Без звука",
                                  systemImage: MutedStore.shared.isMuted(chat.id) ? "bell" : "bell.slash")
                        }.tint(.h2vAccent)
                    }
                    .contextMenu { chatContextMenu(chat) }
                    .listRowBackground(Color.bgApp)
                    .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 14))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Archive List

    private var archiveList: some View {
        List {
            if vm.archivedChats.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 40))
                        .foregroundColor(.textTertiary)
                    Text("Архив пуст")
                        .font(.system(size: 15))
                        .foregroundColor(.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
                .listRowBackground(Color.bgApp)
            } else {
                ForEach(vm.archivedChats) { chat in
                    NavigationLink(value: chat) {
                        ChatRow(chat: chat, myId: appState.currentUser?.id ?? "",
                                isOnline: isOtherOnline(chat),
                                typingNames: [], isMuted: false)
                    }
                    .swipeActions(edge: .trailing) {
                        Button { vm.unarchiveChat(chat) } label: {
                            Label("Разархив.", systemImage: "tray.and.arrow.up")
                        }.tint(.h2vAccent)
                    }
                    .listRowBackground(Color.bgApp)
                    .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 14))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func isOtherOnline(_ chat: Chat) -> Bool {
        guard let myId = appState.currentUser?.id,
              let other = chat.otherUser(myId: myId) else { return false }
        return appState.isUserOnline(other.id)
    }

    @ViewBuilder
    private func chatContextMenu(_ chat: Chat) -> some View {
        let isPinned = chat.members.contains(where: { $0.pinnedAt != nil })
        let isMuted = MutedStore.shared.isMuted(chat.id)

        Button { isPinned ? vm.unpinChat(chat) : vm.pinChat(chat) } label: {
            Label(isPinned ? "Открепить" : "Закрепить", systemImage: isPinned ? "pin.slash" : "pin")
        }
        Button { vm.muteChat(chat) } label: {
            Label(isMuted ? "Включить звук" : "Без звука", systemImage: isMuted ? "bell" : "bell.slash")
        }
        if (chat.unread ?? 0) > 0 {
            Button { vm.clearUnread(chatId: chat.id) } label: {
                Label("Прочитано", systemImage: "envelope.open")
            }
        }
        Button { vm.archiveChat(chat) } label: {
            Label("Архивировать", systemImage: "archivebox")
        }
        Divider()
        Button(role: .destructive) { showDeleteConfirm = chat } label: {
            Label(chat.type == .group ? "Покинуть" : "Удалить", systemImage: "trash")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundColor(.textTertiary)
            Text("Пусто")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.textSecondary)
            Text("Найди кого-нибудь через поиск ↑")
                .font(.system(size: 13))
                .foregroundColor(.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var chatRowSkeleton: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.bgCard).frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(Color.bgCard).frame(width: 120, height: 14)
                RoundedRectangle(cornerRadius: 4).fill(Color.bgCard).frame(width: 200, height: 12)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    // MARK: - Search

    private var searchResultsList: some View {
        List {
            if vm.isSearching {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 40).listRowBackground(Color.bgApp)
            } else if vm.searchResults.isEmpty {
                Text("Никого не найдено")
                    .font(.system(size: 14)).foregroundColor(.textTertiary)
                    .frame(maxWidth: .infinity).padding(.top, 40).listRowBackground(Color.bgApp)
            } else {
                ForEach(vm.searchResults) { user in
                    Button { startChat(user) } label: {
                        HStack(spacing: 12) {
                            AvatarView(url: user.avatarURL, initials: user.initials, size: 46,
                                       isOnline: appState.isUserOnline(user.id), id: user.id)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.displayName).font(.system(size: 15, weight: .medium)).foregroundColor(.textPrimary)
                                Text("@\(user.nickname)").font(.system(size: 13)).foregroundColor(.textSecondary)
                            }
                            Spacer()
                            Text("Начать чат →").font(.system(size: 12, weight: .medium)).foregroundColor(.h2vAccent)
                        }
                    }
                    .listRowBackground(Color.bgApp)
                    .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func startChat(_ user: User) {
        Task {
            if let chat = try? await APIClient.shared.createDirect(userId: user.id) {
                vm.searchText = ""
                navPath.append(chat)
            }
        }
    }
}

// MARK: - Secret Chat Creation

struct SecretChatView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    var onCreated: (Chat) -> Void

    @State private var searchText = ""
    @State private var results: [User] = []
    @State private var isSearching = false
    @State private var error: String?

    var body: some View {
        ZStack {
            Color.bgApp.ignoresSafeArea()
            VStack(spacing: 0) {
                SearchBar(text: $searchText, placeholder: "Найти пользователя...")
                    .padding(14)
                    .onChange(of: searchText) { _, q in search(q) }

                ScrollView {
                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.success)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Секретный чат")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.textPrimary)
                                Text("Сообщения зашифрованы end-to-end")
                                    .font(.system(size: 12))
                                    .foregroundColor(.textSecondary)
                            }
                        }
                        .padding(14)

                        if let error {
                            Text(error).font(.system(size: 12)).foregroundColor(.danger).padding(.horizontal, 14)
                        }

                        LazyVStack(spacing: 0) {
                            if isSearching {
                                ProgressView().padding(.top, 30)
                            } else {
                                ForEach(results) { user in
                                    Button { createSecret(user) } label: {
                                        HStack(spacing: 12) {
                                            AvatarView(url: user.avatarURL, initials: user.initials, size: 42, id: user.id)
                                            Text(user.displayName).font(.system(size: 15)).foregroundColor(.textPrimary)
                                            Spacer()
                                            Image(systemName: "lock.fill").font(.system(size: 12)).foregroundColor(.success)
                                        }
                                        .padding(.horizontal, 16).padding(.vertical, 10)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Секретный чат")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Отмена") { dismiss() }.foregroundColor(.textSecondary)
            }
        }
    }

    private func search(_ q: String) {
        guard !q.isEmpty else { results = []; return }
        isSearching = true
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            do { results = try await APIClient.shared.searchUsers(query: q) } catch {}
            isSearching = false
        }
    }

    private func createSecret(_ user: User) {
        Task {
            do {
                let chat = try await APIClient.shared.createSecret(userId: user.id)
                SecretChatSessionStore.shared.registerSecretChat(chat.id)
                onCreated(chat)
            } catch let e as NetworkError {
                error = e.localizedDescription
            } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Chat Row

struct ChatRow: View {
    let chat: Chat
    let myId: String
    var isOnline: Bool = false
    var typingNames: [String] = []
    var isMuted: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(url: chat.chatAvatarURL(myId: myId),
                       initials: chat.chatInitials(myId: myId),
                       size: 52, isOnline: isOnline && chat.type != .self_, id: chat.id)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    chatTitle
                    Spacer()
                    if let date = chat.lastMessage?.createdAt {
                        Text(DateHelper.chatRow(date))
                            .font(.system(size: 12))
                            .foregroundColor((chat.unread ?? 0) > 0 ? .h2vAccent : .textTertiary)
                    }
                }

                HStack {
                    if !typingNames.isEmpty {
                        Text("печатает...")
                            .font(.system(size: 13))
                            .foregroundColor(.h2vAccent)
                    } else if let draft = chat.draft, !draft.text.isEmpty {
                        HStack(spacing: 0) {
                            Text("Черновик: ").font(.system(size: 13)).foregroundColor(.danger)
                            Text(draft.text).font(.system(size: 13)).foregroundColor(.textSecondary).lineLimit(1)
                        }
                    } else {
                        lastMessagePreview
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        if isMuted {
                            Image(systemName: "bell.slash.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.textTertiary)
                        }
                        if let unread = chat.unread, unread > 0 {
                            UnreadBadge(count: unread, muted: isMuted)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var chatTitle: some View {
        HStack(spacing: 4) {
            if chat.type == .secret {
                Image(systemName: "lock.fill").font(.system(size: 11)).foregroundColor(.success)
            }
            if chat.type == .self_ {
                Image(systemName: "bookmark.fill").font(.system(size: 11)).foregroundColor(.h2vAccent)
            }
            Text(chat.displayName(myId: myId))
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.textPrimary)
                .lineLimit(1)
            if chat.members.contains(where: { $0.pinnedAt != nil }) {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundColor(.textTertiary)
            }
        }
    }

    private var lastMessagePreview: some View {
        Group {
            if let msg = chat.lastMessage {
                if msg.deleted {
                    Text("Сообщение удалено").font(.system(size: 13)).foregroundColor(.textTertiary).italic()
                } else {
                    HStack(spacing: 0) {
                        if (chat.type == .group || chat.type == .self_), let sender = msg.sender {
                            Text(sender.id == myId ? "Вы: " : "\(sender.nickname): ")
                                .font(.system(size: 13, weight: .medium)).foregroundColor(.textSecondary)
                        }
                        Text(previewText(msg)).font(.system(size: 13)).foregroundColor(.textSecondary).lineLimit(1)
                    }
                }
            } else {
                Text("Нет сообщений").font(.system(size: 13)).foregroundColor(.textTertiary)
            }
        }
    }

    private func previewText(_ msg: Message) -> String {
        if msg.ciphertext != nil { return "🔒 Зашифровано" }
        switch msg.type {
        case .image: return "📷 " + (msg.text ?? "Фото")
        case .video: return "🎬 " + (msg.text ?? "Видео")
        case .audio: return "🎤 Голосовое"
        case .file: return "📎 " + (msg.mediaName ?? "Файл")
        case .system: return msg.text ?? ""
        default: return msg.text ?? ""
        }
    }
}
