import SwiftUI
import Photos
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - ChatViewModel
// Messages stored newest-first. ScrollView is flipped for natural chat UX.

@MainActor
class ChatViewModel: NSObject, ObservableObject, AVAudioRecorderDelegate {
    let chatId: String
    @Published var messages: [Message] = []      // newest first
    @Published var outbox: [OutboxMessage] = []
    @Published var isLoading = false
    @Published var hasMore = false
    @Published var inputText = ""
    @Published var replyTo: Message?
    @Published var editingMessage: Message?
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0

    @Published var searchText = ""
    @Published var searchActive = false
    @Published var searchResults: [String] = []
    @Published var searchIndex = 0

    @Published var showForwardPicker = false
    @Published var forwardingMessage: Message?

    @Published var showDeleteSheet: Message?
    @Published var errorMessage: String?

    private var nextCursor: String?
    private var audioRecorder: AVAudioRecorder?
    private var recordingTimer: Timer?
    private var recordingURL: URL?
    private var pendingRecordingDuration: TimeInterval = 0

    override init() {
        self.chatId = ""
        super.init()
    }

    init(chatId: String) {
        self.chatId = chatId
        super.init()
    }

    // MARK: - Load

    func loadMessages() {
        let cached = CacheManager.shared.loadMessages(chatId: chatId)
        if !cached.isEmpty && messages.isEmpty {
            messages = cached
            markNewestAsRead()
        }

        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let data = try await APIClient.shared.getMessages(chatId: chatId)
                messages = data.messages
                nextCursor = data.nextCursor
                hasMore = data.nextCursor != nil
                CacheManager.shared.saveMessages(data.messages, chatId: chatId)
                markNewestAsRead()
            } catch {
                if messages.isEmpty {
                    errorMessage = error.localizedDescription
                }
                print("❌ loadMessages(\(chatId)) error: \(error)")
            }
            isLoading = false
        }
    }

    private var loadMoreDebounce = false

    func loadMore() {
        guard !isLoading, !loadMoreDebounce, hasMore, let cursor = nextCursor else { return }
        isLoading = true
        loadMoreDebounce = true
        Task {
            do {
                let data = try await APIClient.shared.getMessages(chatId: chatId, cursor: cursor, limit: 30)
                messages.append(contentsOf: data.messages)
                nextCursor = data.nextCursor
                hasMore = data.nextCursor != nil
                CacheManager.shared.appendMessages(data.messages, chatId: chatId)
            } catch {
                print("❌ loadMore error: \(error)")
            }
            isLoading = false
            try? await Task.sleep(nanoseconds: 300_000_000)
            loadMoreDebounce = false
        }
    }

    // MARK: - WebSocket

    private var wsSubscribed = false

    func subscribeWS() {
        guard !wsSubscribed else { return }
        wsSubscribed = true
        WebSocketClient.shared.addListener(id: "chat_\(chatId)") { [weak self] event in
            Task { @MainActor [weak self] in self?.handleEvent(event) }
        }
    }

    func unsubscribeWS() {
        WebSocketClient.shared.removeListener(id: "chat_\(chatId)")
        wsSubscribed = false
    }

    private func handleEvent(_ event: WSEvent) {
        let msgChatId = event.chatId ?? event.decodeMessage()?.chatId
        guard msgChatId == chatId else { return }

        switch event.event {
        case "message:new":
            guard let msg = event.decodeMessage() else { return }
            if let obIdx = outbox.firstIndex(where: { $0.text == msg.text && $0.type == msg.type }) {
                outbox.remove(at: obIdx)
            }
            if !messages.contains(where: { $0.id == msg.id }) {
                messages.insert(msg, at: 0)
                markNewestAsRead()
                CacheManager.shared.saveMessages(messages, chatId: chatId)
            }
        case "message:edited":
            guard let msg = event.decodeMessage() else { return }
            if let idx = messages.firstIndex(where: { $0.id == msg.id }) {
                messages[idx] = msg
            }
        case "message:deleted":
            if let msgId = event.messageId {
                messages.removeAll { $0.id == msgId }
            }
        case "reaction:added":
            if let msgId = event.messageId,
               let idx = messages.firstIndex(where: { $0.id == msgId }),
               let data = try? JSONSerialization.data(withJSONObject: event.payload["reaction"] ?? [:]),
               let reaction = try? JSONDecoder().decode(Reaction.self, from: data) {
                messages[idx].reactions = (messages[idx].reactions ?? []) + [reaction]
            }
        case "reaction:removed":
            if let msgId = event.messageId,
               let idx = messages.firstIndex(where: { $0.id == msgId }),
               let uid = event.payload["userId"] as? String,
               let emoji = event.payload["emoji"] as? String {
                messages[idx].reactions?.removeAll { $0.userId == uid && $0.emoji == emoji }
            }
        case "message:read":
            if let msgId = event.messageId,
               let readBy = event.payload["readBy"] as? String,
               let idx = messages.firstIndex(where: { $0.id == msgId }) {
                var receipts = messages[idx].readReceipts ?? []
                if !receipts.contains(where: { $0.userId == readBy }) {
                    receipts.append(ReadReceipt(userId: readBy, readAt: ISO8601DateFormatter().string(from: Date())))
                    messages[idx].readReceipts = receipts
                }
            }
        default: break
        }
    }

    func markAsReadOnExit() {
        markNewestAsRead()
    }

    private func markNewestAsRead() {
        guard let newest = messages.first else { return }
        WebSocketClient.shared.markRead(messageId: newest.id, chatId: chatId)
        Task {
            try? await APIClient.shared.markRead(messageId: newest.id)
        }
    }

    // MARK: - Send with Outbox

    func sendText() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if let editing = editingMessage {
            Task { try? await APIClient.shared.editMessage(id: editing.id, text: text) }
            editingMessage = nil
        } else {
            let ob = OutboxMessage(id: UUID().uuidString, chatId: chatId, text: text,
                                   type: .text, replyToId: replyTo?.id,
                                   status: .sending, createdAt: Date())
            outbox.insert(ob, at: 0)
            WebSocketClient.shared.sendMessage(chatId: chatId, text: text, replyToId: replyTo?.id)
            replyTo = nil
        }
        inputText = ""
    }

    func deleteMessage(_ msg: Message, forEveryone: Bool) {
        Task { try? await APIClient.shared.deleteMessage(id: msg.id, forEveryone: forEveryone) }
    }

    func startEditing(_ msg: Message) {
        editingMessage = msg
        inputText = msg.text ?? ""
    }

    func toggleReaction(messageId: String, emoji: String, myId: String) {
        guard let idx = messages.firstIndex(where: { $0.id == messageId }) else { return }
        let existing = messages[idx].reactions?.first(where: { $0.userId == myId && $0.emoji == emoji })
        Task {
            if existing != nil {
                try? await APIClient.shared.removeReaction(messageId: messageId, emoji: emoji)
            } else {
                try? await APIClient.shared.addReaction(messageId: messageId, emoji: emoji)
            }
        }
    }

    func pinMessage(_ msg: Message) {
        Task { _ = try? await APIClient.shared.pinMessage(chatId: chatId, messageId: msg.id) }
    }

    func unpinMessage() {
        Task { _ = try? await APIClient.shared.pinMessage(chatId: chatId, messageId: nil) }
    }

    func forwardMessage(_ msg: Message, toChatId: String, senderName: String) {
        WebSocketClient.shared.sendMessage(
            chatId: toChatId, text: msg.text ?? "", type: msg.type.rawValue,
            mediaUrl: msg.mediaUrl, mediaName: msg.mediaName, mediaSize: msg.mediaSize,
            forwardedFromId: msg.id, forwardSenderName: senderName
        )
    }

    func performSearch() {
        let q = searchText.lowercased()
        guard !q.isEmpty else { searchResults = []; return }
        searchResults = messages.filter { ($0.text ?? "").lowercased().contains(q) }.map(\.id)
        searchIndex = 0
    }

    // MARK: - Voice Recording (with Outbox)

    func startRecording() {
        NSLog("[H2V Voice] startRecording called")
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try audioSession.setActive(true)
        } catch {
            NSLog("[H2V Voice] audioSession error: %@", error.localizedDescription)
            return
        }

        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docDir.appendingPathComponent("h2v_voice_\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true
            let started = audioRecorder?.record() ?? false
            NSLog("[H2V Voice] record started=%d inputAvail=%d url=%@",
                  started ? 1 : 0,
                  audioSession.isInputAvailable ? 1 : 0,
                  url.lastPathComponent)
            recordingURL = url
            isRecording = true
            recordingDuration = 0
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let rec = self.audioRecorder else { return }
                    self.recordingDuration = rec.currentTime
                }
            }
        } catch {
            NSLog("[H2V Voice] AVAudioRecorder init error: %@", error.localizedDescription)
        }
    }

    func stopRecording() {
        pendingRecordingDuration = recordingDuration
        audioRecorder?.stop()
        recordingTimer?.invalidate(); recordingTimer = nil
        isRecording = false
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        NSLog("[H2V Voice] delegate didFinishRecording success=%d", flag ? 1 : 0)
        Task { @MainActor in
            self.processRecordedFile(recorder: recorder, success: flag)
        }
    }

    private func processRecordedFile(recorder: AVAudioRecorder, success: Bool) {
        let fileURL = recorder.url
        guard success else {
            NSLog("[H2V Voice] recording failed")
            audioRecorder = nil
            return
        }
        audioRecorder = nil

        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attrs?[.size] as? Int) ?? 0
        NSLog("[H2V Voice] DONE file=%@ diskSize=%d success=%d", fileURL.lastPathComponent, fileSize, success ? 1 : 0)

        guard let data = try? Data(contentsOf: fileURL), data.count > 100 else {
            NSLog("[H2V Voice] file too small or unreadable")
            return
        }

        var duration = pendingRecordingDuration
        if let fp = try? AVAudioPlayer(contentsOf: fileURL), fp.duration > 0.1 {
            duration = fp.duration
            NSLog("[H2V Voice] AVAudioPlayer duration=%.2f", fp.duration)
        }
        if duration < 0.1 { duration = pendingRecordingDuration }
        NSLog("[H2V Voice] finalDuration=%.2f dataSize=%d", duration, data.count)

        let waveform = WaveformGenerator.generate(from: data, barCount: 32)
        let chatIdCopy = chatId
        let obId = UUID().uuidString
        var ob = OutboxMessage(id: obId, chatId: chatIdCopy, text: "",
                               type: .audio, mediaData: data,
                               mediaFilename: fileURL.lastPathComponent, mediaMimeType: "audio/mp4",
                               localMediaURL: fileURL, status: .uploading, createdAt: Date())
        ob.voiceDuration = duration
        ob.waveform = waveform
        outbox.insert(ob, at: 0)

        Task {
            do {
                let result = try await APIClient.shared.upload(
                    fileData: data, filename: fileURL.lastPathComponent, mimeType: "audio/mp4"
                )
                await MainActor.run {
                    if let idx = self.outbox.firstIndex(where: { $0.id == obId }) {
                        self.outbox[idx].status = .sending
                    }
                }
                WebSocketClient.shared.sendMessage(
                    chatId: chatIdCopy, text: "", type: "AUDIO",
                    mediaUrl: result.url, mediaName: result.name, mediaSize: result.size
                )
            } catch {
                await MainActor.run {
                    if let idx = self.outbox.firstIndex(where: { $0.id == obId }) {
                        self.outbox[idx].status = .failed
                        self.outbox[idx].error = error.localizedDescription
                    }
                }
            }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    

    func cancelRecording() {
        audioRecorder?.stop(); audioRecorder = nil
        recordingTimer?.invalidate(); recordingTimer = nil
        isRecording = false
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Media Upload (with Outbox)

    func uploadAndSend(data: Data, filename: String, mimeType: String, type: String) {
        let msgType = MessageType(rawValue: type) ?? .file
        let obId = UUID().uuidString
        let ob = OutboxMessage(id: obId, chatId: chatId, text: "", type: msgType,
                               mediaData: data, mediaFilename: filename, mediaMimeType: mimeType,
                               replyToId: replyTo?.id, status: .uploading, createdAt: Date())
        outbox.insert(ob, at: 0)
        let replyId = replyTo?.id
        replyTo = nil

        Task {
            do {
                let result = try await APIClient.shared.upload(
                    fileData: data, filename: filename, mimeType: mimeType
                )
                NSLog("[H2V Upload] OK type=%@ url=%@ name=%@ size=%d", result.type, result.url, result.name, result.size)
                if let idx = outbox.firstIndex(where: { $0.id == obId }) {
                    outbox[idx].status = .sending
                }
                let sendType = result.type
                WebSocketClient.shared.sendMessage(
                    chatId: chatId, text: "", type: sendType,
                    mediaUrl: result.url, mediaName: result.name, mediaSize: result.size,
                    replyToId: replyId
                )
            } catch {
                NSLog("[H2V Upload] FAIL: %@", error.localizedDescription)
                if let idx = outbox.firstIndex(where: { $0.id == obId }) {
                    outbox[idx].status = .failed
                    outbox[idx].error = error.localizedDescription
                }
            }
        }
    }

    func retryOutbox(_ ob: OutboxMessage) {
        outbox.removeAll { $0.id == ob.id }
        if let data = ob.mediaData, let fn = ob.mediaFilename, let mime = ob.mediaMimeType {
            uploadAndSend(data: data, filename: fn, mimeType: mime, type: ob.type.rawValue)
        } else if !ob.text.isEmpty {
            inputText = ob.text
            sendText()
        }
    }

    func removeOutbox(_ id: String) {
        outbox.removeAll { $0.id == id }
    }
}

// MARK: - ChatView

struct ChatView: View {
    let chat: Chat
    @StateObject private var vm: ChatViewModel
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    @State private var showProfile = false
    @State private var showMediaGallery = false
    @State private var showDocumentPicker = false
    @State private var mediaViewerCtx: MediaViewerContext?
    @FocusState private var inputFocused: Bool

    private var myId: String { appState.currentUser?.id ?? "" }

    init(chat: Chat) {
        self.chat = chat
        _vm = StateObject(wrappedValue: ChatViewModel(chatId: chat.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            chatHeader

            if let pinnedId = chat.pinnedMessageId,
               let pinnedMsg = vm.messages.first(where: { $0.id == pinnedId }) {
                pinnedBanner(pinnedMsg)
            }

            if chat.type == .secret {
                e2eBanner
            }

            if vm.searchActive {
                searchBar
            }

            if let error = vm.errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28))
                            .foregroundColor(.warning)
                    Text("Ошибка загрузки")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.textPrimary)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                    Button("Повторить") { vm.loadMessages() }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.h2vAccent)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                messagesList
            }
            inputBar
        }
        .background(Color.bgApp.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            vm.loadMessages()
            vm.subscribeWS()
        }
        .onDisappear {
            vm.markAsReadOnExit()
            vm.unsubscribeWS()
        }
        .onChange(of: vm.inputText) { _, _ in
            WebSocketClient.shared.typingStart(chatId: chat.id)
        }
        .sheet(isPresented: $showProfile) {
            NavigationStack {
                if chat.type == .group {
                    GroupProfileView(chat: chat).environmentObject(appState)
                } else if chat.type == .self_ {
                    Text("Избранное").font(.title2.bold()).foregroundColor(.textPrimary)
                } else if let other = chat.otherUser(myId: myId) {
                    UserProfileView(user: other, chatId: chat.id).environmentObject(appState)
                }
            }
        }
        .sheet(isPresented: $vm.showForwardPicker) {
            NavigationStack {
                ForwardPickerView(message: vm.forwardingMessage) { toChatId in
                    if let msg = vm.forwardingMessage {
                        let senderName = msg.sender?.displayName ?? "?"
                        vm.forwardMessage(msg, toChatId: toChatId, senderName: senderName)
                    }
                    vm.showForwardPicker = false
                }
                .environmentObject(appState)
            }
        }
        .confirmationDialog("Удалить сообщение", isPresented: Binding(
            get: { vm.showDeleteSheet != nil },
            set: { if !$0 { vm.showDeleteSheet = nil } }
        )) {
            if let msg = vm.showDeleteSheet {
                if msg.sender?.id == myId {
                    Button("Удалить у всех", role: .destructive) {
                        vm.deleteMessage(msg, forEveryone: true)
                    }
                }
                Button("Удалить у меня", role: .destructive) {
                    vm.deleteMessage(msg, forEveryone: false)
                }
                Button("Отмена", role: .cancel) {}
            }
        }
        .fullScreenCover(item: $mediaViewerCtx) { ctx in
            MediaViewerView(urls: ctx.urls, startIndex: ctx.startIndex)
        }
    }

    // MARK: - Header

    private var chatHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.h2vAccent)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }

                Button { showProfile = true } label: {
                    HStack(spacing: 10) {
                        AvatarView(url: chat.chatAvatarURL(myId: myId),
                                   initials: chat.chatInitials(myId: myId),
                                   size: 38, id: chat.id)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                if chat.type == .secret {
                                    Image(systemName: "lock.fill").font(.system(size: 10)).foregroundColor(.success)
                                }
                                Text(chat.displayName(myId: myId))
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.textPrimary)
                                    .lineLimit(1)
                            }
                            chatSubtitle
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Button { vm.searchActive.toggle() } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16))
                        .foregroundColor(.textSecondary)
                        .frame(width: 32, height: 32)
                }

                Menu {
                    if chat.type == .direct || chat.type == .secret {
                        Button { showProfile = true } label: {
                            Label("Профиль", systemImage: "person")
                        }
                    }
                    if chat.type == .group {
                        Button { showProfile = true } label: {
                            Label("Инфо о группе", systemImage: "person.3")
                        }
                    }
                    Button { vm.searchActive = true } label: {
                        Label("Поиск", systemImage: "magnifyingglass")
                    }
                    Divider()
                    Button { MutedStore.shared.toggle(chat.id) } label: {
                        Label(MutedStore.shared.isMuted(chat.id) ? "Вкл. звук" : "Без звука",
                              systemImage: MutedStore.shared.isMuted(chat.id) ? "bell" : "bell.slash")
                    }
                    if chat.type == .group {
                        Button(role: .destructive) {
                            Task {
                                try? await APIClient.shared.leaveChat(id: chat.id)
                                dismiss()
                            }
                        } label: {
                            Label("Покинуть", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } else {
                        Button(role: .destructive) {
                            Task {
                                try? await APIClient.shared.deleteChat(id: chat.id)
                                dismiss()
                            }
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16))
                        .foregroundColor(.textSecondary)
                        .frame(width: 32, height: 32)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider().foregroundColor(.borderPrimary)
        }
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var chatSubtitle: some View {
        let typingNames = appState.typingNicknames(chatId: chat.id)
        if !typingNames.isEmpty {
            Text("печатает...")
                .font(.system(size: 12)).foregroundColor(.h2vAccent)
        } else if chat.type == .group {
            Text("\(chat.members.count) участников")
                .font(.system(size: 12)).foregroundColor(.textSecondary)
        } else if chat.type == .self_ {
            Text("\(vm.messages.count) сообщений")
                .font(.system(size: 12)).foregroundColor(.textSecondary)
        } else if let other = chat.otherUser(myId: myId) {
            if appState.isUserOnline(other.id) {
                Text("онлайн").font(.system(size: 12)).foregroundColor(.success)
            } else {
                Text(DateHelper.lastSeen(other.lastOnline))
                    .font(.system(size: 12)).foregroundColor(.textSecondary)
            }
        }
    }

    // MARK: - E2E Banner

    private var e2eBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 14))
                .foregroundColor(.success)
            Text("Сообщения зашифрованы end-to-end")
                .font(.system(size: 12))
                .foregroundColor(.success)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.success.opacity(0.08))
    }

    // MARK: - Pinned Message

    private func pinnedBanner(_ msg: Message) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "pin.fill")
                .font(.system(size: 12))
                .foregroundColor(.h2vAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Закреплённое")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.h2vAccent)
                Text(msg.text ?? "Медиа")
                    .font(.system(size: 12))
                    .foregroundColor(.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button { vm.unpinMessage() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
                    .foregroundColor(.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.bgSurface)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.textTertiary)

                    TextField("", text: $vm.searchText,
                              prompt: Text("Поиск в чате...").foregroundColor(.textTertiary))
                        .foregroundColor(.textPrimary)
                        .font(.system(size: 15))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { vm.performSearch() }

                    if !vm.searchText.isEmpty {
                        Button {
                            vm.searchText = ""
                            vm.searchResults = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.textTertiary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.bgElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button {
                    vm.searchActive = false
                    vm.searchText = ""
                    vm.searchResults = []
                } label: {
                    Text("Отмена")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.h2vAccent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.bgSurface)

            if !vm.searchResults.isEmpty {
                HStack(spacing: 0) {
                    Text("\(vm.searchIndex + 1) из \(vm.searchResults.count)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.textSecondary)

                    Spacer()

                    HStack(spacing: 16) {
                        Button {
                            if vm.searchIndex > 0 { vm.searchIndex -= 1 }
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(vm.searchIndex > 0 ? .h2vAccent : .textTertiary)
                        }
                        .disabled(vm.searchIndex <= 0)

                        Button {
                            if vm.searchIndex < vm.searchResults.count - 1 { vm.searchIndex += 1 }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(vm.searchIndex < vm.searchResults.count - 1 ? .h2vAccent : .textTertiary)
                        }
                        .disabled(vm.searchIndex >= vm.searchResults.count - 1)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.bgCard)
            } else if !vm.searchText.isEmpty {
                HStack {
                    Text("Нет результатов")
                        .font(.system(size: 12))
                        .foregroundColor(.textTertiary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.bgCard)
            }

            Divider().background(Color.borderPrimary)
        }
    }

    // MARK: - Messages List (Reversed ScrollView)
    // messages[0] = newest (visually bottom), messages[N] = oldest (visually top)
    // ScrollView is flipped so scroll starts at newest. loadMore appends at end = no jump.

    @State private var scrollProxy: ScrollViewProxy?

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(vm.outbox) { ob in
                        outboxBubble(ob)
                            .scaleEffect(x: 1, y: -1)
                            .id("ob_\(ob.id)")
                    }

                    ForEach(Array(vm.messages.enumerated()), id: \.element.id) { index, msg in
                        let showDate = shouldShowDate(at: index)
                        let showSender = shouldShowSender(at: index)
                        let isHighlighted = vm.searchResults.indices.contains(vm.searchIndex) &&
                            vm.searchResults[vm.searchIndex] == msg.id

                        VStack(spacing: 4) {
                            MessageBubble(
                                message: msg,
                                isMine: msg.sender?.id == myId,
                                showSender: showSender && chat.type == .group,
                                myId: myId,
                                isHighlighted: isHighlighted,
                                onReply: { vm.replyTo = msg },
                                onEdit: { vm.startEditing(msg) },
                                onDelete: { vm.showDeleteSheet = msg },
                                onReaction: { emoji in
                                    vm.toggleReaction(messageId: msg.id, emoji: emoji, myId: myId)
                                },
                                onMediaTap: { url in openMediaViewer(tappedURL: url) },
                                onCopy: {
                                    UIPasteboard.general.string = msg.text ?? ""
                                },
                                onPin: { vm.pinMessage(msg) },
                                onForward: {
                                    vm.forwardingMessage = msg
                                    vm.showForwardPicker = true
                                }
                            )
                            if showDate { dateSeparator(msg.createdAt) }
                        }
                        .scaleEffect(x: 1, y: -1)
                        .id(msg.id)
                    }

                    if vm.isLoading && vm.messages.isEmpty {
                        ProgressView().padding()
                            .scaleEffect(x: 1, y: -1)
                    }

                    if vm.hasMore && vm.isLoading {
                        ProgressView().scaleEffect(0.7).padding(4)
                            .scaleEffect(x: 1, y: -1)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .scaleEffect(x: 1, y: -1)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { geo in
                let maxScroll = geo.contentSize.height - geo.containerSize.height
                return maxScroll > 50 && geo.contentOffset.y >= maxScroll - 400
            } action: { _, isNearEnd in
                if isNearEnd { vm.loadMore() }
            }
            .onAppear { scrollProxy = proxy }
            .onChange(of: vm.searchIndex) { _, idx in
                if vm.searchResults.indices.contains(idx) {
                    withAnimation { proxy.scrollTo(vm.searchResults[idx], anchor: .center) }
                }
            }
            .onTapGesture { inputFocused = false }
        }
    }

    private func shouldShowDate(at index: Int) -> Bool {
        guard index < vm.messages.count - 1 else { return true }
        let current = vm.messages[index].createdDate
        let older = vm.messages[index + 1].createdDate
        return !Calendar.current.isDate(current, inSameDayAs: older)
    }

    private func shouldShowSender(at index: Int) -> Bool {
        guard index < vm.messages.count - 1 else { return true }
        return vm.messages[index].sender?.id != vm.messages[index + 1].sender?.id
    }

    // MARK: - Outbox Bubble

    private func outboxBubble(_ ob: OutboxMessage) -> some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 4) {
                if ob.type == .audio {
                    outboxVoiceBubble(ob)
                } else {
                    outboxGenericBubble(ob)
                }

                if ob.status == .failed {
                    HStack(spacing: 12) {
                        Button { vm.retryOutbox(ob) } label: {
                            Text("Повторить").font(.system(size: 11, weight: .medium)).foregroundColor(.h2vAccent)
                        }
                        Button { vm.removeOutbox(ob.id) } label: {
                            Text("Удалить").font(.system(size: 11)).foregroundColor(.textTertiary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 1)
    }

    private func outboxVoiceBubble(_ ob: OutboxMessage) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(LinearGradient.accentGradient)
                    .frame(width: 38, height: 38)

                if ob.status == .failed {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.7)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                WaveformView(
                    bars: ob.waveform,
                    progress: 0,
                    accentColor: Color.h2vAccent,
                    barCount: 32
                )
                .frame(height: 20)
                .opacity(0.6)

                HStack(spacing: 6) {
                    Text(formatDuration(ob.voiceDuration))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.textTertiary)

                    Text(DateHelper.time(ob.createdAtString))
                        .font(.system(size: 10))
                        .foregroundColor(.textTertiary)

                    Image(systemName: "clock")
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.3))
                }
            }
            .frame(minWidth: 140)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.h2vAccent.opacity(ob.status == .failed ? 0.08 : 0.15))
        )
    }

    @ViewBuilder
    private func outboxGenericBubble(_ ob: OutboxMessage) -> some View {
        if ob.type == .image, let data = ob.mediaData, let uiImg = UIImage(data: data) {
            ZStack(alignment: .bottomTrailing) {
                Image(uiImage: uiImg)
                    .resizable().scaledToFit()
                    .frame(maxWidth: 260, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .opacity(ob.status == .failed ? 0.5 : 0.8)

                HStack(spacing: 4) {
                    if ob.status == .failed {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 10)).foregroundColor(.danger)
                    } else {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.5)
                    }
                    Text(DateHelper.time(ob.createdAtString))
                        .font(.system(size: 10)).foregroundColor(.white)
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(6)
            }
        } else if ob.type == .video {
            ZStack(alignment: .center) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.bgCard)
                    .frame(width: 200, height: 150)
                Image(systemName: "video.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.white.opacity(0.5))
                if ob.status == .failed {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 20)).foregroundColor(.danger)
                } else {
                    ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                }
            }
        } else {
            HStack(alignment: .bottom, spacing: 6) {
                if !ob.text.isEmpty {
                    Text(ob.text)
                        .font(.system(size: 14))
                        .foregroundColor(.textPrimary)
                } else if let fn = ob.mediaFilename {
                    Image(systemName: "doc.fill").font(.system(size: 14)).foregroundColor(.h2vAccent)
                    Text(fn)
                        .font(.system(size: 13))
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                }

                if ob.status == .failed {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12)).foregroundColor(.danger)
                } else {
                    ProgressView().scaleEffect(0.6)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.h2vAccent.opacity(ob.status == .failed ? 0.08 : 0.15))
            )
        }
    }

    private func dateSeparator(_ dateStr: String) -> some View {
        Text(DateHelper.dateSeparator(dateStr))
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(Color.bgSurface.opacity(0.9), in: Capsule())
            .padding(.vertical, 8)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider().foregroundColor(.borderPrimary)

            if let reply = vm.replyTo {
                replyBar(reply)
            }
            if let editing = vm.editingMessage {
                editBar(editing)
            }

            HStack(spacing: 8) {
                if vm.isRecording {
                    recordingBarContent
                } else {
                    attachButton
                    textInput
                }
                sendOrVoiceButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(Color.bgSurface.ignoresSafeArea(.container, edges: .bottom))
    }

    private func replyBar(_ msg: Message) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.h2vAccent)
                .frame(width: 3, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(msg.sender?.displayName ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.h2vAccent)
                Text(msg.text ?? "Медиа")
                    .font(.system(size: 12))
                    .foregroundColor(.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button { vm.replyTo = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14))
                    .foregroundColor(.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.bgCard)
    }

    private func editBar(_ msg: Message) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil").foregroundColor(.h2vAccent)
            Text("Редактирование")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.h2vAccent)
            Spacer()
            Button { vm.editingMessage = nil; vm.inputText = "" } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14))
                    .foregroundColor(.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.bgCard)
    }

    private var attachButton: some View {
        Button { showMediaGallery = true } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.textSecondary)
                .frame(width: 40, height: 40)
                .background(Color.bgCard, in: Circle())
        }
        .sheet(isPresented: $showMediaGallery) {
            MediaGalleryPicker(
                onSendPhotos: { assets in handleSelectedAssets(assets) },
                onPickDocument: { showDocumentPicker = true }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPickerView { data, filename, mime in
                vm.uploadAndSend(data: data, filename: filename, mimeType: mime, type: "FILE")
            }
        }
    }

    @State private var showFormatBar = false

    private var textInput: some View {
        VStack(spacing: 0) {
            if showFormatBar && inputFocused {
                formatToolbar
            }

            TextField("", text: $vm.inputText,
                      prompt: Text("Сообщение...").foregroundColor(.textTertiary),
                      axis: .vertical)
                .foregroundColor(.textPrimary)
                .font(.system(size: 14))
                .lineLimit(1...6)
                .focused($inputFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.bgCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.borderPrimary, lineWidth: 0.5)
                }
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Button {
                            showFormatBar.toggle()
                        } label: {
                            Image(systemName: "textformat")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(showFormatBar ? .h2vAccent : .textSecondary)
                        }
                        Spacer()
                    }
                }
        }
    }

    private var formatToolbar: some View {
        HStack(spacing: 2) {
            formatBtn("bold", wrap: "**")
            formatBtn("italic", wrap: "*")
            formatBtn("strikethrough", wrap: "~~")
            formatBtn("chevron.left.forwardslash.chevron.right", wrap: "`")
            formatBtn("underline", wrap: "<u>", closeTag: "</u>")

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.bgCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.bottom, 4)
    }

    private func formatBtn(_ icon: String, wrap: String, closeTag: String? = nil) -> some View {
        Button {
            let close = closeTag ?? wrap
            vm.inputText += "\(wrap)\(close)"
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.textSecondary)
                .frame(width: 36, height: 32)
                .background(Color.bgElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var hasText: Bool {
        !vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.editingMessage != nil
    }

    // MARK: - Voice: Telegram-style hold-to-record

    @State private var voiceDragOffset: CGSize = .zero
    @State private var voiceLocked = false
    @State private var recPulse = false

    private var sendOrVoiceButton: some View {
        Group {
            if hasText && !vm.isRecording {
                Button { vm.sendText() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 42, height: 42)
                        .background(LinearGradient.accentGradient, in: Circle())
                        .shadow(color: Color.h2vAccent.opacity(0.3), radius: 8, y: 2)
                }
            } else if vm.isRecording && voiceLocked {
                Button {
                    vm.stopRecording()
                    withAnimation(.spring(response: 0.3)) { voiceLocked = false; voiceDragOffset = .zero }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 42, height: 42)
                        .background(LinearGradient.accentGradient, in: Circle())
                        .shadow(color: Color.h2vAccent.opacity(0.3), radius: 8, y: 2)
                }
                .transition(.scale.combined(with: .opacity))
            } else {
                voiceMicButton
            }
        }
        .animation(.easeInOut(duration: 0.15), value: hasText)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: vm.isRecording)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: voiceLocked)
    }

    private var voiceMicButton: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 18))
            .foregroundColor(.white)
            .frame(width: 42, height: 42)
            .background(
                Circle().fill(
                    vm.isRecording
                        ? AnyShapeStyle(Color.danger)
                        : AnyShapeStyle(LinearGradient.accentGradient)
                )
            )
            .shadow(color: (vm.isRecording ? Color.danger : Color.h2vAccent).opacity(0.3), radius: 8, y: 2)
            .scaleEffect(vm.isRecording ? 1.25 : 1.0)
            .offset(voiceLocked ? .zero : voiceDragOffset)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !vm.isRecording {
                            vm.startRecording()
                            voiceLocked = false
                        }
                        let dx = value.translation.width
                        let dy = value.translation.height

                        if dy < -60 && !voiceLocked {
                            withAnimation(.spring(response: 0.3)) {
                                voiceLocked = true
                                voiceDragOffset = .zero
                            }
                            return
                        }

                        if !voiceLocked {
                            voiceDragOffset = CGSize(
                                width: min(0, max(-140, dx)),
                                height: min(0, max(-80, dy))
                            )
                        }
                    }
                    .onEnded { _ in
                        if voiceLocked { return }

                        if voiceDragOffset.width < -100 {
                            vm.cancelRecording()
                        } else if vm.isRecording {
                            vm.stopRecording()
                        }
                        withAnimation(.spring(response: 0.3)) { voiceDragOffset = .zero }
                    }
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: vm.isRecording)
    }

    private var recordingBarContent: some View {
        HStack(spacing: 0) {
            if voiceLocked {
                Button {
                    vm.cancelRecording()
                    withAnimation(.spring(response: 0.3)) { voiceLocked = false; voiceDragOffset = .zero }
                } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.danger)
                        .frame(width: 36, height: 36)
                        .background(Color.danger.opacity(0.12), in: Circle())
                }
                .transition(.scale.combined(with: .opacity))
            } else {
                cancelHint
            }

            Spacer(minLength: 4)

            HStack(spacing: 8) {
                Circle()
                    .fill(Color.danger)
                    .frame(width: 9, height: 9)
                    .scaleEffect(recPulse ? 1.0 : 0.5)
                    .opacity(recPulse ? 1.0 : 0.3)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: recPulse)

                Text(formatRecordingTime(vm.recordingDuration))
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundColor(.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }

            Spacer(minLength: 4)

            if !voiceLocked {
                lockHint
            }
        }
        .onAppear { recPulse = true }
        .onDisappear { recPulse = false }
        .transition(.opacity.combined(with: .move(edge: .leading)))
    }

    private var cancelHint: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.left")
                .font(.system(size: 10, weight: .bold))
            Text("Отмена")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundColor(.textTertiary)
        .opacity(voiceDragOffset.width < -20 ? 1.0 : 0.5)
        .frame(width: 70)
    }

    private var lockHint: some View {
        VStack(spacing: 2) {
            Image(systemName: "lock.fill")
                .font(.system(size: 12))
            Image(systemName: "chevron.up")
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundColor(.textTertiary)
        .opacity(voiceDragOffset.height < -20 ? 1.0 : 0.4)
        .frame(width: 36, height: 36)
    }

    private func openMediaViewer(tappedURL: URL) {
        let allMedia: [URL] = vm.messages
            .reversed()
            .compactMap { msg -> URL? in
                guard msg.type == .image || msg.type == .video,
                      let url = msg.mediaFullURL else { return nil }
                return url
            }
        let idx = allMedia.firstIndex(of: tappedURL) ?? 0
        mediaViewerCtx = MediaViewerContext(urls: allMedia, startIndex: idx)
    }

    private func formatRecordingTime(_ dur: TimeInterval) -> String {
        let totalMs = Int(dur * 100)
        let mins = totalMs / 6000
        let secs = (totalMs / 100) % 60
        let cs = totalMs % 100
        return String(format: "%d:%02d,%02d", mins, secs, cs)
    }

    private func formatDuration(_ dur: TimeInterval) -> String {
        let mins = Int(dur) / 60; let secs = Int(dur) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func handleSelectedAssets(_ assets: [PHAsset]) {
        for asset in assets {
            loadAssetData(asset) { data, filename, mime in
                guard let data else { return }
                let type = asset.mediaType == .video ? "VIDEO" : "IMAGE"
                DispatchQueue.main.async {
                    vm.uploadAndSend(data: data, filename: filename, mimeType: mime, type: type)
                }
            }
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: Message
    let isMine: Bool
    var showSender: Bool = false
    let myId: String
    var isHighlighted: Bool = false
    var onReply: () -> Void = {}
    var onEdit: () -> Void = {}
    var onDelete: () -> Void = {}
    var onReaction: (String) -> Void = { _ in }
    var onMediaTap: (URL) -> Void = { _ in }
    var onCopy: () -> Void = {}
    var onPin: () -> Void = {}
    var onForward: () -> Void = {}

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 60) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
                if showSender, let sender = message.sender {
                    Text(sender.displayName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color(hex: "c4b5fd"))
                        .padding(.horizontal, 8)
                }

                if let reply = message.replyTo { replyQuote(reply) }
                if message.forwardedFromId != nil { forwardHeader }

                bubbleContent.contextMenu { messageMenu }

                reactionsRow
            }
            if !isMine { Spacer(minLength: 60) }
        }
        .padding(.vertical, 1)
        .background(isHighlighted ? Color.h2vAccent.opacity(0.12) : Color.clear,
                     in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if message.deleted { deletedBubble }
        else {
            switch message.type {
            case .image: imageBubble
            case .video: videoBubble
            case .audio: voiceBubble
            case .file:  fileBubble
            case .system: systemMessage
            default: textBubble
            }
        }
    }

    private var textBubble: some View {
        HStack(alignment: .bottom, spacing: 6) {
            RichTextView(message.text ?? "")
            messageTime
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(bubbleBackground)
    }

    private var deletedBubble: some View {
        HStack(spacing: 6) {
            Image(systemName: "nosign").font(.system(size: 12))
            Text("Сообщение удалено").font(.system(size: 13)).italic()
        }
        .foregroundColor(.textTertiary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(bubbleBackground)
    }

    private var imageBubble: some View {
        ZStack(alignment: .bottomTrailing) {
            if let url = message.mediaFullURL {
                CachedAsyncImage(url: url) { img in
                    img.resizable().scaledToFit().frame(maxWidth: 260, maxHeight: 280)
                } placeholder: {
                    ProgressView().frame(width: 200, height: 150)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onTapGesture { onMediaTap(url) }
            }
            messageTimeOverlay
        }
        .padding(2)
    }

    private var videoBubble: some View {
        ZStack {
            if let url = message.mediaFullURL {
                AsyncImage(url: url) { phase in
                    if case .success(let img) = phase { img.resizable().scaledToFit() }
                    else { Color.bgCard }
                }
                .frame(maxWidth: 260, maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.white.opacity(0.9))
                }
                .onTapGesture { onMediaTap(url) }
            }
        }
    }

    private var voiceBubble: some View {
        VoiceBubbleView(
            message: message,
            isMine: isMine,
            bubbleBackground: AnyView(bubbleBackground),
            messageTime: AnyView(messageTime)
        )
    }

    private var fileBubble: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.fill").font(.system(size: 24)).foregroundColor(.h2vAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.mediaName ?? "Файл")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.textPrimary).lineLimit(1)
                if let size = message.mediaSize {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .font(.system(size: 11)).foregroundColor(.textTertiary)
                }
            }
            Spacer()
            messageTime
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(bubbleBackground)
    }

    private var systemMessage: some View {
        Text(message.text ?? "")
            .font(.system(size: 12)).foregroundColor(.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14).padding(.vertical, 4)
    }

    private var bubbleBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(isMine ? Color.h2vAccent.opacity(0.15) : Color.bgCard)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isMine ? Color.clear : Color.borderCard, lineWidth: 0.5)
            }
    }

    private var messageTime: some View {
        HStack(spacing: 3) {
            if message.edited {
                Text("ред.").font(.system(size: 10)).foregroundColor(.textTertiary)
            }
            Text(DateHelper.time(message.createdAt))
                .font(.system(size: 10)).foregroundColor(.textTertiary)
            if isMine { readStatusIcon }
        }
    }

    private var messageTimeOverlay: some View {
        messageTime
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(6)
    }

    @ViewBuilder
    private var readStatusIcon: some View {
        let hasRead = (message.readReceipts ?? []).contains(where: { $0.userId != myId })
        let isDelivered = message.isDelivered ?? false

        if hasRead {
            doubleCheck.foregroundColor(Color(hex: "53b3f3"))
        } else if isDelivered {
            doubleCheck.foregroundColor(.white.opacity(0.7))
        } else {
            singleCheck.foregroundColor(.white.opacity(0.4))
        }
    }

    private var singleCheck: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 9, weight: .bold))
    }

    private var doubleCheck: some View {
        ZStack(alignment: .leading) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .offset(x: 5)
        }
        .frame(width: 16)
    }

    private func replyQuote(_ reply: ReplyTo) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.h2vAccent).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(reply.sender?.displayName ?? "")
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(.h2vAccent)
                Text(reply.isDeleted == true ? "Удалено" : (reply.text ?? "Медиа"))
                    .font(.system(size: 11)).foregroundColor(.textSecondary).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
        .padding(.horizontal, 8)
        .background(isMine ? Color.h2vAccent.opacity(0.08) : Color.bgElevated,
                     in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var forwardHeader: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrowshape.turn.up.right.fill").font(.system(size: 10))
            Text("Переслано от \(message.forwardSenderName ?? "?")")
                .font(.system(size: 11))
        }
        .foregroundColor(.h2vAccent)
        .padding(.horizontal, 10).padding(.top, 4)
    }

    // MARK: - Reactions

    @ViewBuilder
    private var reactionsRow: some View {
        let grouped = Dictionary(grouping: message.reactions ?? [], by: \.emoji)
        if !grouped.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(grouped.keys.sorted()), id: \.self) { emoji in
                    let count = grouped[emoji]?.count ?? 0
                    let myReaction = grouped[emoji]?.contains(where: { $0.userId == myId }) == true
                    Button { onReaction(emoji) } label: {
                        HStack(spacing: 3) {
                            Text(emoji).font(.system(size: 13))
                            if count > 1 {
                                Text("\(count)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(myReaction ? .h2vAccent : .textSecondary)
                            }
                        }
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(myReaction ? Color.h2vAccent.opacity(0.15) : Color.bgCard,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(myReaction ? Color.h2vAccent.opacity(0.3) : Color.borderCard, lineWidth: 0.5)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var messageMenu: some View {
        Button { onReply() } label: {
            Label("Ответить", systemImage: "arrowshape.turn.up.left")
        }

        Button { onForward() } label: {
            Label("Переслать", systemImage: "arrowshape.turn.up.right")
        }

        if message.type == .text || message.text != nil {
            Button { onCopy() } label: {
                Label("Копировать", systemImage: "doc.on.doc")
            }
        }

        Button { onPin() } label: {
            Label("Закрепить", systemImage: "pin")
        }

        Menu("Реакция") {
            ForEach(commonEmojis, id: \.self) { emoji in
                Button(emoji) { onReaction(emoji) }
            }
        }

        if isMine && !message.deleted && message.type == .text {
            Button { onEdit() } label: {
                Label("Редактировать", systemImage: "pencil")
            }
        }

        Button(role: .destructive) { onDelete() } label: {
            Label("Удалить", systemImage: "trash")
        }
    }
}

// MARK: - Forward Picker

struct ForwardPickerView: View {
    let message: Message?
    var onPick: (String) -> Void
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var chats: [Chat] = []
    @State private var searchText = ""

    private var filtered: [Chat] {
        if searchText.isEmpty { return chats }
        let q = searchText.lowercased()
        return chats.filter {
            $0.displayName(myId: appState.currentUser?.id ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        ZStack {
            Color.bgApp.ignoresSafeArea()
            VStack(spacing: 0) {
                SearchBar(text: $searchText, placeholder: "Выберите чат...")
                    .padding(14)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { chat in
                            Button {
                                onPick(chat.id)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    AvatarView(url: chat.chatAvatarURL(myId: appState.currentUser?.id ?? ""),
                                               initials: chat.chatInitials(myId: appState.currentUser?.id ?? ""),
                                               size: 44, id: chat.id)
                                    Text(chat.displayName(myId: appState.currentUser?.id ?? ""))
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundColor(.textPrimary)
                                    Spacer()
                                    Image(systemName: "paperplane")
                                        .font(.system(size: 14))
                                        .foregroundColor(.h2vAccent)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 10)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Переслать")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Отмена") { dismiss() }.foregroundColor(.textSecondary)
            }
        }
        .onAppear {
            Task {
                if let data = try? await APIClient.shared.getChats() {
                    chats = data.chats
                }
            }
        }
    }
}

// MARK: - Voice Bubble View (with duration loading)

struct VoiceBubbleView: View {
    let message: Message
    let isMine: Bool
    let bubbleBackground: AnyView
    let messageTime: AnyView

    @ObservedObject private var player = AudioPlayerManager.shared
    @State private var loadedDuration: TimeInterval = 0

    private var isPlaying: Bool {
        player.playingId == message.id && player.isPlaying
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if let url = message.mediaFullURL {
                    player.play(url: url, messageId: message.id)
                    WebSocketClient.shared.markListened(messageId: message.id)
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(LinearGradient.accentGradient, in: Circle())
            }

            VStack(alignment: .leading, spacing: 3) {
                WaveformView(
                    seed: message.id,
                    progress: player.playingId == message.id ? player.progress : 0,
                    accentColor: isMine ? Color.h2vAccent : Color.textSecondary,
                    barCount: 32
                )
                .frame(height: 20)

                HStack(spacing: 6) {
                    let dur = player.playingId == message.id
                        ? player.currentTime
                        : (player.cachedDuration(for: message.mediaFullURL) ?? loadedDuration)
                    Text(formatVoiceDur(dur))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.textTertiary)
                    messageTime
                    if let listens = message.voiceListens, !listens.isEmpty {
                        Text("\(listens.count)")
                            .font(.system(size: 10))
                            .foregroundColor(.textTertiary)
                    }
                }
            }
            .frame(minWidth: 140)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(bubbleBackground)
        .onAppear {
            if let url = message.mediaFullURL, loadedDuration == 0 {
                Task {
                    let d = await AudioPlayerManager.shared.loadDuration(for: url)
                    await MainActor.run { loadedDuration = d }
                }
            }
        }
    }

    private func formatVoiceDur(_ t: TimeInterval) -> String {
        let m = Int(t) / 60; let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Audio Player

@MainActor
class AudioPlayerManager: ObservableObject {
    static let shared = AudioPlayerManager()
    @Published var isPlaying = false
    @Published var playingId: String?
    @Published var progress: Double = 0
    @Published var currentTime: TimeInterval = 0

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var durationMap: [URL: TimeInterval] = [:]

    func play(url: URL, messageId: String? = nil) {
        if isPlaying && playingId == messageId { stop(); return }
        stop()

        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        let headers = HTTPCookie.requestHeaderFields(with: cookies)
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: item)
        playingId = messageId

        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, let dur = self.player?.currentItem?.duration,
                      dur.seconds.isFinite && dur.seconds > 0 else { return }
                self.currentTime = time.seconds
                self.progress = time.seconds / dur.seconds
                if self.durationMap[url] == nil {
                    self.durationMap[url] = dur.seconds
                }
            }
        }

        player?.play()
        isPlaying = true

        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                               object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    func stop() {
        if let obs = timeObserver { player?.removeTimeObserver(obs); timeObserver = nil }
        player?.pause(); player = nil
        isPlaying = false; playingId = nil; progress = 0; currentTime = 0
    }

    func cachedDuration(for url: URL?) -> TimeInterval? {
        guard let url else { return nil }
        return durationMap[url]
    }

    func loadDuration(for url: URL) async -> TimeInterval {
        if let cached = durationMap[url] { return cached }

        do {
            let (data, resp) = try await APIClient.shared.downloadData(from: url)
            NSLog("[H2V Voice] loadDuration downloaded %d bytes, status=%d, url=%@",
                  data.count, (resp as? HTTPURLResponse)?.statusCode ?? 0, url.lastPathComponent)
            if let player = try? AVAudioPlayer(data: data), player.duration > 0.1 {
                let dur = player.duration
                NSLog("[H2V Voice] loadDuration AVAudioPlayer dur=%.2f", dur)
                await MainActor.run { self.durationMap[url] = dur }
                return dur
            }

            let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("dur_\(UUID().uuidString).m4a")
            try data.write(to: tmpFile)
            if let fp = try? AVAudioPlayer(contentsOf: tmpFile), fp.duration > 0.1 {
                let dur = fp.duration
                NSLog("[H2V Voice] loadDuration fromFile dur=%.2f", dur)
                try? FileManager.default.removeItem(at: tmpFile)
                await MainActor.run { self.durationMap[url] = dur }
                return dur
            }
            try? FileManager.default.removeItem(at: tmpFile)
        } catch {
            NSLog("[H2V Voice] loadDuration download error: %@", error.localizedDescription)
        }

        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        let headers = HTTPCookie.requestHeaderFields(with: cookies)
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let dur = try? await asset.load(.duration)
        let seconds = dur.map { CMTimeGetSeconds($0) } ?? 0
        NSLog("[H2V Voice] loadDuration AVURLAsset dur=%.2f", seconds)
        if seconds > 0 && seconds.isFinite {
            await MainActor.run { self.durationMap[url] = seconds }
        }
        return seconds > 0 ? seconds : 0
    }
}

// MARK: - Identifiable URL

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

struct MediaViewerContext: Identifiable {
    let id = UUID()
    let urls: [URL]
    let startIndex: Int
}

// MARK: - Document Picker

struct DocumentPickerView: UIViewControllerRepresentable {
    let onPick: (Data, String, String) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data])
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (Data, String, String) -> Void
        init(onPick: @escaping (Data, String, String) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url) else { return }
            let filename = url.lastPathComponent
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            onPick(data, filename, mime)
        }
    }
}
