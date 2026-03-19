import SwiftUI

// MARK: - Group Profile View

struct GroupProfileView: View {
    let chat: Chat
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var groupName: String = ""
    @State private var isEditing = false
    @State private var showAddMembers = false
    @State private var error: String?
    @State private var activeTab: GroupMediaTab = .media
    @State private var mediaMessages: [Message] = []
    @State private var fileMessages: [Message] = []
    @State private var voiceMessages: [Message] = []
    @State private var isLoadingMedia = false
    @State private var mediaViewerCtx: MediaViewerContext?

    enum GroupMediaTab: String, CaseIterable {
        case media = "Медиа"
        case files = "Файлы"
        case voice = "Голосовые"
    }

    private var myId: String { appState.currentUser?.id ?? "" }
    private var isAdmin: Bool {
        chat.members.first(where: { $0.user.id == myId })?.role == "ADMIN"
    }

    var body: some View {
        ZStack {
            Color.bgApp.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    headerSection
                    membersSection
                    groupSharedMediaSection
                    actionsSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Закрыть") { dismiss() }
                    .foregroundColor(.textSecondary)
            }
        }
        .fullScreenCover(item: $mediaViewerCtx) { ctx in
            MediaViewerView(urls: ctx.urls, startIndex: ctx.startIndex)
        }
        .sheet(isPresented: $showAddMembers) {
            AddMembersView(chatId: chat.id)
                .environmentObject(appState)
        }
        .onAppear { groupName = chat.name ?? "" }
        .task { await loadGroupMedia() }
    }

    private var headerSection: some View {
        VStack(spacing: 12) {
            AvatarView(url: chat.chatAvatarURL(myId: myId),
                       initials: chat.chatInitials(myId: myId),
                       size: 80, id: chat.id)

            if isEditing {
                TextField("", text: $groupName, prompt: Text("Имя группы").foregroundColor(.textTertiary))
                    .foregroundColor(.textPrimary)
                    .font(.system(size: 18, weight: .bold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .inputStyle(radius: 10)

                HStack(spacing: 12) {
                    Button("Отмена") { isEditing = false; groupName = chat.name ?? "" }
                        .foregroundColor(.textSecondary)
                    AccentButton(title: "Сохранить") {
                        Task {
                            _ = try? await APIClient.shared.renameGroup(id: chat.id, name: groupName)
                            isEditing = false
                        }
                    }
                    .frame(width: 120)
                }
            } else {
                Text(chat.name ?? "Группа")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.textPrimary)

                Text("\(chat.members.count) участников")
                    .font(.system(size: 14))
                    .foregroundColor(.textSecondary)

                if isAdmin {
                    Button { isEditing = true } label: {
                        Text("Редактировать")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.h2vAccent)
                    }
                }
            }
        }
    }

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("УЧАСТНИКИ")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.textTertiary)
                    .tracking(0.9)
                Spacer()
                if isAdmin {
                    Button { showAddMembers = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.h2vAccent)
                    }
                }
            }

            VStack(spacing: 0) {
                ForEach(chat.members) { member in
                    HStack(spacing: 12) {
                        AvatarView(url: member.user.avatarURL, initials: member.user.initials,
                                   size: 40, isOnline: appState.isUserOnline(member.user.id),
                                   id: member.user.id)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(member.user.displayName)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.textPrimary)
                                if member.role == "ADMIN" {
                                    Text("Админ")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.h2vAccent)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Color.h2vAccent.opacity(0.15), in: Capsule())
                                }
                            }
                            if appState.isUserOnline(member.user.id) {
                                Text("онлайн").font(.system(size: 12)).foregroundColor(.success)
                            } else {
                                Text(DateHelper.lastSeen(member.user.lastOnline))
                                    .font(.system(size: 12)).foregroundColor(.textTertiary)
                            }
                        }

                        Spacer()

                        if isAdmin && member.user.id != myId {
                            Button {
                                Task {
                                    try? await APIClient.shared.kickMember(chatId: chat.id, userId: member.user.id)
                                }
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .font(.system(size: 16))
                                    .foregroundColor(.danger.opacity(0.6))
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
            .cardBackground(radius: 12)
        }
    }

    // MARK: - Group Shared Media

    private func loadGroupMedia() async {
        isLoadingMedia = true
        async let mediaReq = APIClient.shared.getSharedMedia(chatId: chat.id, type: "IMAGE")
        async let fileReq = APIClient.shared.getSharedMedia(chatId: chat.id, type: "FILE")
        async let voiceReq = APIClient.shared.getSharedMedia(chatId: chat.id, type: "AUDIO")
        do {
            let (m, f, v) = try await (mediaReq, fileReq, voiceReq)
            mediaMessages = m.messages
            let videoData = try? await APIClient.shared.getSharedMedia(chatId: chat.id, type: "VIDEO")
            if let vids = videoData?.messages { mediaMessages += vids }
            mediaMessages.sort { $0.createdAt > $1.createdAt }
            fileMessages = f.messages
            voiceMessages = v.messages
        } catch {}
        isLoadingMedia = false
    }

    private var groupSharedMediaSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                ForEach(GroupMediaTab.allCases, id: \.self) { tab in
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

            Group {
                switch activeTab {
                case .media: groupMediaGrid
                case .files: groupFilesList
                case .voice: groupVoiceList
                }
            }
            .animation(.easeInOut(duration: 0.2), value: activeTab)
        }
    }

    private var groupMediaGrid: some View {
        Group {
            if isLoadingMedia {
                ProgressView().padding(.top, 30)
            } else if mediaMessages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 32)).foregroundColor(.textTertiary.opacity(0.5))
                    Text("Нет медиа").font(.system(size: 13)).foregroundColor(.textTertiary)
                }.padding(.top, 30)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 2),
                                    GridItem(.flexible(), spacing: 2),
                                    GridItem(.flexible(), spacing: 2)], spacing: 2) {
                    ForEach(mediaMessages) { msg in
                        if let url = msg.mediaFullURL {
                            ZStack {
                                CachedAsyncImage(url: url) { img in
                                    img.resizable().scaledToFill()
                                } placeholder: { Color.bgCard }
                                .frame(height: 110).clipped()
                                if msg.type == .video {
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 28))
                                        .foregroundColor(.white.opacity(0.9)).shadow(radius: 3)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let all = mediaMessages.compactMap { $0.mediaFullURL }
                                let idx = all.firstIndex(of: url) ?? 0
                                mediaViewerCtx = MediaViewerContext(urls: all, startIndex: idx)
                            }
                        }
                    }
                }
            }
        }
    }

    private var groupFilesList: some View {
        Group {
            if isLoadingMedia {
                ProgressView().padding(.top, 30)
            } else if fileMessages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 32)).foregroundColor(.textTertiary.opacity(0.5))
                    Text("Нет файлов").font(.system(size: 13)).foregroundColor(.textTertiary)
                }.padding(.top, 30)
            } else {
                VStack(spacing: 0) {
                    ForEach(fileMessages) { msg in
                        HStack(spacing: 10) {
                            Image(systemName: "doc.fill").font(.system(size: 20)).foregroundColor(.h2vAccent)
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

    private var groupVoiceList: some View {
        Group {
            if isLoadingMedia {
                ProgressView().padding(.top, 30)
            } else if voiceMessages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "mic")
                        .font(.system(size: 32)).foregroundColor(.textTertiary.opacity(0.5))
                    Text("Нет голосовых").font(.system(size: 13)).foregroundColor(.textTertiary)
                }.padding(.top, 30)
            } else {
                VStack(spacing: 0) {
                    ForEach(voiceMessages) { msg in
                        HStack(spacing: 10) {
                            Button {
                                if let url = msg.mediaFullURL { AudioPlayerManager.shared.play(url: url) }
                            } label: {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 14)).foregroundColor(.white)
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

    private var actionsSection: some View {
        VStack(spacing: 2) {
            Button {
                Task {
                    try? await APIClient.shared.leaveChat(id: chat.id)
                    dismiss()
                }
            } label: {
                HStack {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                    Text("Покинуть группу")
                }
                .font(.system(size: 15))
                .foregroundColor(.danger)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
            }

            if isAdmin {
                Divider().background(Color.borderPrimary)
                Button {
                    Task {
                        try? await APIClient.shared.deleteChat(id: chat.id)
                        dismiss()
                    }
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("Удалить группу")
                    }
                    .font(.system(size: 15))
                    .foregroundColor(.danger)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                }
            }
        }
        .cardBackground(radius: 16)
    }
}

// MARK: - Add Members

struct AddMembersView: View {
    let chatId: String
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var searchText = ""
    @State private var results: [User] = []
    @State private var isSearching = false

    var body: some View {
        ZStack {
            Color.bgApp.ignoresSafeArea()

            VStack(spacing: 0) {
                SearchBar(text: $searchText, placeholder: "Найти пользователя...")
                    .padding(14)
                    .onChange(of: searchText) { _, q in search(q) }

                ScrollView {
                    LazyVStack(spacing: 0) {
                        if isSearching {
                            ProgressView().padding(.top, 40)
                        } else {
                            ForEach(results) { user in
                                HStack(spacing: 12) {
                                    AvatarView(url: user.avatarURL, initials: user.initials,
                                               size: 42, id: user.id)
                                    Text(user.displayName)
                                        .font(.system(size: 15))
                                        .foregroundColor(.textPrimary)
                                    Spacer()
                                    Button("Добавить") {
                                        Task {
                                            _ = try? await APIClient.shared.addMembers(chatId: chatId, userIds: [user.id])
                                            dismiss()
                                        }
                                    }
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.h2vAccent)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Добавить участников")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Отмена") { dismiss() }
                    .foregroundColor(.textSecondary)
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
}
