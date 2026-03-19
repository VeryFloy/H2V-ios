import Foundation
import SwiftUI

final class CacheManager: @unchecked Sendable {
    static let shared = CacheManager()

    private let fm = FileManager.default
    private let cacheDir: URL
    private let messagesDir: URL
    private let mediaDir: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let queue = DispatchQueue(label: "h2v.cache", qos: .utility)

    init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("h2v_cache", isDirectory: true)
        cacheDir = base
        messagesDir = base.appendingPathComponent("messages", isDirectory: true)
        mediaDir = base.appendingPathComponent("media", isDirectory: true)
        for dir in [cacheDir, messagesDir, mediaDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Chat List

    func saveChats(_ chats: [Chat]) {
        queue.async { [self] in
            let url = cacheDir.appendingPathComponent("chatlist.json")
            try? encoder.encode(chats).write(to: url, options: .atomic)
        }
    }

    func loadChats() -> [Chat] {
        let url = cacheDir.appendingPathComponent("chatlist.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([Chat].self, from: data)) ?? []
    }

    func saveArchivedChats(_ chats: [Chat]) {
        queue.async { [self] in
            let url = cacheDir.appendingPathComponent("archived.json")
            try? encoder.encode(chats).write(to: url, options: .atomic)
        }
    }

    func loadArchivedChats() -> [Chat] {
        let url = cacheDir.appendingPathComponent("archived.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([Chat].self, from: data)) ?? []
    }

    // MARK: - Messages

    func saveMessages(_ messages: [Message], chatId: String) {
        queue.async { [self] in
            let url = messagesDir.appendingPathComponent("\(chatId).json")
            try? encoder.encode(messages).write(to: url, options: .atomic)
        }
    }

    func loadMessages(chatId: String) -> [Message] {
        let url = messagesDir.appendingPathComponent("\(chatId).json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([Message].self, from: data)) ?? []
    }

    func appendMessages(_ newMessages: [Message], chatId: String) {
        queue.async { [self] in
            var existing = loadMessages(chatId: chatId)
            let existingIds = Set(existing.map(\.id))
            let unique = newMessages.filter { !existingIds.contains($0.id) }
            existing.append(contentsOf: unique)
            let url = messagesDir.appendingPathComponent("\(chatId).json")
            try? encoder.encode(existing).write(to: url, options: .atomic)
        }
    }

    // MARK: - Media Cache

    func mediaPath(for urlString: String) -> URL {
        let hash = urlString.data(using: .utf8)!.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .prefix(64)
        let ext = (urlString as NSString).pathExtension
        return mediaDir.appendingPathComponent("\(hash).\(ext.isEmpty ? "dat" : ext)")
    }

    func cachedMedia(for urlString: String) -> URL? {
        let path = mediaPath(for: urlString)
        return fm.fileExists(atPath: path.path) ? path : nil
    }

    func cacheMedia(data: Data, for urlString: String) {
        queue.async { [self] in
            let path = mediaPath(for: urlString)
            try? data.write(to: path, options: .atomic)
        }
    }

    func cacheMediaFromURL(_ remoteURL: URL, key: String) async -> URL? {
        if let cached = cachedMedia(for: key) { return cached }
        guard let (data, _) = try? await URLSession.shared.data(from: remoteURL) else { return nil }
        cacheMedia(data: data, for: key)
        return mediaPath(for: key)
    }

    // MARK: - Cleanup

    func clearAll() {
        queue.async { [self] in
            try? fm.removeItem(at: cacheDir)
            try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try? fm.createDirectory(at: messagesDir, withIntermediateDirectories: true)
            try? fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        }
    }

    func cacheSize() -> Int64 {
        guard let enumerator = fm.enumerator(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    func totalSizeMB() -> Double {
        Double(cacheSize()) / (1024.0 * 1024.0)
    }
}

// MARK: - Cached AsyncImage

struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var loadedImage: UIImage?

    var body: some View {
        if let image = loadedImage {
            content(Image(uiImage: image))
        } else if let url {
            placeholder()
                .task { await loadImage(url: url) }
        } else {
            placeholder()
        }
    }

    private func loadImage(url: URL) async {
        let key = url.absoluteString
        if let cached = CacheManager.shared.cachedMedia(for: key),
           let data = try? Data(contentsOf: cached),
           let img = UIImage(data: data) {
            loadedImage = img
            return
        }
        guard let (data, _) = try? await APIClient.shared.downloadData(from: url),
              let img = UIImage(data: data) else { return }
        CacheManager.shared.cacheMedia(data: data, for: key)
        loadedImage = img
    }
}
