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
    var currentUserId: String?
    private(set) var hasMore = true
    private var nextCursor: String? = nil
    let chat: Chat

    init(chat: Chat) { self.chat = chat }

    // Convenience: IDs only
    var typingUserIds: Set<String> { Set(typingUsers.keys) }

    // Human-readable typing label
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
        if refresh { nextCursor = nil; hasMore = true }
        guard hasMore else { return }
        isLoading = true
        let cursor = nextCursor
        Task {
            do {
                let data = try await APIClient.shared.getMessages(chatId: chat.id, cursor: cursor, limit: 40)
                let msgs = data.messages.reversed() as [Message]
                if refresh { messages = msgs } else { messages.insert(contentsOf: msgs, at: 0) }
                nextCursor = data.nextCursor
                hasMore = data.nextCursor != nil
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
        WebSocketClient.shared.sendMessage(chatId: chat.id, text: trimmed, type: "TEXT")
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
                WebSocketClient.shared.sendMessage(chatId: chat.id, text: upload.url,
                                                   type: "IMAGE", mediaUrl: upload.url)
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

    func sendTyping() {
        let ud = UserDefaults.standard
        let enabled = ud.object(forKey: "h2v.typingIndicator") == nil || ud.bool(forKey: "h2v.typingIndicator")
        guard enabled, ensureConnected() else { return }
        WebSocketClient.shared.typingStart(chatId: chat.id)
    }
    func stopTyping() { WebSocketClient.shared.typingStop(chatId: chat.id) }

    func handleEvent(_ event: WSEvent) {
        switch event.type {
        // Messages
        case "message:new", "new_message":
            guard let msg = event.decodeMessage() else { return }
            let inThisChat = msg.chatId == chat.id
                || (msg.chatId == nil && event.chatId == chat.id)
            guard inThisChat else { return }
            if !messages.contains(where: { $0.id == msg.id }) {
                messages.append(msg)
            }

        case "message:deleted", "message_deleted":
            if let id = event.messageId { messages.removeAll { $0.id == id } }

        // Typing — server broadcasts "typing:started" / "typing:stopped"
        case "typing:started", "typing:start":
            guard let uid = event.userId, uid != currentUserId else { return }
            let eid = event.rawPayload["chatId"] as? String
            guard eid == chat.id else { return }
            let nick = event.rawPayload["nickname"] as? String
                ?? chat.members.first(where: { $0.userId == uid })?.user.nickname
                ?? uid
            typingUsers[uid] = nick
            // Auto-clear after 5s in case typing:stopped is missed
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

    // MARK: Private

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
                inputBar
            }
        }
        .animation(.easeInOut(duration: 0.22), value: vm.sendError)
        .navigationBarHidden(true)
        .onAppear {
            vm.currentUserId = appState.currentUser?.id
            appState.activeChatId = vm.chat.id
            vm.loadMessages(refresh: true)
            WebSocketClient.shared.onEvent = { [weak vm] event in
                Task { @MainActor in
                    vm?.handleEvent(event)
                    appState.handlePresence(event: event)
                }
            }
        }
        .onDisappear {
            appState.activeChatId = nil
            stopTypingNow()
            WebSocketClient.shared.onEvent = { [weak appState] event in
                Task { @MainActor in appState?.handlePresence(event: event) }
            }
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

                    if !vm.messages.isEmpty {
                        DateSeparator(text: "Сегодня")
                            .padding(.vertical, 8)
                    }

                    ForEach(Array(vm.messages.enumerated()), id: \.element.id) { idx, msg in
                        let isMe = msg.sender.id == (vm.currentUserId ?? "")
                        let prevMsg = idx > 0 ? vm.messages[idx - 1] : nil
                        let sameSender = prevMsg?.sender.id == msg.sender.id

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
            .onChange(of: vm.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom") }
            }
            .onChange(of: vm.typingLabel) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom") }
            }
            .onAppear { proxy.scrollTo("bottom") }
        }
    }

    @ViewBuilder
    private func contextMenuItems(msg: Message, isMe: Bool) -> some View {
        Button {
            UIPasteboard.general.string = msg.text
        } label: {
            Label("Копировать", systemImage: "doc.on.doc")
        }
        if isMe {
            Button(role: .destructive) { vm.deleteMessage(msg.id) } label: {
                Label("Удалить", systemImage: "trash")
            }
        }
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

                HStack(spacing: 3) {
                    Text(MessageTime.shortTime(from: message.createdAt))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.2))
                    if isMe {
                        let isRead = !(message.readReceipts?.isEmpty ?? true)
                        Image(systemName: isRead ? "checkmark.message" : "checkmark")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.white.opacity(0.3))
                    }
                }
                .padding(.horizontal, 4)
            }

            if !isMe { Spacer(minLength: 60) }
        }
    }

    private var textContent: some View {
        Text(message.text ?? "")
            .font(.system(size: fontSize))
            .foregroundStyle(isMe && bubbleStyle == "gradient"
                ? Color.white
                : Color.textPrimary)
            .tracking(-0.1)
            .lineSpacing(2)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
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
