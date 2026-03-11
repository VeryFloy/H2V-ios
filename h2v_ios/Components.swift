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

// MARK: - Adaptive Design Tokens

extension Color {
    /// Main app background — adapts to light/dark
    static let appBg = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(hex: "0d0d0d")
            : UIColor(hex: "F2F2F7")
    })

    /// Glass surface panel
    static let glassSurface = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.149, green: 0.149, blue: 0.173, alpha: 1)
            : UIColor(red: 1, green: 1, blue: 1, alpha: 0.92)
    })

    /// Glass panel border
    static let glassBorder = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.13)
            : UIColor.black.withAlphaComponent(0.07)
    })

    /// My message bubble
    static let bubbleMe = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.13)
            : UIColor(hex: "D0E8FF")
    })

    /// Their message bubble
    static let bubbleThem = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.07)
            : UIColor.white
    })

    /// Primary text
    static let textPrimary = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.92)
            : UIColor.black.withAlphaComponent(0.88)
    })

    /// Secondary text
    static let textSecondary = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.33)
            : UIColor.black.withAlphaComponent(0.38)
    })

    /// Tertiary / placeholder text
    static let textTertiary = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.2)
            : UIColor.black.withAlphaComponent(0.2)
    })

    static let onlineGreen = Color(hex: "30D158")
    static let dangerRed   = Color(hex: "FF3B30")
    static let badgeBg     = Color.white
    static let badgeFg     = Color.black
}

// MARK: - Avatar Pastel Palette

private let avatarPalette: [Color] = [
    Color(hex: "E8D5B7"), Color(hex: "B7D4E8"), Color(hex: "E8B7B7"),
    Color(hex: "C5B7E8"), Color(hex: "B7E8C5"), Color(hex: "E8C5B7"),
    Color(hex: "D4E8B7"), Color(hex: "B7E8D4"), Color(hex: "E8D4C5"),
    Color(hex: "C5D4E8"),
]

func avatarColor(for id: String) -> Color {
    let hash = id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
    return avatarPalette[abs(hash) % avatarPalette.count]
}

// MARK: - Glass View Modifiers

extension View {
    func glassBackground(cornerRadius: CGFloat = 16, opacity: Double = 0.52) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.glassSurface.opacity(opacity))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.glassBorder, lineWidth: 0.5)
            }
    }

    func glassCapsule(opacity: Double = 0.52) -> some View {
        self
            .background { Capsule().fill(Color.glassSurface.opacity(opacity)) }
            .overlay { Capsule().stroke(Color.glassBorder, lineWidth: 0.5) }
    }
}

// MARK: - Avatar View

struct AvatarView: View {
    let url: URL?
    let initials: String
    let size: CGFloat
    var isOnline: Bool = false
    var avatarColorOverride: Color? = nil
    var square: Bool = false

    private var color: Color { avatarColorOverride ?? Color(hex: "B7D4E8") }
    private var radius: CGFloat { square ? size * 0.28 : size / 2 }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let url {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        default: initialsContent
                        }
                    }
                } else {
                    initialsContent
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(color.opacity(0.28), lineWidth: 1)
            }

            if isOnline {
                Circle()
                    .fill(Color.onlineGreen)
                    .frame(width: size * 0.24, height: size * 0.24)
                    .overlay(Circle().stroke(Color.appBg, lineWidth: size * 0.05))
                    .offset(x: 1, y: 1)
            }
        }
    }

    private var initialsContent: some View {
        ZStack {
            color.opacity(0.15)
            Text(initials)
                .font(.system(size: size * 0.34, weight: .bold))
                .foregroundStyle(color)
                .letterSpacing(-0.3)
        }
    }
}

// MARK: - Glass Search Bar

struct GlassSearchBar: View {
    @Binding var text: String
    var placeholder = "Search"
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.textTertiary)
            TextField("", text: $text,
                      prompt: Text(placeholder).foregroundStyle(Color.textTertiary))
                .foregroundStyle(Color.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassBackground(cornerRadius: 14, opacity: 0.38)
    }
}

// MARK: - Glass Button

struct GlassCircleButton: View {
    let icon: String
    let size: CGFloat
    var iconSize: CGFloat = 15
    var iconColor: Color = Color.textSecondary
    var action: (() -> Void)? = nil

    var body: some View {
        Button { action?() } label: {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: size, height: size)
                .glassBackground(cornerRadius: size / 2, opacity: 0.45)
        }
    }
}

// MARK: - Typing Indicator

struct TypingIndicatorView: View {
    @State private var phase: Double = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.textSecondary)
                    .frame(width: 5, height: 5)
                    .scaleEffect(1 + 0.5 * sin(phase + Double(i) * .pi / 1.5))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassBackground(cornerRadius: 18, opacity: 0.4)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
    }
}

// MARK: - Glass Input Field

struct GlassInputField: View {
    let label: String
    @Binding var text: String
    var secure: Bool = false
    var keyboard: UIKeyboardType = .default
    var autocap: TextInputAutocapitalization = .sentences

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.textTertiary)
                .padding(.horizontal, 2)
            Group {
                if secure {
                    SecureField("", text: $text)
                } else {
                    TextField("", text: $text)
                        .keyboardType(keyboard)
                        .textInputAutocapitalization(autocap)
                        .autocorrectionDisabled()
                }
            }
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .glassBackground(cornerRadius: 12, opacity: 0.38)
        }
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
                .foregroundStyle(muted ? Color.textTertiary : .black)
                .padding(.horizontal, 5)
                .frame(minWidth: 20, minHeight: 20)
                .background(muted ? Color.textTertiary.opacity(0.2) : .white, in: Capsule())
        }
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.textTertiary)
            .tracking(0.9)
    }
}

// MARK: - Date Formatter

enum MessageTime {
    static private let timeFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    static private let weekFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE"; return f }()
    static private let dateFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd.MM.yy"; return f }()
    static private let iso = ISO8601DateFormatter()

    static func shortTime(from s: String) -> String {
        guard let d = iso.date(from: s) else { return "" }
        return timeFmt.string(from: d)
    }

    static func rowTime(from s: String) -> String {
        guard let d = iso.date(from: s) else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return timeFmt.string(from: d) }
        if cal.isDateInYesterday(d) { return "Вчера" }
        if let days = cal.dateComponents([.day], from: d, to: .now).day, days < 7 { return weekFmt.string(from: d) }
        return dateFmt.string(from: d)
    }

    static func date(from s: String) -> Date { iso.date(from: s) ?? .now }
}

// MARK: - Helper

extension Text {
    func letterSpacing(_ v: Double) -> Text { self.tracking(v) }
}
