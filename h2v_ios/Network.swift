import Foundation

// MARK: - Config

enum Config {
    static let baseURL = "https://web.h2von.com"
    static let wsURL   = "wss://web.h2von.com/ws"
}

// MARK: - Network Error

enum NetworkError: LocalizedError {
    case invalidURL, unauthorized, noSession, unknown
    case serverError(String)
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:           return "Некорректный URL"
        case .unauthorized:         return "Сессия истекла. Войдите снова."
        case .noSession:            return "Нет активной сессии"
        case .unknown:              return "Неизвестная ошибка"
        case .serverError(let m):   return m
        case .decodingError(let m): return "Ошибка декодирования: \(m)"
        }
    }
}

// MARK: - API Client

final class APIClient: @unchecked Sendable {
    static let shared = APIClient()

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = HTTPCookieStorage.shared
        session = URLSession(configuration: config)
    }

    // MARK: - Core request

    @discardableResult
    private func request<T: Decodable>(
        path: String,
        method: String = "GET",
        bodyData: Data? = nil,
        contentType: String? = "application/json"
    ) async throws -> T {
        guard let url = URL(string: Config.baseURL + path) else { throw NetworkError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let ct = contentType {
            req.setValue(ct, forHTTPHeaderField: "Content-Type")
        }
        req.httpBody = bodyData

        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 401 { throw NetworkError.unauthorized }

        do {
            let envelope = try JSONDecoder().decode(APIResponse<T>.self, from: data)
            if let result = envelope.data { return result }
            throw NetworkError.serverError(envelope.message ?? "Ошибка сервера")
        } catch let ne as NetworkError { throw ne } catch {
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            print("❌ API decode error [\(path)]: \(error)\nResponse: \(preview)")
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = json["message"] as? String { throw NetworkError.serverError(msg) }
            throw NetworkError.decodingError("\(path): \(error.localizedDescription)")
        }
    }

    private func body<B: Encodable>(_ value: B) throws -> Data { try JSONEncoder().encode(value) }

    // MARK: - Auth (OTP)

    func sendOtp(email: String) async throws -> OtpResponse {
        struct B: Encodable { let email: String }
        return try await request(path: "/api/auth/send-otp", method: "POST",
                                 bodyData: try body(B(email: email)))
    }

    func verifyOtp(email: String, code: String, nickname: String? = nil) async throws -> VerifyOtpData {
        struct B: Encodable { let email: String; let code: String; let nickname: String? }
        return try await request(path: "/api/auth/verify-otp", method: "POST",
                                 bodyData: try body(B(email: email, code: code, nickname: nickname)))
    }

    func logout() async throws {
        struct Empty: Decodable {}
        let _: Empty = try await request(path: "/api/auth/logout", method: "POST")
    }

    // MARK: - Sessions

    func getSessions() async throws -> [SessionInfo] {
        try await request(path: "/api/auth/sessions")
    }

    func terminateSession(id: String) async throws {
        struct R: Decodable { let terminated: String }
        let _: R = try await request(path: "/api/auth/sessions/\(id)", method: "DELETE")
    }

    func terminateOtherSessions() async throws {
        struct R: Decodable { let terminated: Int }
        let _: R = try await request(path: "/api/auth/sessions", method: "DELETE")
    }

    // MARK: - Users

    func getMe() async throws -> User { try await request(path: "/api/users/me") }

    func updateMe(data: [String: Any]) async throws -> User {
        let jsonData = try JSONSerialization.data(withJSONObject: data)
        return try await request(path: "/api/users/me", method: "PATCH", bodyData: jsonData)
    }

    func updateMeWithForm(_ formData: Data, boundary: String) async throws -> User {
        guard let url = URL(string: Config.baseURL + "/api/users/me") else { throw NetworkError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = formData
        let (data, response) = try await session.data(for: req)
        if (response as? HTTPURLResponse)?.statusCode == 401 { throw NetworkError.unauthorized }
        let envelope = try JSONDecoder().decode(APIResponse<User>.self, from: data)
        guard let result = envelope.data else { throw NetworkError.serverError(envelope.message ?? "Error") }
        return result
    }

    func deleteMe() async throws {
        struct Empty: Decodable {}
        let _: Empty = try await request(path: "/api/users/me", method: "DELETE")
    }

    func searchUsers(query: String) async throws -> [User] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return try await request(path: "/api/users/search?q=\(q)")
    }

    func getUser(id: String) async throws -> User {
        try await request(path: "/api/users/\(id)")
    }

    // MARK: - Chats

    func getChats() async throws -> ChatsData {
        try await request(path: "/api/chats")
    }

    func getArchivedChats() async throws -> ChatsData {
        try await request(path: "/api/chats?archived=true")
    }

    func getChat(id: String) async throws -> Chat {
        try await request(path: "/api/chats/\(id)")
    }

    func getSavedMessages() async throws -> Chat {
        try await request(path: "/api/chats/saved", method: "POST")
    }

    func createDirect(userId: String) async throws -> Chat {
        struct B: Encodable { let targetUserId: String }
        return try await request(path: "/api/chats/direct", method: "POST",
                                 bodyData: try body(B(targetUserId: userId)))
    }

    func createGroup(name: String, memberIds: [String]) async throws -> Chat {
        struct B: Encodable { let name: String; let memberIds: [String] }
        return try await request(path: "/api/chats/group", method: "POST",
                                 bodyData: try body(B(name: name, memberIds: memberIds)))
    }

    func createSecret(userId: String) async throws -> Chat {
        struct B: Encodable { let targetUserId: String }
        return try await request(path: "/api/chats/secret", method: "POST",
                                 bodyData: try body(B(targetUserId: userId)))
    }

    func leaveChat(id: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await request(path: "/api/chats/\(id)/leave", method: "DELETE")
    }

    func deleteChat(id: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await request(path: "/api/chats/\(id)", method: "DELETE")
    }

    func archiveChat(id: String, archived: Bool) async throws {
        struct B: Encodable { let archived: Bool }
        struct R: Decodable { let chatId: String }
        let _: R = try await request(path: "/api/chats/\(id)/archive", method: "PATCH",
                                     bodyData: try body(B(archived: archived)))
    }

    func pinChat(id: String, pinned: Bool) async throws {
        struct B: Encodable { let pinned: Bool }
        struct R: Decodable { let chatId: String; let pinned: Bool }
        let _: R = try await request(path: "/api/chats/\(id)/pin-chat", method: "PATCH",
                                     bodyData: try body(B(pinned: pinned)))
    }

    func renameGroup(id: String, name: String) async throws -> Chat {
        struct B: Encodable { let name: String }
        return try await request(path: "/api/chats/\(id)", method: "PATCH",
                                 bodyData: try body(B(name: name)))
    }

    func updateGroupAvatar(id: String, avatarUrl: String) async throws -> Chat {
        struct B: Encodable { let avatar: String }
        return try await request(path: "/api/chats/\(id)", method: "PATCH",
                                 bodyData: try body(B(avatar: avatarUrl)))
    }

    func kickMember(chatId: String, userId: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await request(path: "/api/chats/\(chatId)/members/\(userId)", method: "DELETE")
    }

    func addMembers(chatId: String, userIds: [String]) async throws -> Chat {
        struct B: Encodable { let userIds: [String] }
        return try await request(path: "/api/chats/\(chatId)/members", method: "POST",
                                 bodyData: try body(B(userIds: userIds)))
    }

    func pinMessage(chatId: String, messageId: String?) async throws -> Chat {
        let data = try JSONSerialization.data(withJSONObject: ["messageId": messageId as Any])
        return try await request(path: "/api/chats/\(chatId)/pin", method: "PATCH", bodyData: data)
    }

    // MARK: - Block

    func blockUser(id: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await request(path: "/api/users/\(id)/block", method: "POST")
    }

    func unblockUser(id: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await request(path: "/api/users/\(id)/block", method: "DELETE")
    }

    func getBlockedUsers() async throws -> [String] {
        try await request(path: "/api/users/me/blocked")
    }

    // MARK: - Messages

    func getMessages(chatId: String, cursor: String? = nil, limit: Int = 30, query: String? = nil) async throws -> MessagesData {
        var path = "/api/chats/\(chatId)/messages?limit=\(limit)"
        if let c = cursor { path += "&cursor=\(c)" }
        if let q = query, !q.isEmpty { path += "&q=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)" }
        return try await request(path: path)
    }

    func editMessage(id: String, text: String) async throws -> Message {
        struct B: Encodable { let text: String }
        return try await request(path: "/api/messages/\(id)", method: "PATCH",
                                 bodyData: try body(B(text: text)))
    }

    func deleteMessage(id: String, forEveryone: Bool = true) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await request(path: "/api/messages/\(id)?forEveryone=\(forEveryone)", method: "DELETE")
    }

    func markRead(messageId: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await request(path: "/api/messages/\(messageId)/read", method: "POST")
    }

    func getSharedMedia(chatId: String, type: String, cursor: String? = nil) async throws -> MessagesData {
        var path = "/api/chats/\(chatId)/messages?type=\(type)&limit=50"
        if let c = cursor { path += "&cursor=\(c)" }
        return try await request(path: path)
    }

    func exportChat(chatId: String) async throws -> String {
        guard let url = URL(string: Config.baseURL + "/api/chats/\(chatId)/export") else { throw NetworkError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let (data, _) = try await session.data(for: req)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Reactions

    func addReaction(messageId: String, emoji: String) async throws {
        struct B: Encodable { let emoji: String }
        struct R: Decodable { let id: String }
        let _: R = try await request(path: "/api/messages/\(messageId)/reactions", method: "POST",
                                     bodyData: try body(B(emoji: emoji)))
    }

    func removeReaction(messageId: String, emoji: String) async throws {
        let enc = emoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? emoji
        struct Empty: Decodable {}
        let _: Empty = try await request(path: "/api/messages/\(messageId)/reactions/\(enc)", method: "DELETE")
    }

    // MARK: - Upload

    func upload(fileData: Data, filename: String, mimeType: String) async throws -> UploadResult {
        guard let url = URL(string: Config.baseURL + "/api/upload") else { throw NetworkError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        let boundary = "H2V\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n")
        req.httpBody = body
        let (data, response) = try await session.data(for: req)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        NSLog("[H2V Upload] HTTP %d body=%@", statusCode, String(data: data.prefix(500), encoding: .utf8) ?? "?")
        if statusCode == 401 { throw NetworkError.unauthorized }
        if statusCode >= 400 {
            throw NetworkError.serverError("Upload HTTP \(statusCode): \(String(data: data.prefix(200), encoding: .utf8) ?? "?")")
        }
        let envelope = try JSONDecoder().decode(APIResponse<UploadResult>.self, from: data)
        guard let result = envelope.data else { throw NetworkError.serverError(envelope.message ?? "Upload failed") }
        return result
    }

    // MARK: - Contacts

    func getContacts() async throws -> [ContactInfo] {
        try await request(path: "/api/contacts")
    }

    func addContact(userId: String) async throws {
        struct B: Encodable { let userId: String }
        struct Empty: Decodable {}
        let _: Empty = try await request(path: "/api/contacts", method: "POST",
                                         bodyData: try body(B(userId: userId)))
    }

    func removeContact(userId: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await request(path: "/api/contacts/\(userId)", method: "DELETE")
    }

    // MARK: - Settings

    func getSettings() async throws -> [String: Any] {
        guard let url = URL(string: Config.baseURL + "/api/users/me/settings") else { throw NetworkError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let (data, response) = try await session.data(for: req)
        if (response as? HTTPURLResponse)?.statusCode == 401 { throw NetworkError.unauthorized }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = json["data"] as? [String: Any] else { return [:] }
        return d
    }

    func updateSettings(data: [String: Any]) async throws {
        guard let url = URL(string: Config.baseURL + "/api/users/me/settings") else { throw NetworkError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: data)
        let (_, response) = try await session.data(for: req)
        if (response as? HTTPURLResponse)?.statusCode == 401 { throw NetworkError.unauthorized }
    }

    // MARK: - Download

    func downloadData(from url: URL) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        return try await session.data(for: req)
    }

    // MARK: - Push

    func registerDeviceToken(token: String) async throws {
        struct B: Encodable { let token: String; let platform: String }
        struct Empty: Decodable {}
        let _: Empty = try await request(path: "/api/push/register", method: "POST",
                                         bodyData: try body(B(token: token, platform: "IOS")))
    }
}

// MARK: - Data Helpers

extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}

// MARK: - WebSocket Client

@MainActor
final class WebSocketClient: ObservableObject {
    static let shared = WebSocketClient()

    @Published var isConnected = false
    var onEvent: ((WSEvent) -> Void)?

    private var eventListeners: [String: (WSEvent) -> Void] = [:]

    func addListener(id: String, handler: @escaping (WSEvent) -> Void) {
        eventListeners[id] = handler
    }

    func removeListener(id: String) {
        eventListeners.removeValue(forKey: id)
    }

    private var task: URLSessionWebSocketTask?
    private var wsSession: URLSession?
    private var pingTimer: Timer?
    private var reconnectTimer: Timer?
    private var reconnectAttempts = 0

    func connect() {
        disconnect()
        guard let url = URL(string: Config.wsURL) else { return }

        var req = URLRequest(url: url)
        if let cookies = HTTPCookieStorage.shared.cookies(for: URL(string: Config.baseURL)!) {
            let headers = HTTPCookie.requestHeaderFields(with: cookies)
            for (key, value) in headers {
                req.setValue(value, forHTTPHeaderField: key)
            }
            print("🔌 WS connecting with \(cookies.count) cookies")
        } else {
            print("⚠️ WS connecting WITHOUT cookies")
        }

        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = HTTPCookieStorage.shared
        wsSession = URLSession(configuration: config)
        task = wsSession?.webSocketTask(with: req)
        task?.resume()
        reconnectAttempts = 0
        receive()
        startPing()
    }

    func disconnect() {
        pingTimer?.invalidate(); pingTimer = nil
        reconnectTimer?.invalidate(); reconnectTimer = nil
        task?.cancel(with: .goingAway, reason: nil); task = nil
        wsSession?.invalidateAndCancel(); wsSession = nil
        isConnected = false
    }

    private func startPing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.send(event: "presence:ping") }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            switch result {
            case .success(let msg):
                if case .string(let text) = msg {
                    Task { @MainActor [weak self] in
                        if self?.isConnected == false {
                            self?.isConnected = true
                            print("✅ WS connected")
                        }
                        self?.handle(text)
                    }
                }
                Task { @MainActor [weak self] in self?.receive() }
            case .failure(let error):
                Task { @MainActor [weak self] in
                    print("❌ WS receive error: \(error.localizedDescription)")
                    self?.isConnected = false
                    self?.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        let delay = min(30.0, pow(2.0, Double(reconnectAttempts)))
        reconnectAttempts += 1
        print("🔄 WS reconnect in \(Int(delay))s (attempt \(reconnectAttempts))")
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.connect() }
        }
    }

    private func handle(_ text: String) {
        guard
            let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let eventType = json["event"] as? String
        else { return }
        let payload = json["payload"] as? [String: Any] ?? [:]
        let wsEvent = WSEvent(event: eventType, payload: payload)
        onEvent?(wsEvent)
        for (_, listener) in eventListeners {
            listener(wsEvent)
        }
    }

    func send(event: String, payload: [String: Any] = [:]) {
        guard let task else {
            print("⚠️ WS send failed — not connected (\(event))")
            return
        }
        var dict: [String: Any] = ["event": event]
        if !payload.isEmpty { dict["payload"] = payload }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { error in
            if let error {
                print("❌ WS send error (\(event)): \(error.localizedDescription)")
            }
        }
    }

    func sendMessage(chatId: String, text: String, type: String = "TEXT",
                     mediaUrl: String? = nil, mediaName: String? = nil,
                     mediaSize: Int? = nil, replyToId: String? = nil,
                     forwardedFromId: String? = nil, forwardSenderName: String? = nil) {
        var p: [String: Any] = ["chatId": chatId, "text": text, "type": type]
        if let m = mediaUrl { p["mediaUrl"] = m }
        if let n = mediaName { p["mediaName"] = n }
        if let s = mediaSize { p["mediaSize"] = s }
        if let r = replyToId { p["replyToId"] = r }
        if let f = forwardedFromId { p["forwardedFromId"] = f }
        if let fn = forwardSenderName { p["forwardSenderName"] = fn }
        send(event: "message:send", payload: p)
    }

    func typingStart(chatId: String) { send(event: "typing:start", payload: ["chatId": chatId]) }
    func typingStop(chatId: String)  { send(event: "typing:stop",  payload: ["chatId": chatId]) }
    func markRead(messageId: String, chatId: String) {
        send(event: "message:read", payload: ["messageId": messageId, "chatId": chatId])
    }
    func markListened(messageId: String) {
        send(event: "message:listened", payload: ["messageId": messageId])
    }
}
