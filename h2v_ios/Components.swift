import SwiftUI
import UIKit

// MARK: - Hex Color Init

extension UIColor {
    convenience init(hex: String) {
        let h = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let r = CGFloat((int >> 16) & 0xFF) / 255
        let g = CGFloat((int >> 8)  & 0xFF) / 255
        let b = CGFloat(int         & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}

extension Color {
    init(hex: String) { self.init(UIColor(hex: hex)) }
}

// MARK: - Design Tokens (matching frontend style.css)

extension Color {
    // Dark theme primary
    static let bgApp = Color(hex: "0f1117")
    static let bgSurface = Color(hex: "13161f")
    static let bgCard = Color(hex: "1e2230")
    static let bgElevated = Color(hex: "252a37")
    static let bgInput = Color(hex: "1e2230")
    static let bgMsgMine = Color(hex: "8B5CF6").opacity(0.15)
    static let bgMsgOther = Color(hex: "1e2230")

    static let textPrimary = Color(hex: "e2e8f0")
    static let textSecondary = Color(hex: "64748b")
    static let textTertiary = Color(hex: "475569")
    static let textLink = Color(hex: "a78bfa")

    static let h2vAccent = Color(hex: "8B5CF6")
    static let h2vAccentHover = Color(hex: "7C3AED")
    static let success = Color(hex: "10b981")
    static let danger = Color(hex: "ef4444")
    static let warning = Color(hex: "f59e0b")

    static let borderPrimary = Color.white.opacity(0.06)
    static let borderCard = Color(hex: "252a37")

    static let h2vAccentGradientStart = Color(hex: "8B5CF6")
    static let h2vAccentGradientEnd = Color(hex: "7C3AED")
    static let avatarGradientEnd = Color(hex: "06b6d4")
}

// MARK: - Gradients

extension LinearGradient {
    static let accentGradient = LinearGradient(
        colors: [Color.h2vAccentGradientStart, Color.h2vAccentGradientEnd],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let avatarGradient = LinearGradient(
        colors: [Color.h2vAccent, Color.avatarGradientEnd],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

// MARK: - View Modifiers

extension View {
    func cardBackground(radius: CGFloat = 12) -> some View {
        self
            .background(Color.bgCard, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.borderPrimary, lineWidth: 0.5)
            }
    }

    func inputStyle(radius: CGFloat = 12) -> some View {
        self
            .background(Color.bgInput, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
            }
    }
}

// MARK: - Avatar View

struct AvatarView: View {
    let url: URL?
    let initials: String
    let size: CGFloat
    var isOnline: Bool = false
    var id: String = ""

    private var bgColor: Color {
        if id.isEmpty { return Color.h2vAccent }
        let hash = id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.5, brightness: 0.7)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let url {
                    CachedAsyncImage(url: url) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        initialsView
                    }
                } else {
                    initialsView
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))

            if isOnline {
                Circle()
                    .fill(Color.success)
                    .frame(width: size * 0.28, height: size * 0.28)
                    .overlay(Circle().stroke(Color.bgApp, lineWidth: 2))
                    .offset(x: 2, y: 2)
            }
        }
    }

    private var initialsView: some View {
        ZStack {
            LinearGradient.avatarGradient
            Text(initials)
                .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
    }
}

// MARK: - Search Bar

struct SearchBar: View {
    @Binding var text: String
    var placeholder = "Поиск..."

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.textTertiary)
            TextField("", text: $text,
                      prompt: Text(placeholder).foregroundColor(.textTertiary))
                .foregroundColor(.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.textTertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .inputStyle(radius: 14)
    }
}

// MARK: - Unread Badge

struct UnreadBadge: View {
    let count: Int
    var muted: Bool = false

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(muted ? .textTertiary : .white)
                .padding(.horizontal, 5)
                .frame(minWidth: 20, minHeight: 20)
                .background(muted ? Color.textTertiary.opacity(0.3) : Color.h2vAccent, in: Capsule())
        }
    }
}

// MARK: - Accent Button

struct AccentButton: View {
    let title: String
    var isLoading: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                disabled
                    ? AnyShapeStyle(Color.bgElevated)
                    : AnyShapeStyle(LinearGradient.accentGradient),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .shadow(color: disabled ? .clear : Color.h2vAccent.opacity(0.3), radius: 12, y: 4)
        }
        .disabled(disabled || isLoading)
    }
}

// MARK: - Date Formatting

enum DateHelper {
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let weekFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "EEE"; return f
    }()
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "dd.MM.yy"; return f
    }()
    private static let fullDateFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMMM yyyy"; return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFallback = ISO8601DateFormatter()

    static func parse(_ s: String) -> Date {
        iso.date(from: s) ?? isoFallback.date(from: s) ?? Date()
    }

    static func time(_ s: String) -> String {
        timeFmt.string(from: parse(s))
    }

    static func chatRow(_ s: String) -> String {
        let d = parse(s)
        let cal = Calendar.current
        if cal.isDateInToday(d) { return timeFmt.string(from: d) }
        if cal.isDateInYesterday(d) { return "вчера" }
        if let days = cal.dateComponents([.day], from: d, to: .now).day, days < 7 { return weekFmt.string(from: d) }
        return dateFmt.string(from: d)
    }

    static func fullDate(_ s: String) -> String {
        fullDateFmt.string(from: parse(s))
    }

    static func lastSeen(_ s: String?) -> String {
        guard let s else { return "" }
        let d = parse(s)
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "был(а) сегодня в \(timeFmt.string(from: d))" }
        if cal.isDateInYesterday(d) { return "был(а) вчера в \(timeFmt.string(from: d))" }
        return "был(а) \(dateFmt.string(from: d))"
    }

    static func dateSeparator(_ s: String) -> String {
        let d = parse(s)
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Сегодня" }
        if cal.isDateInYesterday(d) { return "Вчера" }
        return fullDateFmt.string(from: d)
    }
}

// MARK: - Typing Indicator

struct TypingIndicatorView: View {
    @State private var phase: Double = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.textSecondary)
                    .frame(width: 5, height: 5)
                    .scaleEffect(1 + 0.5 * sin(phase + Double(i) * .pi / 1.5))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.bgCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
    }
}

// MARK: - Session-bound Secret Chats

final class SecretChatSessionStore {
    static let shared = SecretChatSessionStore()
    private let sessionIdKey = "h2v_session_id"
    private let secretChatsKey = "h2v_secret_chats"

    var currentSessionId: String {
        if let id = UserDefaults.standard.string(forKey: sessionIdKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: sessionIdKey)
        return id
    }

    func rotateSession() {
        UserDefaults.standard.set(UUID().uuidString, forKey: sessionIdKey)
        UserDefaults.standard.removeObject(forKey: secretChatsKey)
    }

    func registerSecretChat(_ chatId: String) {
        var ids = registeredIds
        ids.insert(chatId)
        UserDefaults.standard.set(Array(ids), forKey: secretChatsKey)
    }

    func isAllowed(_ chatId: String) -> Bool {
        registeredIds.contains(chatId)
    }

    private var registeredIds: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: secretChatsKey) ?? [])
    }
}

// MARK: - Rich Text (formatting + auto-link)

struct RichTextView: View {
    let text: String
    let fontSize: CGFloat

    init(_ text: String, fontSize: CGFloat = 14) {
        self.text = text
        self.fontSize = fontSize
    }

    var body: some View {
        Text(RichTextParser.parse(text, fontSize: fontSize))
    }
}

enum RichTextParser {
    private struct Span {
        let location: Int
        let length: Int
        let innerLocation: Int
        let innerLength: Int
        let apply: (inout AttributedString, Range<AttributedString.Index>, CGFloat) -> Void
    }

    private struct Rule {
        let regex: NSRegularExpression
        let apply: (inout AttributedString, Range<AttributedString.Index>, CGFloat) -> Void
    }

    private static let rules: [Rule] = {
        var r: [Rule] = []
        func add(_ pat: String, _ apply: @escaping (inout AttributedString, Range<AttributedString.Index>, CGFloat) -> Void) {
            if let regex = try? NSRegularExpression(pattern: pat, options: []) {
                r.append(Rule(regex: regex, apply: apply))
            }
        }
        add(#"\*\*(.+?)\*\*"#) { s, r, sz in s[r].font = .system(size: sz, weight: .bold) }
        add(#"__(.+?)__"#)     { s, r, sz in s[r].font = .system(size: sz, weight: .bold) }
        add(#"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#) { s, r, _ in s[r].font = .system(.body).italic() }
        add(#"~~(.+?)~~"#)     { s, r, _ in s[r].strikethroughStyle = .single }
        add(#"`(.+?)`"#)       { s, r, _ in
            s[r].font = .system(size: 13, design: .monospaced)
            s[r].backgroundColor = Color.white.opacity(0.08)
        }
        add(#"<b>(.+?)</b>"#)            { s, r, sz in s[r].font = .system(size: sz, weight: .bold) }
        add(#"<strong>(.+?)</strong>"#)  { s, r, sz in s[r].font = .system(size: sz, weight: .bold) }
        add(#"<i>(.+?)</i>"#)            { s, r, _ in s[r].font = .system(.body).italic() }
        add(#"<em>(.+?)</em>"#)          { s, r, _ in s[r].font = .system(.body).italic() }
        add(#"<s>(.+?)</s>"#)            { s, r, _ in s[r].strikethroughStyle = .single }
        add(#"<strike>(.+?)</strike>"#)  { s, r, _ in s[r].strikethroughStyle = .single }
        add(#"<del>(.+?)</del>"#)        { s, r, _ in s[r].strikethroughStyle = .single }
        add(#"<u>(.+?)</u>"#)            { s, r, _ in s[r].underlineStyle = .single }
        add(#"<code>(.+?)</code>"#)      { s, r, _ in
            s[r].font = .system(size: 13, design: .monospaced)
            s[r].backgroundColor = Color.white.opacity(0.08)
        }
        return r
    }()

    private static let urlRegex = try! NSRegularExpression(
        pattern: #"(https?://[^\s<>"{}|\\^`\[\]]+)"#
    )

    static func parse(_ text: String, fontSize: CGFloat) -> AttributedString {
        var spans: [Span] = []
        let nsText = text as NSString
        let fullNSRange = NSRange(location: 0, length: nsText.length)

        for rule in rules {
            for match in rule.regex.matches(in: text, range: fullNSRange) {
                guard match.numberOfRanges >= 2 else { continue }
                let full = match.range
                let inner = match.range(at: 1)
                guard inner.location != NSNotFound else { continue }
                spans.append(Span(location: full.location, length: full.length,
                                  innerLocation: inner.location, innerLength: inner.length,
                                  apply: rule.apply))
            }
        }

        spans.sort { $0.location > $1.location }
        var used = IndexSet()
        var filtered: [Span] = []
        for span in spans.reversed() {
            let range = span.location..<(span.location + span.length)
            if used.intersects(integersIn: range) { continue }
            used.insert(integersIn: range)
            filtered.append(span)
        }
        filtered.sort { $0.location > $1.location }

        var clean = text
        var offsets: [(innerStart: Int, innerLen: Int, prefixRemoved: Int, suffixRemoved: Int, apply: (inout AttributedString, Range<AttributedString.Index>, CGFloat) -> Void)] = []

        for span in filtered {
            let fullStart = clean.index(clean.startIndex, offsetBy: span.location)
            let fullEnd = clean.index(fullStart, offsetBy: span.length)
            let innerStart = clean.index(clean.startIndex, offsetBy: span.innerLocation)
            let innerEnd = clean.index(innerStart, offsetBy: span.innerLength)
            let inner = String(clean[innerStart..<innerEnd])

            let prefixLen = span.innerLocation - span.location
            let suffixLen = span.length - span.innerLength - prefixLen

            clean.replaceSubrange(fullStart..<fullEnd, with: inner)

            let newStart = clean.distance(from: clean.startIndex, to: fullStart)
            offsets.append((newStart, inner.count, prefixLen, suffixLen, span.apply))
        }

        var result = AttributedString(clean)
        result.font = .system(size: fontSize)
        result.foregroundColor = .textPrimary

        for o in offsets {
            let start = clean.index(clean.startIndex, offsetBy: o.innerStart)
            let end = clean.index(start, offsetBy: o.innerLen)
            if let attrRange = Range(start..<end, in: result) {
                o.apply(&result, attrRange, fontSize)
            }
        }

        let cleanNSRange = NSRange(clean.startIndex..., in: clean)
        for match in urlRegex.matches(in: clean, range: cleanNSRange) {
            guard let range = Range(match.range, in: clean),
                  let attrRange = Range(range, in: result),
                  let url = URL(string: String(clean[range])) else { continue }
            result[attrRange].link = url
            result[attrRange].foregroundColor = .h2vAccent
            result[attrRange].underlineStyle = .single
        }

        return result
    }
}

// MARK: - Emoji Picker

let commonEmojis = ["❤️", "👍", "😂", "😮", "😢", "🔥", "👎", "🎉"]

// MARK: - Swipe-back gesture fix for hidden navigation bar

extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        false
    }
}

// MARK: - Waveform Generator

enum WaveformGenerator {
    static func generate(from data: Data, barCount: Int = 32) -> [CGFloat] {
        guard data.count > 100 else { return fallback(seed: "empty", count: barCount) }

        let bytes = [UInt8](data)
        let step = max(1, bytes.count / (barCount * 50))
        let chunkSize = max(1, bytes.count / barCount)
        var peaks = [CGFloat](repeating: 0, count: barCount)

        for i in 0..<barCount {
            var peak: CGFloat = 0
            let start = i * chunkSize
            let end = min(start + chunkSize, bytes.count)
            var j = start
            while j < end {
                let val = CGFloat(abs(Int16(Int8(bitPattern: bytes[j])))) / 128.0
                if val > peak { peak = val }
                j += step
            }
            peaks[i] = peak
        }

        let maxPeak = peaks.max() ?? 0.001
        return peaks.map { max(0.06, $0 / maxPeak) }
    }

    static func fallback(seed: String, count: Int = 32) -> [CGFloat] {
        var hash: UInt32 = 0
        for c in seed.unicodeScalars {
            hash = hash &* 31 &+ c.value
        }
        var bars = [CGFloat]()
        for _ in 0..<count {
            hash = hash &* 1103515245 &+ 12345
            let val = CGFloat(hash % 80) / 100.0 + 0.10
            bars.append(val)
        }
        return bars
    }
}

// MARK: - Waveform View

struct WaveformView: View {
    var seed: String = ""
    var bars: [CGFloat]?
    var progress: Double = 0
    var accentColor: Color = .h2vAccent
    var barCount: Int = 32

    private var waveData: [CGFloat] {
        if let bars, bars.count == barCount { return bars }
        return WaveformGenerator.fallback(seed: seed, count: barCount)
    }

    var body: some View {
        GeometryReader { geo in
            let barWidth: CGFloat = max(2, (geo.size.width - CGFloat(barCount - 1) * 1.5) / CGFloat(barCount))
            let spacing: CGFloat = 1.5

            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    let h = waveData[i] * geo.size.height
                    let filled = Double(i) / Double(barCount) < progress

                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(filled ? accentColor : accentColor.opacity(0.35))
                        .frame(width: barWidth, height: max(2, h))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
