import Foundation

// MARK: - API Response

struct APIResponse<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let message: String?
    let code: String?
}

// MARK: - Auth

struct OtpResponse: Decodable {
    let status: String
}

struct VerifyOtpData: Decodable {
    let user: User
    let isNewUser: Bool?
}

// MARK: - User

struct User: Codable, Identifiable, Equatable, Hashable {
    let id: String
    var nickname: String
    var firstName: String?
    var lastName: String?
    var avatar: String?
    var bio: String?
    var email: String?
    var isOnline: Bool?
    var lastOnline: String?
    var blockedByThem: Bool?

    var displayName: String {
        let parts = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
        return parts.isEmpty ? nickname : parts
    }

    var initials: String {
        if let f = firstName?.first, let l = lastName?.first {
            return "\(f)\(l)".uppercased()
        }
        return String(nickname.prefix(1)).uppercased()
    }

    var avatarURL: URL? {
        guard let avatar, !avatar.isEmpty else { return nil }
        if avatar.hasPrefix("http") { return URL(string: avatar) }
        return URL(string: Config.baseURL + avatar)
    }
}

// MARK: - Chat

struct Chat: Codable, Identifiable, Equatable, Hashable {
    static func == (lhs: Chat, rhs: Chat) -> Bool {
        lhs.id == rhs.id
        && lhs.unread == rhs.unread
        && lhs.lastMessage?.id == rhs.lastMessage?.id
        && lhs.lastMessage?.text == rhs.lastMessage?.text
        && lhs.draft?.text == rhs.draft?.text
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    let id: String
    let type: ChatType
    var name: String?
    var avatar: String?
    var description: String?
    var pinnedMessageId: String?
    let createdAt: String
    var updatedAt: String?
    var members: [ChatMember]
    var unread: Int?
    var draft: ChatDraft?

    var lastMessage: Message?

    private enum CodingKeys: String, CodingKey {
        case id, type, name, avatar, description, pinnedMessageId
        case createdAt, updatedAt, members, unread, draft
        case messages, lastMessage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(ChatType.self, forKey: .type)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        pinnedMessageId = try c.decodeIfPresent(String.self, forKey: .pinnedMessageId)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        members = (try? c.decode([ChatMember].self, forKey: .members)) ?? []
        unread = try c.decodeIfPresent(Int.self, forKey: .unread)
        draft = try c.decodeIfPresent(ChatDraft.self, forKey: .draft)

        if let msgs = try? c.decode([Message].self, forKey: .messages), let first = msgs.first {
            lastMessage = first
        } else {
            lastMessage = try c.decodeIfPresent(Message.self, forKey: .lastMessage)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(avatar, forKey: .avatar)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try c.encode(members, forKey: .members)
        try c.encodeIfPresent(unread, forKey: .unread)
        try c.encodeIfPresent(draft, forKey: .draft)
        try c.encodeIfPresent(lastMessage, forKey: .lastMessage)
    }

    func displayName(myId: String) -> String {
        if type == .group { return name ?? "Group" }
        if type == .self_ { return "Избранное" }
        return otherUser(myId: myId)?.displayName ?? "Chat"
    }

    func otherUser(myId: String) -> User? {
        members.first(where: { $0.user.id != myId })?.user
    }

    func chatAvatarURL(myId: String) -> URL? {
        if type == .group || type == .self_ {
            guard let av = avatar, !av.isEmpty else { return nil }
            return URL(string: av.hasPrefix("http") ? av : Config.baseURL + av)
        }
        return otherUser(myId: myId)?.avatarURL
    }

    func chatInitials(myId: String) -> String {
        if type == .self_ { return "⭐" }
        if type == .group { return name.map { String($0.prefix(1)).uppercased() } ?? "G" }
        return otherUser(myId: myId)?.initials ?? "?"
    }

    func isArchivedFor(userId: String) -> Bool {
        members.first(where: { $0.userId == userId })?.isArchived ?? false
    }
}

enum ChatType: String, Codable {
    case direct = "DIRECT"
    case group = "GROUP"
    case secret = "SECRET"
    case self_ = "SELF"

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = ChatType(rawValue: value) ?? .direct
    }
}

struct ChatMember: Codable, Identifiable, Equatable {
    let id: String
    let chatId: String
    let userId: String
    let role: String
    var isArchived: Bool?
    var pinnedAt: String?
    let joinedAt: String
    let user: User

    static func == (lhs: ChatMember, rhs: ChatMember) -> Bool { lhs.id == rhs.id }
}

struct ChatDraft: Codable, Equatable {
    let text: String
    let replyToId: String?
    var updatedAt: String?
}

struct ChatsData: Decodable {
    let chats: [Chat]
    let nextCursor: String?
}

// MARK: - Message

struct Message: Codable, Identifiable, Equatable {
    let id: String
    var chatId: String?
    var text: String?
    var ciphertext: String?
    var signalType: Int?
    let type: MessageType
    var mediaUrl: String?
    var mediaName: String?
    var mediaSize: Int?
    var isDeleted: Bool?
    var isEdited: Bool?
    var replyToId: String?
    var replyTo: ReplyTo?
    var forwardedFromId: String?
    var forwardSenderName: String?
    var mediaGroupId: String?
    let createdAt: String
    var updatedAt: String?
    var sender: MessageSender?
    var readReceipts: [ReadReceipt]?
    var voiceListens: [VoiceListen]?
    var reactions: [Reaction]?
    var readBy: [String]?
    var isDelivered: Bool?

    var createdDate: Date {
        DateHelper.parse(createdAt)
    }

    var mediaFullURL: URL? {
        guard let url = mediaUrl, !url.isEmpty else { return nil }
        if url.hasPrefix("http") { return URL(string: url) }
        return URL(string: Config.baseURL + url)
    }

    var deleted: Bool { isDeleted ?? false }
    var edited: Bool { isEdited ?? false }

    static func == (lhs: Message, rhs: Message) -> Bool { lhs.id == rhs.id }
}

enum MessageType: String, Codable {
    case text = "TEXT"
    case image = "IMAGE"
    case file = "FILE"
    case audio = "AUDIO"
    case video = "VIDEO"
    case system = "SYSTEM"

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = MessageType(rawValue: value) ?? .text
    }
}

struct MessageSender: Codable, Equatable {
    let id: String
    let nickname: String
    var firstName: String?
    var lastName: String?
    var avatar: String?

    var displayName: String {
        let parts = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
        return parts.isEmpty ? nickname : parts
    }

    var avatarURL: URL? {
        guard let avatar, !avatar.isEmpty else { return nil }
        if avatar.hasPrefix("http") { return URL(string: avatar) }
        return URL(string: Config.baseURL + avatar)
    }
}

struct ReadReceipt: Codable, Equatable {
    let userId: String
    let readAt: String
}

struct VoiceListen: Codable, Equatable {
    let userId: String
}

struct Reaction: Codable, Identifiable, Equatable {
    let id: String
    let messageId: String?
    let userId: String
    let emoji: String
    var user: ReactionUser?
}

struct ReactionUser: Codable, Equatable {
    let nickname: String
}

struct ReplyTo: Codable, Equatable {
    let id: String
    let text: String?
    var ciphertext: String?
    var signalType: Int?
    let sender: MessageSender?
    let isDeleted: Bool?
}

struct MessagesData: Decodable {
    let messages: [Message]
    let nextCursor: String?
}

// MARK: - Upload

struct UploadResult: Decodable {
    let url: String
    let type: String
    let name: String
    let size: Int
}

// MARK: - Session

struct SessionInfo: Codable, Identifiable {
    let id: String
    let deviceName: String?
    let location: String?
    let lastActiveAt: String
    let createdAt: String
    let isCurrent: Bool
}

// MARK: - Contact

struct ContactInfo: Codable, Identifiable {
    let id: String
    let nickname: String
    var firstName: String?
    var lastName: String?
    var avatar: String?
    var isOnline: Bool
    var lastOnline: String?
    var isMutual: Bool
}

// MARK: - Settings

typealias PrivacyLevel = String

// MARK: - Outbox

enum OutboxStatus: String {
    case sending, uploading, failed
}

struct OutboxMessage: Identifiable {
    let id: String
    let chatId: String
    let text: String
    let type: MessageType
    var mediaData: Data?
    var mediaFilename: String?
    var mediaMimeType: String?
    var localMediaURL: URL?
    var replyToId: String?
    var status: OutboxStatus
    let createdAt: Date
    var progress: Double = 0
    var error: String?
    var voiceDuration: TimeInterval = 0
    var waveform: [CGFloat] = []

    var createdAtString: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: createdAt)
    }
}

// MARK: - WS Events

struct WSEvent {
    let event: String
    let payload: [String: Any]

    var chatId: String? { payload["chatId"] as? String }
    var userId: String? { payload["userId"] as? String }
    var messageId: String? { payload["messageId"] as? String }

    func decode<T: Decodable>(as type: T.Type) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func decodeMessage() -> Message? { decode(as: Message.self) }
}
