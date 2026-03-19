<div align="center">

<img src="https://h2von.com/img/icon-white-512.png" alt="H2V" width="80" />

# H2V Messenger — iOS

### Native iOS client. Fast. Private. Open Source.

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Swift](https://img.shields.io/badge/Swift-5.9+-F05138?logo=swift&logoColor=white)](https://swift.org)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-5-007AFF?logo=apple&logoColor=white)](https://developer.apple.com/xcode/swiftui/)
[![iOS](https://img.shields.io/badge/iOS-18.2+-000000?logo=apple&logoColor=white)](https://developer.apple.com/ios/)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/VeryFloy/H2V-ios/pulls)

[Web App](https://web.h2von.com) · [Backend](https://github.com/VeryFloy/H2V-servers) · [Web Client](https://github.com/VeryFloy/H2V-web) · [Report Bug](https://github.com/VeryFloy/H2V-ios/issues) · [Request Feature](https://github.com/VeryFloy/H2V-ios/issues)

</div>

---

## About

The native iOS client for H2V Messenger — a next-generation messenger built on transparency, speed, and encryption by default. This app is written entirely in **Swift** and **SwiftUI**, with no third-party dependencies.

> H2V is in active development. The iOS client connects to the same backend as the [web app](https://web.h2von.com) and supports all core features.

---

## Features

### Messaging

Full-featured chat: **direct**, **group** (up to 200 members), **secret** (E2E encrypted), and **Saved Messages**. Reply, forward, edit, delete, pin messages. Rich text formatting — **bold**, *italic*, `code`, ~~strikethrough~~.

### Voice Messages

Telegram-style voice recording: **hold to record**, **release to send**, **swipe left to cancel**, **swipe up to lock** for hands-free recording. Live waveform visualization and duration counter with milliseconds.

### Media

Full-screen **media viewer** with horizontal swiping between photos/videos, pinch-to-zoom, and smooth drag-to-dismiss with progressive scaling and blur. **Media gallery picker** with multi-select, image editing, and file attachment.

### Real-Time

WebSocket-powered real-time updates: new messages, typing indicators, online/offline status, reactions, read receipts (sent ✓, delivered ✓✓, read 🔵). Messages appear instantly without pull-to-refresh.

### Profiles & Groups

User profiles with shared media gallery (photos, files, voice messages). Group management: add/remove members, change name/avatar, admin roles. Shared media is browsable and cached.

### Settings

Full settings ported from the web client with tabbed navigation:

| Tab | What's inside |
|---|---|
| **General** | Language, cache management |
| **Notifications** | Push notification preferences |
| **Chat** | Message display settings |
| **Privacy** | Online status, read receipts, profile visibility |
| **Sessions** | Active sessions, remote logout |

### Offline & Caching

Aggressive caching strategy: chat list, messages, avatars, and media are cached locally. Previously loaded chats render instantly from cache while fresh data loads in the background.

---

## Tech

| | |
|---|---|
| **Language** | [Swift 5.9+](https://swift.org) — modern, safe, fast |
| **UI** | [SwiftUI](https://developer.apple.com/xcode/swiftui/) — declarative, no UIKit wrapping |
| **Target** | iOS 18.2+ (iPhone) |
| **Networking** | URLSession — REST API + WebSocket, cookie-based auth |
| **Storage** | FileManager — JSON file cache for messages and chat lists |
| **Audio** | AVFoundation — recording, playback, waveform generation |
| **Dependencies** | **Zero** — no CocoaPods, no SPM packages, pure Apple frameworks |

---

## Project Structure

```
h2v_ios/
├── h2v_iosApp.swift          # App entry point, deep links
├── ContentView.swift          # Root view — auth gate + tab navigation
├── AuthView.swift             # Email OTP authentication (3-step flow)
├── ChatListView.swift         # Chat list with search, archive, swipe actions
├── ChatView.swift             # Message area, input bar, voice recording
├── Components.swift           # Shared UI components, theme, color system
├── Models.swift               # Data models (Chat, Message, User, etc.)
├── Network.swift              # APIClient + WebSocketClient
├── CacheManager.swift         # File-based caching (messages, chats, media)
├── MediaViewer.swift          # Full-screen media gallery with gestures
├── MediaGalleryPicker.swift   # Photo/video/file picker with editing
├── ProfileSettingsViews.swift # User profile, settings (5 tabs)
├── ProfileView.swift          # Group profile, shared media
├── CreateGroupView.swift      # Group creation flow
└── NotificationManager.swift  # Push notification handling
```

~8,000 lines of Swift across 15 source files. No generated code, no storyboards.

---

## Quick Start

### Prerequisites

- **Xcode 16+** with iOS 18.2 SDK
- An Apple Developer account (free or paid) for device testing
- An iPhone running **iOS 18.2+**

### Build & Run

```bash
git clone https://github.com/VeryFloy/H2V-ios.git
cd H2V-ios
open h2v_ios.xcodeproj
```

1. Open the project in Xcode
2. Select your development team in **Signing & Capabilities**
3. Connect your iPhone and select it as the build target
4. Press **⌘R** to build and run

The app connects to `https://h2von.com` by default. To point it at a local backend, edit the `baseURL` in `Network.swift`.

### Build from Command Line

```bash
xcodebuild -project h2v_ios.xcodeproj \
  -scheme h2v_ios \
  -sdk iphoneos \
  -configuration Release \
  CODE_SIGN_IDENTITY="Apple Development" \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  -allowProvisioningUpdates
```

---

## API Compatibility

This client is fully compatible with the [H2V backend API](https://github.com/VeryFloy/H2V-servers). Key endpoints:

| Method | Endpoint | Description |
|---|---|---|
| `POST` | `/api/auth/send-otp` | Send OTP to email |
| `POST` | `/api/auth/verify-otp` | Verify OTP, get session |
| `GET` | `/api/chats` | List all chats |
| `GET` | `/api/chats/:id/messages` | Message history (paginated) |
| `POST` | `/api/upload` | Upload media (max 20 MB) |
| `WS` | `/ws?token=` | Real-time WebSocket |

Full API reference: [H2V-servers API.md](https://github.com/VeryFloy/H2V-servers/blob/main/API.md)

---

## Roadmap

### Done — Q1 2026

- [x] Email OTP authentication
- [x] Direct, group, secret, and self chats
- [x] Text messages with formatting
- [x] Voice messages with waveform (Telegram-style UX)
- [x] Media: photos, videos, files
- [x] Full-screen media viewer with swipe & zoom
- [x] Reactions, replies, forwarding, pinning
- [x] Read receipts and delivery status
- [x] Real-time WebSocket (typing, online, reactions)
- [x] Offline caching
- [x] Full settings (5 tabs)
- [x] User & group profiles with shared media

### Next — Q2 2026

- [ ] Push notifications (APNs)
- [ ] E2E encryption for secret chats (Signal Protocol)
- [ ] Voice & video calls (WebRTC)
- [ ] iPad layout (split view)
- [ ] Chat export

### Later — Q3–Q4 2026

- [ ] Sticker packs
- [ ] Message search with date filters
- [ ] App lock (Face ID / Touch ID)
- [ ] Widgets (unread count, recent chats)
- [ ] Apple Watch companion

---

## Contributing

H2V is **open source** and we welcome contributions of all sizes.

1. **Fork** the repository
2. Create a branch: `git checkout -b feat/your-idea`
3. Commit using [Conventional Commits](https://www.conventionalcommits.org): `feat:`, `fix:`, `refactor:`
4. Open a **Pull Request** with a clear description

### Guidelines

- **SwiftUI only** — no UIKit views unless absolutely necessary
- **No third-party dependencies** — keep the project lean
- **CSS Modules convention** — styles should be scoped and modular (applies to web; iOS uses native theming)
- Follow the existing code style and naming conventions

---

## Related Repositories

| Repository | Description |
|---|---|
| [H2V-web](https://github.com/VeryFloy/H2V-web) | Web client (SolidJS PWA) |
| [H2V-servers](https://github.com/VeryFloy/H2V-servers) | Backend API (Express + Prisma) |
| **H2V-ios** | ← You are here |

---

## License

**GNU General Public License v3.0** — see [LICENSE](LICENSE).

You are free to use, modify, and distribute this software under the terms of the GPL v3. If you distribute modified versions, you must also make your source code available under the same license.

---

<div align="center">

**[h2von.com](https://h2von.com)**

Made with care by the H2V team.

</div>
