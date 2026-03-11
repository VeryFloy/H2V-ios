import SwiftUI
import PhotosUI

// MARK: - ChatViewModel

@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var isLoading = false
    @Published var isUploading = false
    @Published var sendError: String?
    /// userId → nickname for people currently typing
    @Published var typingUsers: [String: String] = [:]
    @Published var errorMsg: String?
    /// Message currently being replied to
    @Published var replyTo: Message? = nil
    var currentUserId: String?
    private(set) var hasMore = true
    private var nextCursor: String? = nil
    let chat: Chat
    /// Last messageId for which we sent a read receipt (deduplication)
    private var lastSentReadId: String? = nil

    init(chat: Chat) { self.chat = chat }

    var typingUserIds: Set<String> { Set(typingUsers.keys) }

    var typingLabel: String? {
        guard !typingUsers.isEmpty else { return nil }
        let names = typingUsers.values.map { "@\($0)" }
        switch names.count {
        case 1: return "\(names[0]) печатает..."
        case 2: return "\(names[0]) и \(names[1]) печатают..."
        default: return "\(names.count) человека печатают..."
        }
    }

    func loadMessages(refresh: Bool = false) {
        guard !isLoading else { return }
        if refresh {
            // Show cached messages instantly while network loads
            let cached = MessageCache.shared.load(for: chat.id)
            if !cached.isEmpty && messages.isEmpty {
                messages = cached
                markLastMessageRead()
            }
            nextCursor = nil
            hasMore = true
        }
        guard hasMore else { return }
        isLoading = true
        let cursor = nextCursor
        Task {
            do {
                let data = try await APIClient.shared.getMessages(chatId: chat.id, cursor: cursor, limit: 40)
                let msgs = data.messages.reversed() as [Message]
                if refresh {
                    messages = msgs
                    // Persist latest batch to cache
                    MessageCache.shared.save(msgs, for: chat.id)
                } else {
                    messages.insert(contentsOf: msgs, at: 0)
                }
                nextCursor = data.nextCursor
                hasMore = data.nextCursor != nil
                markLastMessageRead()
            } catch { errorMsg = error.localizedDescription }
            isLoading = false
        }
    }

    func sendText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard ensureConnected() else {
            sendError = "Нет подключения. Проверьте сеть."
            return
        }
        sendError = nil
        let rid = replyTo?.id
        replyTo = nil
        WebSocketClient.shared.sendMessage(chatId: chat.id, text: trimmed, type: "TEXT", replyToId: rid)
    }

    func sendImage(_ item: PhotosPickerItem) {
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else { return }
            isUploading = true
            do {
                let upload = try await APIClient.shared.uploadFile(data: data, filename: "photo.jpg", mimeType: "image/jpeg")
                guard ensureConnected() else {
                    sendError = "Нет подключения. Проверьте сеть."
                    isUploading = false
                    return
                }
                let rid = replyTo?.id
                replyTo = nil
                WebSocketClient.shared.sendMessage(chatId: chat.id, text: "",
                                                   type: "IMAGE", mediaUrl: upload.url, replyToId: rid)
            } catch { errorMsg = error.localizedDescription }
            isUploading = false
        }
    }

    func deleteMessage(_ id: String) {
        Task {
            try? await APIClient.shared.deleteMessage(id: id)
            messages.removeAll { $0.id == id }
        }
    }

    func editMessage(id: String, newText: String) {
        Task {
            do {
                let updated = try await APIClient.shared.editMessage(id: id, text: newText)
                if let i = messages.firstIndex(where: { $0.id == id }) {
                    messages[i] = updated
                }
            } catch { errorMsg = error.localizedDescription }
        }
    }

    func toggleReaction(messageId: String, emoji: String) {
        guard let msg = messages.first(where: { $0.id == messageId }) else { return }
        let alreadyReacted = msg.reactions?.contains { $0.userId == currentUserId && $0.emoji == emoji } ?? false
        Task {
            do {
                if alreadyReacted {
                    try await APIClient.shared.removeReaction(messageId: messageId, emoji: emoji)
                } else {
                    try await APIClient.shared.addReaction(messageId: messageId, emoji: emoji)
                }
            } catch { errorMsg = error.localizedDescription }
        }
    }

    func sendTyping() {
        let ud = UserDefaults.standard
        let enabled = ud.object(forKey: "h2v.typingIndicator") == nil || ud.bool(forKey: "h2v.typingIndicator")
        guard enabled, ensureConnected() else { return }
        WebSocketClient.shared.typingStart(chatId: chat.id)
    }
    func stopTyping() { WebSocketClient.shared.typingStop(chatId: chat.id) }

    // MARK: - WS Event Handler

    func handleEvent(_ event: WSEvent) {
        switch event.type {

        case "message:new", "new_message":
            guard let msg = event.decodeMessage() else { return }
            let inThisChat = msg.chatId == chat.id
                || (msg.chatId == nil && event.chatId == chat.id)
            guard inThisChat else { return }
            if !messages.contains(where: { $0.id == msg.id }) {
                messages.append(msg)
                MessageCache.shared.save(messages, for: chat.id)
                if msg.sender.id != currentUserId {
                    markLastMessageRead()
                }
            }

        case "message:edited":
            guard let msg = event.decodeMessage() else { return }
            if let i = messages.firstIndex(where: { $0.id == msg.id }) {
                messages[i] = msg
            }

        case "message:deleted", "message_deleted":
            if let id = event.messageId { messages.removeAll { $0.id == id } }

        case "message:read":
            guard let msgId = event.rawPayload["messageId"] as? String else { return }
            let userId = event.rawPayload["userId"] as? String ?? event.userId ?? ""
            let readAt = event.rawPayload["readAt"] as? String
                ?? ISO8601DateFormatter().string(from: Date())
            let receipt = ReadReceipt(userId: userId, readAt: readAt)
            guard let targetIdx = messages.firstIndex(where: { $0.id == msgId }) else { return }
            for i in 0...targetIdx {
                guard messages[i].sender.id == currentUserId else { continue }
                if !(messages[i].readReceipts?.contains(where: { $0.userId == userId }) ?? false) {
                    messages[i].readReceipts = (messages[i].readReceipts ?? []) + [receipt]
                }
            }

        case "reaction:added":
            let rDict = event.rawPayload["reaction"] as? [String: Any] ?? event.rawPayload
            guard let msgId    = rDict["messageId"] as? String,
                  let rId      = rDict["id"]        as? String,
                  let rUserId  = rDict["userId"]    as? String,
                  let rEmoji   = rDict["emoji"]     as? String else { return }
            guard let i = messages.firstIndex(where: { $0.id == msgId }) else { return }
            let newR = Reaction(id: rId, userId: rUserId, emoji: rEmoji)
            if !(messages[i].reactions?.contains(where: { $0.id == rId }) ?? false) {
                messages[i].reactions = (messages[i].reactions ?? []) + [newR]
            }

        case "reaction:removed":
            let msgId  = event.rawPayload["messageId"] as? String ?? event.messageId ?? ""
            let userId = event.rawPayload["userId"]    as? String ?? ""
            let emoji  = event.rawPayload["emoji"]     as? String ?? ""
            guard !msgId.isEmpty, let i = messages.firstIndex(where: { $0.id == msgId }) else { return }
            messages[i].reactions?.removeAll { $0.userId == userId && $0.emoji == emoji }

        case "typing:started", "typing:start":
            guard let uid = event.userId, uid != currentUserId else { return }
            let eid = event.rawPayload["chatId"] as? String
            guard eid == chat.id else { return }
            let nick = event.rawPayload["nickname"] as? String
                ?? chat.members.first(where: { $0.userId == uid })?.user.nickname
                ?? uid
            typingUsers[uid] = nick
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                typingUsers.removeValue(forKey: uid)
            }

        case "typing:stopped", "typing:stop":
            guard let uid = event.userId else { return }
            typingUsers.removeValue(forKey: uid)

        default: break
        }
    }

    // MARK: - Read Receipts

    func markLastMessageRead() {
        let sendReceipts = UserDefaults.standard.object(forKey: "h2v.readReceipts") == nil
            || UserDefaults.standard.bool(forKey: "h2v.readReceipts")
        guard sendReceipts else { return }
        guard let lastMsg = messages.last(where: { $0.sender.id != currentUserId && !($0.isDeleted ?? false) })
        else { return }
        guard lastMsg.id != lastSentReadId else { return }
        lastSentReadId = lastMsg.id
        WebSocketClient.shared.markRead(messageId: lastMsg.id, chatId: chat.id)
    }

    // MARK: - Private

    @discardableResult
    private func ensureConnected() -> Bool {
        if WebSocketClient.shared.isConnected { return true }
        if let token = TokenStorage.shared.accessToken {
            WebSocketClient.shared.connect(token: token)
        }
        return WebSocketClient.shared.isConnected
    }
}

// MARK: - ChatView

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var inputText = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var typingTimer: Timer?
    @State private var mediaViewerURLs: [URL] = []
    @State private var mediaViewerIndex: Int = 0
    @State private var showMediaViewer = false
    @State private var wsSubscriberID: UUID? = nil
    @State private var didInitialScroll = false

    init(chat: Chat) {
        _vm = StateObject(wrappedValue: ChatViewModel(chat: chat))
    }

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()
            VStack(spacing: 0) {
                chatHeader
                Divider().background(Color.glassBorder)
                // WS error banner
                if let err = vm.sendError {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 12, weight: .medium))
                        Text(err)
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background(Color.dangerRed.opacity(0.85))
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                messageArea
                Divider().background(Color.glassBorder)
                // Reply bar
                if let reply = vm.replyTo {
                    replyBar(for: reply)
                }
                inputBar
            }
        }
        .animation(.easeInOut(duration: 0.22), value: vm.sendError)
        .navigationBarHidden(true)
        .onAppear {
            vm.currentUserId = appState.currentUser?.id
            appState.activeChatId = vm.chat.id
            vm.loadMessages(refresh: true)
            wsSubscriberID = WebSocketClient.shared.subscribe { [weak vm] event in
                vm?.handleEvent(event)
            }
        }
        .onDisappear {
            appState.activeChatId = nil
            stopTypingNow()
            if let id = wsSubscriberID {
                WebSocketClient.shared.unsubscribe(id)
                wsSubscriberID = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            vm.markLastMessageRead()
        }
        .fullScreenCover(isPresented: $showMediaViewer) {
            MediaViewer(urls: mediaViewerURLs, initialIndex: mediaViewerIndex, isPresented: $showMediaViewer)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in if let item { vm.sendImage(item) } }
    }

    // MARK: Header

    private var chatHeader: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 36, height: 36)
                    .glassBackground(cornerRadius: 18, opacity: 0.45)
            }

            let uid = appState.currentUser?.id ?? ""
            let isGroup = vm.chat.type == "GROUP"
            let other = vm.chat.otherUser(currentUserId: uid)
            let isOnline = other.map { appState.onlineUserIds.contains($0.id) } ?? false

            if isGroup {
                // Group avatar
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(avatarColor(for: vm.chat.id).opacity(0.18))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(avatarColor(for: vm.chat.id).opacity(0.28), lineWidth: 1)
                        }
                        .frame(width: 38, height: 38)
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(avatarColor(for: vm.chat.id))
                }
            } else {
                AvatarView(
                    url: vm.chat.chatAvatarURL(currentUserId: uid),
                    initials: vm.chat.chatInitials(currentUserId: uid),
                    size: 38,
                    isOnline: isOnline,
                    avatarColorOverride: avatarColor(for: vm.chat.id)
                )
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(vm.chat.displayName(currentUserId: uid))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .tracking(-0.2)
                    .lineLimit(1)
                Group {
                    if let label = vm.typingLabel {
                        Text(label)
                            .foregroundStyle(Color.onlineGreen)
                    } else if isGroup {
                        let memberCount = vm.chat.members.count
                        Text("\(memberCount) \(memberCount == 1 ? "участник" : memberCount < 5 ? "участника" : "участников")")
                            .foregroundStyle(Color.textTertiary)
                    } else if isOnline {
                        Text("онлайн")
                            .foregroundStyle(Color.onlineGreen)
                    } else {
                        Text("@\(other?.nickname ?? "")")
                            .foregroundStyle(Color(hex: "5E8CFF").opacity(0.7))
                    }
                }
                .font(.system(size: 12))
                .animation(.easeInOut(duration: 0.15), value: vm.typingLabel)
            }

            Spacer()

            if isGroup {
                // Group info button
                Button {} label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.textTertiary)
                        .frame(width: 34, height: 34)
                        .glassBackground(cornerRadius: 17, opacity: 0.38)
                }
            } else {
                Button {} label: {
                    Image(systemName: "phone")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.textTertiary)
                        .frame(width: 34, height: 34)
                        .glassBackground(cornerRadius: 17, opacity: 0.38)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Message Area

    // MARK: - Date separator helpers

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM"
        return f
    }()

    private static let dateFmtYear: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM yyyy"
        return f
    }()

    private func dateSeparatorText(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date)     { return "Сегодня" }
        if cal.isDateInYesterday(date) { return "Вчера" }
        let isSameYear = cal.isDate(date, equalTo: Date(), toGranularity: .year)
        return isSameYear
            ? Self.dateFmt.string(from: date)
            : Self.dateFmtYear.string(from: date)
    }

    private func showSeparator(before index: Int) -> Bool {
        guard index < vm.messages.count else { return false }
        if index == 0 { return true }
        let curr = vm.messages[index].createdDate
        let prev = vm.messages[index - 1].createdDate
        return !Calendar.current.isDate(curr, inSameDayAs: prev)
    }

    // MARK: - Message area

    private var messageArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if vm.hasMore {
                        ProgressView()
                            .tint(Color.white.opacity(0.3))
                            .padding(.vertical, 8)
                            .onAppear { vm.loadMessages() }
                    }

                    ForEach(Array(vm.messages.enumerated()), id: \.element.id) { idx, msg in
                        let isMe = msg.sender.id == (vm.currentUserId ?? "")
                        let prevMsg = idx > 0 ? vm.messages[idx - 1] : nil
                        let sameSender = prevMsg?.sender.id == msg.sender.id

                        if showSeparator(before: idx) {
                            DateSeparator(text: dateSeparatorText(for: msg.createdDate))
                                .padding(.vertical, 8)
                        }

                        MessageBubbleView(message: msg, isMe: isMe, sameSender: sameSender,
                                          chatType: vm.chat.type) { url in
                            let imageURLs = vm.messages.compactMap { $0.mediaFullURL }
                            let idx = imageURLs.firstIndex(of: url) ?? 0
                            mediaViewerURLs = imageURLs
                            mediaViewerIndex = idx
                            showMediaViewer = true
                        }
                        .contextMenu { contextMenuItems(msg: msg, isMe: isMe) }
                        .id(msg.id)
                        .padding(.bottom, sameSender ? 1 : 4)
                    }

                    if let label = vm.typingLabel {
                        HStack(spacing: 6) {
                            TypingIndicatorView()
                            Text(label)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.leading, 14)
                        .padding(.vertical, 4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .onChange(of: vm.messages.count) { oldCount, newCount in
                if !didInitialScroll {
                    // First batch loaded — jump instantly, no animation
                    proxy.scrollTo("bottom")
                    didInitialScroll = true
                } else if newCount > oldCount {
                    // New incoming/sent message — smooth scroll
                    withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("bottom") }
                }
            }
            .onChange(of: vm.typingLabel) { _, label in
                if label != nil {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom") }
                }
            }
            .onAppear {
                proxy.scrollTo("bottom")
                didInitialScroll = false
            }
        }
    }

    @ViewBuilder
    private func contextMenuItems(msg: Message, isMe: Bool) -> some View {
        // Reaction picker
        let reactions = ["👍", "❤️", "😂", "😮", "😢", "🔥"]
        HStack(spacing: 4) {
            ForEach(reactions, id: \.self) { emoji in
                Button {
                    vm.toggleReaction(messageId: msg.id, emoji: emoji)
                } label: {
                    Text(emoji).font(.title2)
                }
            }
        }

        Divider()

        Button {
            vm.replyTo = msg
        } label: {
            Label("Ответить", systemImage: "arrowshape.turn.up.left")
        }

        if let text = msg.text, !text.isEmpty {
            Button {
                UIPasteboard.general.string = text
            } label: {
                Label("Копировать", systemImage: "doc.on.doc")
            }
        }

        if isMe && !(msg.isDeleted ?? false) {
            if msg.messageType == .text, let text = msg.text {
                Button {
                    inputText = text
                    // Indicate editing by setting reply bar placeholder
                    // Full inline edit could be a future enhancement
                } label: {
                    Label("Редактировать", systemImage: "pencil")
                }
            }

            Button(role: .destructive) { vm.deleteMessage(msg.id) } label: {
                Label("Удалить", systemImage: "trash")
            }
        }
    }

    // MARK: Reply Bar

    private func replyBar(for msg: Message) -> some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color(hex: "5E8CFF"))
                .frame(width: 3)
                .cornerRadius(2)

            VStack(alignment: .leading, spacing: 2) {
                Text("@\(msg.sender.nickname)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(hex: "5E8CFF"))
                    .lineLimit(1)
                Group {
                    if msg.messageType == .image {
                        Text("📷 Фото")
                    } else {
                        Text(msg.text ?? "")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
            }

            Spacer()

            Button {
                vm.replyTo = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.glassSurface.opacity(0.4))
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.18), value: vm.replyTo?.id)
    }

    // MARK: Input Bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button { showPhotoPicker = true } label: {
                Image(systemName: "photo")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.white.opacity(vm.isUploading ? 0.2 : 0.4))
                    .frame(width: 36, height: 36)
                    .glassBackground(cornerRadius: 18, opacity: 0.38)
            }
            .disabled(vm.isUploading)

            HStack(spacing: 8) {
                TextField("", text: $inputText,
                          prompt: Text("Написать...").foregroundStyle(Color.white.opacity(0.22)),
                          axis: .vertical)
                    .foregroundStyle(.white)
                    .font(.system(size: 15))
                    .tracking(-0.1)
                    .lineLimit(1...5)
                    .onChange(of: inputText) { _, v in
                        if v.isEmpty { stopTypingNow() } else { handleTyping() }
                    }
                Text("😊")
                    .font(.system(size: 17))
                    .opacity(0.3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassBackground(cornerRadius: 22, opacity: 0.38)

            let hasText = !inputText.trimmingCharacters(in: .whitespaces).isEmpty
            Button {
                let t = inputText
                inputText = ""
                stopTypingNow()
                vm.sendText(t)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(hasText ? .black : Color.white.opacity(0.25))
                    .frame(width: 44, height: 44)
                    .background(
                        hasText
                            ? AnyShapeStyle(Color.white.opacity(0.92))
                            : AnyShapeStyle(Color.white.opacity(0.08)),
                        in: Circle()
                    )
                    .overlay(Circle().stroke(Color.white.opacity(hasText ? 0 : 0.12), lineWidth: 0.5))
                    .shadow(color: .white.opacity(hasText ? 0.18 : 0), radius: 12)
            }
            .disabled(!hasText)
            .animation(.easeInOut(duration: 0.18), value: hasText)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, max((UIApplication.shared.connectedScenes
            .first as? UIWindowScene)?.windows.first?.safeAreaInsets.bottom ?? 0, 20))
    }

    // MARK: Typing Helpers

    private func handleTyping() {
        vm.sendTyping()
        typingTimer?.invalidate()
        typingTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
            Task { @MainActor in self.stopTypingNow() }
        }
    }

    private func stopTypingNow() {
        typingTimer?.invalidate()
        typingTimer = nil
        vm.stopTyping()
    }
}

// MARK: - MessageBubbleView

struct MessageBubbleView: View {
    let message: Message
    let isMe: Bool
    let sameSender: Bool
    var chatType: String = "DIRECT"
    var onImageTap: ((URL) -> Void)? = nil

    private var isGroup: Bool { chatType == "GROUP" }
    private var showSenderName: Bool { isGroup && !isMe && !sameSender }

    @AppStorage("h2v.fontSize")    private var fontSize: Double = 15
    @AppStorage("h2v.bubbleStyle") private var bubbleStyle: String = "glass"

    // Bubble fill — colour depends on style + sender
    private var myBubbleFill: Color {
        switch bubbleStyle {
        case "solid":    return Color(hex: "1E3A5F")          // dark blue solid
        case "gradient": return Color.clear                   // gradient handled below
        default:         return Color.bubbleMe                // glass (adaptive)
        }
    }
    private var theirBubbleFill: Color {
        switch bubbleStyle {
        case "solid":    return Color(hex: "2A2A2E")
        case "gradient": return Color(hex: "2A2A2E")
        default:         return Color.bubbleThem
        }
    }
    private var myBubbleBorder: Color {
        switch bubbleStyle {
        case "solid":    return Color(hex: "2E5A9C").opacity(0.5)
        case "gradient": return Color(hex: "4A7CFF").opacity(0.4)
        default:         return Color.glassBorder
        }
    }
    private var theirBubbleBorder: Color { Color.glassBorder.opacity(0.6) }

    private var r: CGFloat { sameSender ? 14 : 18 }

    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: .init(
                topLeading:     r,
                bottomLeading:  isMe ? r : 4,
                bottomTrailing: isMe ? 4 : r,
                topTrailing:    r
            ),
            style: .continuous
        )
    }

    var body: some View {
        HStack {
            if isMe { Spacer(minLength: 60) }

            VStack(alignment: isMe ? .trailing : .leading, spacing: 2) {
                // Sender name for group chats
                if showSenderName {
                    HStack(spacing: 5) {
                        AvatarView(
                            url: message.sender.avatarURL,
                            initials: String(message.sender.nickname.prefix(2)).uppercased(),
                            size: 18,
                            avatarColorOverride: avatarColor(for: message.sender.id)
                        )
                        Text("@\(message.sender.nickname)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(avatarColor(for: message.sender.id))
                    }
                    .padding(.leading, 4)
                }

                if message.messageType == .image {
                    imageContent
                } else {
                    textContent
                }

                // Reactions strip
                reactionsStrip

                HStack(spacing: 3) {
                    if message.isEdited == true {
                        Text("изменено")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.white.opacity(0.18))
                            .italic()
                    }
                    Text(MessageTime.shortTime(from: message.createdAt))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.2))
                    if isMe {
                        let isRead = !(message.readReceipts?.isEmpty ?? true)
                        Image(systemName: isRead ? "checkmark.message" : "checkmark")
                            .font(.system(size: 9))
                            .foregroundStyle(isRead ? Color(hex: "5E8CFF").opacity(0.8) : Color.white.opacity(0.3))
                    }
                }
                .padding(.horizontal, 4)
            }

            if !isMe { Spacer(minLength: 60) }
        }
    }

    // MARK: - Reply quote

    @ViewBuilder
    private var replyQuote: some View {
        if let reply = message.replyTo {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(Color(hex: "5E8CFF").opacity(0.7))
                    .frame(width: 3)
                    .cornerRadius(1.5)
                VStack(alignment: .leading, spacing: 1) {
                    Text("@\(reply.sender.nickname)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(hex: "5E8CFF").opacity(0.9))
                        .lineLimit(1)
                    if reply.isDeleted == true {
                        Text("Сообщение удалено")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.textTertiary)
                            .italic()
                    } else {
                        Text(reply.text ?? "Медиа")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(2)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    // MARK: - Reactions strip

    @ViewBuilder
    private var reactionsStrip: some View {
        let grouped = groupedReactions
        if !grouped.isEmpty {
            HStack(spacing: 4) {
                ForEach(grouped, id: \.emoji) { item in
                    Text(item.count > 1 ? "\(item.emoji) \(item.count)" : item.emoji)
                        .font(.system(size: 13))
                        .padding(.horizontal, item.count > 1 ? 7 : 5)
                        .padding(.vertical, 3)
                        .background(
                            item.mine
                                ? Color(hex: "5E8CFF").opacity(0.28)
                                : Color.white.opacity(0.1),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().stroke(
                                item.mine ? Color(hex: "5E8CFF").opacity(0.5) : Color.white.opacity(0.12),
                                lineWidth: 0.5
                            )
                        )
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private struct ReactionGroup { let emoji: String; let count: Int; let mine: Bool }

    private var groupedReactions: [ReactionGroup] {
        guard let reactions = message.reactions, !reactions.isEmpty else { return [] }
        var dict: [String: (count: Int, mine: Bool)] = [:]
        for r in reactions {
            let existing = dict[r.emoji] ?? (count: 0, mine: false)
            dict[r.emoji] = (count: existing.count + 1, mine: existing.mine)
        }
        return dict.map { ReactionGroup(emoji: $0.key, count: $0.value.count, mine: $0.value.mine) }
            .sorted { $0.count > $1.count }
    }

    private var textContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            replyQuote
                .padding(.top, message.replyTo != nil ? 6 : 0)
                .padding(.horizontal, message.replyTo != nil ? 4 : 0)

            Text(message.isDeleted == true ? "Сообщение удалено" : (message.text ?? ""))
                .font(.system(size: message.isDeleted == true ? fontSize - 1 : fontSize))
                .foregroundStyle(
                    message.isDeleted == true
                        ? Color.textTertiary.opacity(0.6)
                        : (isMe && bubbleStyle == "gradient" ? Color.white : Color.textPrimary)
                )
                .italic(message.isDeleted == true)
                .tracking(-0.1)
                .lineSpacing(2)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
        }
        .background { bubbleBackground }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if isMe && bubbleStyle == "gradient" {
            ZStack {
                bubbleShape
                    .fill(LinearGradient(
                        colors: [Color(hex: "4A7CFF"), Color(hex: "7A4AFF")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                bubbleShape
                    .stroke(Color(hex: "6A9CFF").opacity(0.4), lineWidth: 1)
            }
        } else {
            ZStack {
                bubbleShape.fill(isMe ? myBubbleFill : theirBubbleFill)
                bubbleShape.stroke(isMe ? myBubbleBorder : theirBubbleBorder, lineWidth: 1)
            }
        }
    }

    private var imageContent: some View {
        Group {
            if let url = message.mediaFullURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable()
                            .scaledToFill()
                            .frame(maxWidth: 220, maxHeight: 280)
                            .clipShape(bubbleShape)
                            .overlay { bubbleShape.stroke(Color.white.opacity(0.08), lineWidth: 1) }
                            .onTapGesture { onImageTap?(url) }
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .padding(6)
                                    .background(Color.black.opacity(0.4), in: Circle())
                                    .padding(6)
                            }
                    case .failure:
                        imagePlaceholder
                    default:
                        imagePlaceholder
                            .overlay { ProgressView().tint(.white.opacity(0.4)) }
                    }
                }
            } else {
                imagePlaceholder
            }
        }
    }

    private var imagePlaceholder: some View {
        ZStack {
            isMe ? Color.bubbleMe : Color.bubbleThem
            Image(systemName: "photo")
                .foregroundStyle(Color.white.opacity(0.3))
        }
        .frame(width: 200, height: 200)
        .clipShape(bubbleShape)
        .overlay { bubbleShape.stroke(Color.white.opacity(0.08), lineWidth: 1) }
    }
}

// MARK: - Date Separator

struct DateSeparator: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.2))
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.04), in: Capsule())
            .frame(maxWidth: .infinity)
    }
}
