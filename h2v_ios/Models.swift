import Foundation

// MARK: - API Response

struct APIResponse<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let message: String?
    let code: String?
}

struct MessageResponse: Decodable {
    let message: String
}

struct VoidData: Decodable {}

// MARK: - Auth

struct AuthData: Decodable {
    let user: User
    let tokens: Tokens
}

struct Tokens: Codable {
    let accessToken: String
    let refreshToken: String
}

// MARK: - User

struct User: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let nickname: String
    let avatar: String?
    let bio: String?
    let lastOnline: String?
    let isOnline: Bool?

    var initials: String {
        let parts = nickname.split(separator: "_").prefix(2)
        if parts.isEmpty { return String(nickname.prefix(2)).uppercased() }
        return parts.map { String($0.prefix(1)).uppercased() }.joined()
    }

    var avatarURL: URL? {
        guard let avatar, !avatar.isEmpty else { return nil }
        if avatar.hasPrefix("http") { return URL(string: avatar) }
        return URL(string: Config.baseURL + avatar)
    }
}

// MARK: - Chat

struct Chat: Codable, Identifiable, Hashable {
    static func == (lhs: Chat, rhs: Chat) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    let id: String
    let type: String
    let name: String?
    let avatar: String?
    let description: String?
    let createdAt: String
    let updatedAt: String
    let members: [ChatMember]
    var messages: [Message]?

    var lastMessage: Message? { messages?.first }

    func displayName(currentUserId: String) -> String {
        if type == "GROUP" { return name ?? "Group" }
        return members.first(where: { $0.userId != currentUserId })?.user.nickname ?? "Chat"
    }

    func otherUser(currentUserId: String) -> User? {
        members.first(where: { $0.userId != currentUserId })?.user
    }

    func chatAvatarURL(currentUserId: String) -> URL? {
        if type == "GROUP" {
            guard let av = avatar, !av.isEmpty else { return nil }
            return URL(string: av.hasPrefix("http") ? av : Config.baseURL + av)
        }
        return otherUser(currentUserId: currentUserId)?.avatarURL
    }

    func chatInitials(currentUserId: String) -> String {
        if type == "GROUP" { return name.map { String($0.prefix(2)).uppercased() } ?? "GR" }
        return otherUser(currentUserId: currentUserId)?.initials ?? "??"
    }
}

struct ChatMember: Codable, Identifiable {
    let id: String
    let chatId: String
    let userId: String
    let role: String
    let joinedAt: String
    let user: User
}

struct ChatsData: Decodable {
    let chats: [Chat]
    let nextCursor: String?
}

// MARK: - Message

struct Message: Codable, Identifiable, Equatable {
    let id: String
    let chatId: String?
    let text: String?
    let ciphertext: String?
    let signalType: Int?
    let type: String?
    let mediaUrl: String?
    let replyToId: String?
    let isEdited: Bool?
    let isDeleted: Bool?
    let createdAt: String
    let updatedAt: String?
    let sender: MessageSender
    var readReceipts: [ReadReceipt]?
    var reactions: [Reaction]?
    let replyTo: ReplyTo?

    var createdDate: Date {
        ISO8601DateFormatter().date(from: createdAt) ?? Date()
    }

    var mediaFullURL: URL? {
        guard let url = mediaUrl, !url.isEmpty else { return nil }
        if url.hasPrefix("http") { return URL(string: url) }
        return URL(string: Config.baseURL + url)
    }

    var messageType: MsgType {
        MsgType(rawValue: type ?? "TEXT") ?? .text
    }

    static func == (lhs: Message, rhs: Message) -> Bool { lhs.id == rhs.id }
}

enum MsgType: String, Codable {
    case text = "TEXT"
    case image = "IMAGE"
    case file = "FILE"
    case audio = "AUDIO"
    case video = "VIDEO"
    case system = "SYSTEM"
}

struct MessagesData: Decodable {
    let messages: [Message]
    let nextCursor: String?
}

struct MessageSender: Codable, Equatable {
    let id: String
    let nickname: String
    let avatar: String?

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

struct Reaction: Codable, Identifiable, Equatable {
    let id: String
    let userId: String
    let emoji: String
}

struct ReplyTo: Codable, Equatable {
    let id: String
    let text: String?
    let isDeleted: Bool?
    let sender: MessageSender
}

// MARK: - Upload

struct UploadResult: Decodable {
    let url: String
    let type: String
    let name: String
    let size: Int
}
