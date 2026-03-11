import Foundation

// MARK: - Config

enum Config {
    static let baseURL = "https://h2von.com"
    static let wsURL   = "wss://h2von.com/ws"
}

// MARK: - Token Storage

final class TokenStorage {
    static let shared = TokenStorage()
    private let defaults = UserDefaults.standard

    var accessToken: String? {
        get { defaults.string(forKey: "h2v.accessToken") }
        set { defaults.set(newValue, forKey: "h2v.accessToken") }
    }
    var refreshToken: String? {
        get { defaults.string(forKey: "h2v.refreshToken") }
        set { defaults.set(newValue, forKey: "h2v.refreshToken") }
    }

    func save(tokens: Tokens) {
        accessToken = tokens.accessToken
        refreshToken = tokens.refreshToken
    }
    func clear() {
        defaults.removeObject(forKey: "h2v.accessToken")
        defaults.removeObject(forKey: "h2v.refreshToken")
    }
}

// MARK: - Network Error

enum NetworkError: LocalizedError {
    case noToken, invalidURL, unauthorized, unknown
    case serverError(String)
    case decodingError(String)
    case nicknameRequired
    case otpExpired

    var errorDescription: String? {
        switch self {
        case .noToken:              return "Не авторизован"
        case .invalidURL:           return "Неверный URL"
        case .unauthorized:         return "Сессия истекла, войди снова"
        case .unknown:              return "Неизвестная ошибка"
        case .serverError(let m):   return m
        case .decodingError(let m): return "Ошибка данных: \(m)"
        case .nicknameRequired:     return "Требуется никнейм"
        case .otpExpired:           return "Код истёк или неверен"
        }
    }
}

// MARK: - API Client

final class APIClient {
    static let shared = APIClient()

    // MARK: - Core HTTP (shared, with automatic token-refresh on 401)

    private func performHTTP(
        path: String,
        method: String,
        bodyData: Data?,
        authenticated: Bool,
        isRetry: Bool = false
    ) async throws -> Data {
        guard let url = URL(string: Config.baseURL + path) else { throw NetworkError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated {
            guard let token = TokenStorage.shared.accessToken else { throw NetworkError.noToken }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: req)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        if statusCode == 401 {
            if authenticated && !isRetry {
                if let tokens = try? await refreshTokens() {
                    TokenStorage.shared.save(tokens: tokens)
                    await MainActor.run { WebSocketClient.shared.connect() }
                    return try await performHTTP(path: path, method: method, bodyData: bodyData,
                                                 authenticated: authenticated, isRetry: true)
                }
            }
            throw NetworkError.unauthorized
        }
        return data
    }

    // MARK: - Core request

    private func request<T: Decodable>(
        path: String,
        method: String = "GET",
        bodyData: Data? = nil,
        authenticated: Bool = true
    ) async throws -> T {
        let data = try await performHTTP(path: path, method: method, bodyData: bodyData,
                                         authenticated: authenticated)
        do {
            let envelope = try JSONDecoder().decode(APIResponse<T>.self, from: data)
            if let result = envelope.data { return result }
            switch envelope.code {
            case "NICKNAME_REQUIRED":             throw NetworkError.nicknameRequired
            case "OTP_EXPIRED", "INVALID_CODE":   throw NetworkError.otpExpired
            default:
                throw NetworkError.serverError(envelope.message ?? "Unknown error")
            }
        } catch let ne as NetworkError { throw ne } catch {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let code = json["code"] as? String {
                    switch code {
                    case "NICKNAME_REQUIRED": throw NetworkError.nicknameRequired
                    case "OTP_EXPIRED", "INVALID_CODE": throw NetworkError.otpExpired
                    default: break
                    }
                }
                if let msg = json["message"] as? String { throw NetworkError.serverError(msg) }
            }
            throw NetworkError.decodingError(error.localizedDescription)
        }
    }

    // Endpoints that return no meaningful data (success/fail only)
    private func requestVoid(
        path: String,
        method: String = "POST",
        bodyData: Data? = nil,
        authenticated: Bool = true
    ) async throws {
        let data = try await performHTTP(path: path, method: method, bodyData: bodyData,
                                          authenticated: authenticated)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let success = json["success"] as? Bool ?? true
            if !success {
                if let msg = json["message"] as? String { throw NetworkError.serverError(msg) }
                throw NetworkError.unknown
            }
        }
    }

    private func body<B: Encodable>(_ value: B) throws -> Data { try JSONEncoder().encode(value) }

    // MARK: - Auth (OTP-based)

    func sendOtp(email: String) async throws {
        struct B: Encodable { let email: String }
        try await requestVoid(
            path: "/api/auth/send-otp",
            bodyData: try body(B(email: email)),
            authenticated: false
        )
    }

    func verifyOtp(email: String, code: String, nickname: String? = nil) async throws -> AuthData {
        struct B: Encodable { let email, code: String; let nickname: String? }
        return try await request(
            path: "/api/auth/verify-otp",
            method: "POST",
            bodyData: try body(B(email: email, code: code, nickname: nickname)),
            authenticated: false
        )
    }

    func logout(refreshToken: String) async {
        struct B: Encodable { let refreshToken: String }
        let _: MessageResponse? = try? await request(
            path: "/api/auth/logout",
            method: "POST",
            bodyData: try? body(B(refreshToken: refreshToken))
        )
    }

    func refreshTokens() async throws -> Tokens {
        struct B: Encodable { let refreshToken: String }
        guard let rt = TokenStorage.shared.refreshToken else { throw NetworkError.noToken }
        return try await request(
            path: "/api/auth/refresh",
            method: "POST",
            bodyData: try body(B(refreshToken: rt)),
            authenticated: false
        )
    }

    // MARK: - Users

    // MARK: - Device Tokens (APNs)

    func registerDeviceToken(_ token: String) async throws {
        struct B: Encodable { let token: String; let platform: String }
        try await requestVoid(
            path: "/api/users/me/device-token",
            method: "POST",
            bodyData: try body(B(token: token, platform: "IOS"))
        )
    }

    func unregisterDeviceToken(_ token: String) async throws {
        struct B: Encodable { let token: String }
        try await requestVoid(
            path: "/api/users/me/device-token",
            method: "DELETE",
            bodyData: try body(B(token: token))
        )
    }

    func getMe() async throws -> User { try await request(path: "/api/users/me") }

    func updateMe(nickname: String? = nil, bio: String? = nil, avatar: String? = nil) async throws -> User {
        struct B: Encodable { let nickname: String?; let bio: String?; let avatar: String? }
        return try await request(
            path: "/api/users/me",
            method: "PATCH",
            bodyData: try body(B(nickname: nickname, bio: bio, avatar: avatar))
        )
    }

    func deleteAccount() async throws {
        let _: MessageResponse = try await request(path: "/api/users/me", method: "DELETE")
    }

    func searchUsers(query: String) async throws -> [User] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return try await request(path: "/api/users/search?q=\(q)")
    }

    func getUser(id: String) async throws -> User { try await request(path: "/api/users/\(id)") }

    // MARK: - Chats

    func getChats(cursor: String? = nil, limit: Int = 30) async throws -> ChatsData {
        var path = "/api/chats?limit=\(limit)"
        if let c = cursor { path += "&cursor=\(c)" }
        return try await request(path: path)
    }

    func createDirectChat(targetUserId: String) async throws -> Chat {
        struct B: Encodable { let targetUserId: String }
        return try await request(
            path: "/api/chats/direct",
            method: "POST",
            bodyData: try body(B(targetUserId: targetUserId))
        )
    }

    func createGroupChat(name: String, memberIds: [String]) async throws -> Chat {
        struct B: Encodable { let name: String; let memberIds: [String] }
        return try await request(
            path: "/api/chats/group",
            method: "POST",
            bodyData: try body(B(name: name, memberIds: memberIds))
        )
    }

    func leaveChat(chatId: String) async throws {
        let _: MessageResponse = try await request(path: "/api/chats/\(chatId)/leave", method: "DELETE")
    }

    // MARK: - Messages

    func getMessages(chatId: String, cursor: String? = nil, limit: Int = 50) async throws -> MessagesData {
        var path = "/api/chats/\(chatId)/messages?limit=\(limit)"
        if let c = cursor { path += "&cursor=\(c)" }
        return try await request(path: path)
    }

    func deleteMessage(id: String, forEveryone: Bool = true) async throws {
        let _: MessageResponse = try await request(
            path: "/api/messages/\(id)?forEveryone=\(forEveryone)",
            method: "DELETE"
        )
    }

    func editMessage(id: String, text: String) async throws -> Message {
        struct B: Encodable { let text: String }
        return try await request(
            path: "/api/messages/\(id)",
            method: "PATCH",
            bodyData: try body(B(text: text))
        )
    }

    func markRead(messageId: String) async throws {
        let _: MessageResponse = try await request(
            path: "/api/messages/\(messageId)/read",
            method: "POST"
        )
    }

    func addReaction(messageId: String, emoji: String) async throws {
        struct B: Encodable { let emoji: String }
        struct R: Decodable { let id: String }
        let _: R = try await request(
            path: "/api/messages/\(messageId)/reactions",
            method: "POST",
            bodyData: try body(B(emoji: emoji))
        )
    }

    func removeReaction(messageId: String, emoji: String) async throws {
        let enc = emoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? emoji
        let _: MessageResponse = try await request(
            path: "/api/messages/\(messageId)/reactions/\(enc)",
            method: "DELETE"
        )
    }

    // MARK: - Upload

    func uploadFile(data fileData: Data, filename: String, mimeType: String,
                    isRetry: Bool = false) async throws -> UploadResult {
        guard let url = URL(string: Config.baseURL + "/api/upload") else { throw NetworkError.invalidURL }
        guard let token = TokenStorage.shared.accessToken else { throw NetworkError.noToken }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let boundary = "H2VBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var body = Data()
        let nl = "\r\n"
        body += "--\(boundary)\(nl)".data(using: .utf8)!
        body += "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\(nl)".data(using: .utf8)!
        body += "Content-Type: \(mimeType)\(nl)\(nl)".data(using: .utf8)!
        body += fileData
        body += "\(nl)--\(boundary)--\(nl)".data(using: .utf8)!
        req.httpBody = body
        let (respData, response) = try await URLSession.shared.data(for: req)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            if !isRetry, let tokens = try? await refreshTokens() {
                TokenStorage.shared.save(tokens: tokens)
                await MainActor.run { WebSocketClient.shared.connect() }
                return try await uploadFile(data: fileData, filename: filename, mimeType: mimeType, isRetry: true)
            }
            throw NetworkError.unauthorized
        }
        let decoded = try JSONDecoder().decode(APIResponse<UploadResult>.self, from: respData)
        guard let result = decoded.data else {
            throw NetworkError.serverError(decoded.message ?? "Upload failed")
        }
        return result
    }
}

// MARK: - WebSocket Event

struct WSEvent {
    let type: String
    let rawPayload: [String: Any]

    var chatId: String?    { rawPayload["chatId"]    as? String }
    var userId: String?    { rawPayload["userId"]    as? String }
    var messageId: String? { rawPayload["messageId"] as? String }

    func decode<T: Decodable>(as t: T.Type) -> T? {
        guard let d = try? JSONSerialization.data(withJSONObject: rawPayload) else { return nil }
        return try? JSONDecoder().decode(t, from: d)
    }
    func decodeMessage() -> Message? { decode(as: Message.self) }
}

// MARK: - WebSocket Client

@MainActor
final class WebSocketClient: ObservableObject {
    static let shared = WebSocketClient()

    @Published var isConnected = false

    // MARK: - Multicast subscribers
    private var subscribers: [UUID: (WSEvent) -> Void] = [:]

    @discardableResult
    func subscribe(_ handler: @escaping (WSEvent) -> Void) -> UUID {
        let id = UUID()
        subscribers[id] = handler
        return id
    }

    func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    // MARK: - Connection internals
    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectDelay: TimeInterval = 1.0

    // Monotonically-incrementing generation ID.
    // Each _connect() call bumps this so stale receive() callbacks
    // from a previous connection are silently dropped, preventing
    // the online→offline flicker race condition.
    private var connectionGeneration: Int = 0

    // Dedicated URLSession: 10-sec TCP connection timeout, no resource timeout.
    private lazy var wsSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = .infinity
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    // MARK: - Public API

    /// Connect or no-op if already connected.
    /// Pass a token only to force a reconnect with a specific credential.
    func connect(token: String? = nil) {
        let t = token ?? TokenStorage.shared.accessToken
        guard let t else { return }
        // Don't tear down a healthy connection — this prevents the presence flicker
        // that occurs when connect() is called redundantly (e.g., app lifecycle events).
        guard !isConnected else { return }
        _connect(token: t)
    }

    /// Force-reconnect even if currently connected (e.g. after token rotation).
    func forceReconnect(token: String? = nil) {
        let t = token ?? TokenStorage.shared.accessToken
        guard let t else { return }
        _connect(token: t)
    }

    /// Reconnect immediately with zero backoff (called when app becomes active).
    func reconnectNow() {
        guard let token = TokenStorage.shared.accessToken else { return }
        guard !isConnected else { return }
        reconnectTask?.cancel(); reconnectTask = nil
        reconnectDelay = 1.0
        _connect(token: token)
    }

    /// Intentional disconnect (logout). Cancels any pending reconnect.
    func disconnect() {
        reconnectTask?.cancel(); reconnectTask = nil
        reconnectDelay = 1.0
        _teardown(graceful: true)
    }

    // MARK: - Private

    private func _connect(token: String) {
        reconnectTask?.cancel(); reconnectTask = nil
        _teardown(graceful: false)   // not a logout — no .goingAway frame needed
        connectionGeneration += 1
        let gen = connectionGeneration
        guard let url = URL(string: "\(Config.wsURL)?token=\(token)") else { return }
        task = wsSession.webSocketTask(with: url)
        task?.resume()
        send(event: "auth", payload: ["token": token])
        isConnected = true
        receive(generation: gen)
        // Ping every 20 s — server drops idle connections after ~25 s
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.send(event: "presence:ping") }
        }
        reconnectDelay = 1.0
    }

    private func _teardown(graceful: Bool) {
        pingTimer?.invalidate(); pingTimer = nil
        if graceful {
            task?.cancel(with: .goingAway, reason: nil)
        } else {
            task?.cancel()
        }
        task = nil
        isConnected = false
    }

    private func scheduleReconnect() {
        guard TokenStorage.shared.accessToken != nil else { return }
        guard !subscribers.isEmpty else { return }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30.0)
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Use _connect directly (isConnected is false here, already checked upstream)
            if let token = TokenStorage.shared.accessToken {
                self._connect(token: token)
            }
        }
    }

    private func receive(generation: Int) {
        task?.receive { [weak self] result in
            switch result {
            case .success(let msg):
                if case .string(let text) = msg {
                    Task { @MainActor [weak self] in
                        guard let self, self.connectionGeneration == generation else { return }
                        self.isConnected = true
                        self.handle(text)
                    }
                }
                // Continue the receive loop — always dispatch on the same generation
                Task { @MainActor [weak self] in
                    guard let self, self.connectionGeneration == generation else { return }
                    self.receive(generation: generation)
                }
            case .failure:
                Task { @MainActor [weak self] in
                    // Only react if this is still the current connection
                    guard let self, self.connectionGeneration == generation else { return }
                    self.isConnected = false
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard
            let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let eventType = json["event"] as? String
        else { return }
        let payload = json["payload"] as? [String: Any] ?? [:]
        let event = WSEvent(type: eventType, rawPayload: payload)
        subscribers.values.forEach { $0(event) }
    }

    func send(event: String, payload: [String: Any] = [:]) {
        var dict: [String: Any] = ["event": event]
        if !payload.isEmpty { dict["payload"] = payload }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    func sendMessage(chatId: String, text: String, type: String = "TEXT",
                     mediaUrl: String? = nil, replyToId: String? = nil) {
        var p: [String: Any] = ["chatId": chatId, "text": text, "type": type, "signalType": 0]
        if let m = mediaUrl { p["mediaUrl"] = m }
        if let r = replyToId { p["replyToId"] = r }
        send(event: "message:send", payload: p)
    }

    func typingStart(chatId: String) { send(event: "typing:start", payload: ["chatId": chatId]) }
    func typingStop(chatId: String)  { send(event: "typing:stop",  payload: ["chatId": chatId]) }
    func markRead(messageId: String, chatId: String) {
        send(event: "message:read", payload: ["messageId": messageId, "chatId": chatId])
    }
}
