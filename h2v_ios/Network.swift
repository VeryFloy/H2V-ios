import Foundation

// MARK: - Config

enum Config {
    static let baseURL = "http://localhost:3000"
    static let wsURL   = "ws://localhost:3000/ws"
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

    var errorDescription: String? {
        switch self {
        case .noToken:              return "Not authenticated"
        case .invalidURL:           return "Invalid URL"
        case .unauthorized:         return "Session expired. Please sign in again."
        case .unknown:              return "Unknown error"
        case .serverError(let m):   return m
        case .decodingError(let m): return "Decode error: \(m)"
        }
    }
}

// MARK: - API Client

final class APIClient {
    static let shared = APIClient()

    // MARK: - Core request

    private func request<T: Decodable>(
        path: String,
        method: String = "GET",
        bodyData: Data? = nil,
        authenticated: Bool = true
    ) async throws -> T {
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
        if (response as? HTTPURLResponse)?.statusCode == 401 { throw NetworkError.unauthorized }

        do {
            let envelope = try JSONDecoder().decode(APIResponse<T>.self, from: data)
            if let result = envelope.data { return result }
            throw NetworkError.serverError(envelope.message ?? "Unknown error")
        } catch let ne as NetworkError { throw ne } catch {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = json["message"] as? String { throw NetworkError.serverError(msg) }
            throw NetworkError.decodingError(error.localizedDescription)
        }
    }

    private func body<B: Encodable>(_ value: B) throws -> Data { try JSONEncoder().encode(value) }

    // MARK: - Auth

    func register(nickname: String, email: String, password: String) async throws -> AuthData {
        struct B: Encodable { let nickname, email, password: String }
        return try await request(path: "/api/auth/register", method: "POST",
                                 bodyData: try body(B(nickname: nickname, email: email, password: password)),
                                 authenticated: false)
    }

    func login(email: String, password: String) async throws -> AuthData {
        struct B: Encodable { let email, password: String }
        return try await request(path: "/api/auth/login", method: "POST",
                                 bodyData: try body(B(email: email, password: password)),
                                 authenticated: false)
    }

    func logout(refreshToken: String) async {
        struct B: Encodable { let refreshToken: String }
        let _: MessageResponse? = try? await request(path: "/api/auth/logout", method: "POST",
                                                      bodyData: try? body(B(refreshToken: refreshToken)))
    }

    // MARK: - Users

    func getMe() async throws -> User { try await request(path: "/api/users/me") }

    func updateMe(nickname: String? = nil, bio: String? = nil, avatar: String? = nil) async throws -> User {
        struct B: Encodable { let nickname: String?; let bio: String?; let avatar: String? }
        return try await request(path: "/api/users/me", method: "PATCH",
                                 bodyData: try body(B(nickname: nickname, bio: bio, avatar: avatar)))
    }

    func deleteAccount() async throws { let _: MessageResponse = try await request(path: "/api/users/me", method: "DELETE") }

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
        return try await request(path: "/api/chats/direct", method: "POST",
                                 bodyData: try body(B(targetUserId: targetUserId)))
    }

    func createGroupChat(name: String, memberIds: [String]) async throws -> Chat {
        struct B: Encodable { let name: String; let memberIds: [String] }
        return try await request(path: "/api/chats/group", method: "POST",
                                 bodyData: try body(B(name: name, memberIds: memberIds)))
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

    func deleteMessage(id: String) async throws {
        let _: MessageResponse = try await request(path: "/api/messages/\(id)", method: "DELETE")
    }

    func editMessage(id: String, text: String) async throws -> Message {
        struct B: Encodable { let text: String }
        return try await request(path: "/api/messages/\(id)", method: "PATCH",
                                 bodyData: try body(B(text: text)))
    }

    func markRead(messageId: String) async throws {
        let _: MessageResponse = try await request(path: "/api/messages/\(messageId)/read", method: "POST")
    }

    func addReaction(messageId: String, emoji: String) async throws {
        struct B: Encodable { let emoji: String }
        struct R: Decodable { let id: String }
        let _: R = try await request(path: "/api/messages/\(messageId)/reactions", method: "POST",
                                      bodyData: try body(B(emoji: emoji)))
    }

    func removeReaction(messageId: String, emoji: String) async throws {
        let enc = emoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? emoji
        let _: MessageResponse = try await request(path: "/api/messages/\(messageId)/reactions/\(enc)", method: "DELETE")
    }

    // MARK: - Upload

    func uploadFile(data fileData: Data, filename: String, mimeType: String) async throws -> UploadResult {
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
        if (response as? HTTPURLResponse)?.statusCode == 401 { throw NetworkError.unauthorized }
        let decoded = try JSONDecoder().decode(APIResponse<UploadResult>.self, from: respData)
        guard let result = decoded.data else { throw NetworkError.serverError(decoded.message ?? "Upload failed") }
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
    var onEvent: ((WSEvent) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?

    func connect(token: String) {
        disconnect()
        guard let url = URL(string: "\(Config.wsURL)?token=\(token)") else { return }
        task = URLSession.shared.webSocketTask(with: url)
        task?.resume()
        isConnected = true
        receive()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.send(event: "presence:ping") }
        }
    }

    func disconnect() {
        pingTimer?.invalidate(); pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil); task = nil
        isConnected = false
    }

    private func receive() {
        task?.receive { [weak self] result in
            switch result {
            case .success(let msg):
                if case .string(let text) = msg {
                    Task { @MainActor [weak self] in self?.handle(text) }
                }
                Task { @MainActor [weak self] in self?.receive() }
            case .failure:
                Task { @MainActor [weak self] in self?.isConnected = false }
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
        Task { @MainActor [weak self] in
            self?.onEvent?(WSEvent(type: eventType, rawPayload: payload))
        }
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
