import SwiftUI
import AVKit

// MARK: - Media Viewer (Fullscreen, swipeable gallery)

struct MediaViewerView: View {
    let urls: [URL]
    let startIndex: Int
    @Environment(\.dismiss) var dismiss
    @State private var currentIndex: Int
    @State private var scale: CGFloat = 1
    @State private var dragOffset: CGFloat = 0
    @State private var bgOpacity: Double = 1
    @State private var isDraggingVertical = false

    init(url: URL) {
        self.urls = [url]
        self.startIndex = 0
        _currentIndex = State(initialValue: 0)
    }

    init(urls: [URL], startIndex: Int = 0) {
        self.urls = urls
        self.startIndex = startIndex
        _currentIndex = State(initialValue: startIndex)
    }

    private func isVideo(_ url: URL) -> Bool {
        ["mp4", "mov", "m4v", "webm"].contains(url.pathExtension.lowercased())
    }

    private var dismissProgress: CGFloat {
        min(abs(dragOffset) / 250.0, 1.0)
    }

    private var imageScale: CGFloat {
        let p = dismissProgress
        return 1.0 - p * p * 0.45
    }

    private var imageOpacity: Double {
        let p = Double(dismissProgress)
        return 1.0 - p * p * p
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .ignoresSafeArea()
                .opacity(bgOpacity)

            Color.black.opacity(0.55 * bgOpacity)
                .ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(urls.indices, id: \.self) { idx in
                    if isVideo(urls[idx]) {
                        VideoPlayer(player: AVPlayer(url: urls[idx]))
                            .ignoresSafeArea()
                            .tag(idx)
                    } else {
                        imageContent(urls[idx])
                            .tag(idx)
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: urls.count > 1 ? .automatic : .never))
            .ignoresSafeArea()
            .scaleEffect(imageScale)
            .opacity(imageOpacity)
            .offset(y: dragOffset)
            .gesture(verticalDismissGesture)

            VStack {
                header
                Spacer()
                footer
            }
            .opacity(max(1.0 - dismissProgress * 2.0, 0))
        }
        .statusBarHidden()
        .background(ClearBackground())
    }

    // MARK: - Vertical dismiss gesture

    private var verticalDismissGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                let h = abs(value.translation.height)
                let w = abs(value.translation.width)

                if !isDraggingVertical {
                    if h > w * 1.5 && h > 15 {
                        isDraggingVertical = true
                    }
                    return
                }

                guard scale <= 1.05 else { return }

                let raw = value.translation.height
                let resistance: CGFloat = 0.65
                dragOffset = raw * resistance
                bgOpacity = Double(1.0 - dismissProgress)
            }
            .onEnded { _ in
                guard isDraggingVertical else {
                    isDraggingVertical = false
                    return
                }

                if abs(dragOffset) > 70 {
                    withAnimation(.easeOut(duration: 0.28)) {
                        bgOpacity = 0
                        dragOffset = dragOffset > 0 ? 400 : -400
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { dismiss() }
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                        dragOffset = 0
                        bgOpacity = 1
                    }
                }
                isDraggingVertical = false
            }
    }

    // MARK: - Image (zoomable, no drag conflict)

    private func imageContent(_ url: URL) -> some View {
        CachedAsyncImage(url: url) { img in
            img.resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in scale = value.magnification }
                        .onEnded { _ in
                            withAnimation(.spring(response: 0.3)) {
                                scale = max(1, min(scale, 5))
                            }
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.3)) {
                        scale = scale > 1.1 ? 1 : 2.5
                    }
                }
        } placeholder: {
            ProgressView().tint(.white)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            if urls.count > 1 {
                Text("\(currentIndex + 1) / \(urls.count)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
                    .environment(\.colorScheme, .dark)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 20) {
            shareButton
            saveButton
        }
        .padding(.bottom, 44)
    }

    private var shareButton: some View {
        Button {
            guard currentIndex < urls.count else { return }
            Task {
                if let (data, _) = try? await APIClient.shared.downloadData(from: urls[currentIndex]) {
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(urls[currentIndex].lastPathComponent)
                    try? data.write(to: tempURL)
                    await MainActor.run {
                        let av = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
                        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                           let vc = scene.windows.first?.rootViewController {
                            vc.present(av, animated: true)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 17))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
        }
    }

    private var saveButton: some View {
        Button {
            guard currentIndex < urls.count else { return }
            Task {
                if let (data, _) = try? await APIClient.shared.downloadData(from: urls[currentIndex]),
                   let image = UIImage(data: data) {
                    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                }
            }
        } label: {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 17))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
        }
    }
}

// Makes the fullScreenCover background transparent so blur shows through
struct ClearBackground: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = InnerView()
        DispatchQueue.main.async {
            view.superview?.superview?.backgroundColor = .clear
        }
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}

    private class InnerView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            superview?.superview?.backgroundColor = .clear
        }
    }
}
