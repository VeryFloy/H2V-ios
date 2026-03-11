import SwiftUI


// MARK: - MediaViewer

struct MediaViewer: View {
    let urls: [URL]
    let initialIndex: Int
    @Binding var isPresented: Bool

    @State private var currentIndex: Int
    @State private var dismissY: CGFloat = 0

    private var bgOpacity: Double {
        max(0.05, 1.0 - Double(max(0, dismissY)) / 280.0)
    }

    init(urls: [URL], initialIndex: Int, isPresented: Binding<Bool>) {
        self.urls = urls
        self.initialIndex = initialIndex
        self._isPresented = isPresented
        self._currentIndex = State(initialValue: max(0, min(initialIndex, urls.count - 1)))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                    .opacity(bgOpacity)
                    .ignoresSafeArea()
                    .animation(.linear(duration: 0.08), value: dismissY)

                // Pager
                TabView(selection: $currentIndex) {
                    ForEach(0..<urls.count, id: \.self) { i in
                        ZoomablePhoto(url: urls[i],
                                      availableSize: proxy.size,
                                      onSwipeDown: handleSwipeDown,
                                      onSwipeEnd: handleSwipeEnd)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(width: proxy.size.width, height: proxy.size.height)
                .offset(y: dismissY)

                // Close + counter
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button {
                            withAnimation(.spring(response: 0.25)) { isPresented = false }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                        }
                        .padding(.trailing, 20)
                    }
                    .padding(.top, proxy.safeAreaInsets.top + 16)

                    Spacer()

                    if urls.count > 1 {
                        pageIndicator
                            .padding(.bottom, proxy.safeAreaInsets.bottom + 24)
                    }
                }
                .opacity(bgOpacity)
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .statusBarHidden()
    }

    // MARK: Swipe-down callbacks (from ZoomablePhoto)

    private func handleSwipeDown(_ dy: CGFloat) {
        guard dy > 0 else { return }
        dismissY = dy
    }

    private func handleSwipeEnd(_ dy: CGFloat) {
        if dy > 100 {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                isPresented = false
            }
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                dismissY = 0
            }
        }
    }

    // MARK: Page Indicator

    private var pageIndicator: some View {
        Group {
            if urls.count <= 9 {
                HStack(spacing: 5) {
                    ForEach(0..<urls.count, id: \.self) { i in
                        Circle()
                            .fill(Color.white.opacity(i == currentIndex ? 0.9 : 0.3))
                            .frame(width: i == currentIndex ? 7 : 5,
                                   height: i == currentIndex ? 7 : 5)
                            .animation(.spring(response: 0.2), value: currentIndex)
                    }
                }
            } else {
                Text("\(currentIndex + 1) / \(urls.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.12), in: Capsule())
            }
        }
    }
}

// MARK: - ZoomablePhoto

struct ZoomablePhoto: View {
    let url: URL
    let availableSize: CGSize
    let onSwipeDown: (CGFloat) -> Void
    let onSwipeEnd: (CGFloat) -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let img):
                img
                    .resizable()
                    .scaledToFit()
                    .frame(width: availableSize.width, height: availableSize.height)
                    .clipped()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(pinchGesture)
                    .gesture(panGesture)
                    .gesture(verticalDismissGesture)
                    .onTapGesture(count: 2) { doubleTap() }

            case .failure:
                ZStack {
                    Color.clear
                    VStack(spacing: 14) {
                        Image(systemName: "photo.fill")
                            .font(.system(size: 44, weight: .thin))
                            .foregroundStyle(.white.opacity(0.25))
                        Text("Не удалось загрузить")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
                .frame(width: availableSize.width, height: availableSize.height)

            default:
                ZStack {
                    Color.clear
                    ProgressView()
                        .tint(.white.opacity(0.6))
                        .scaleEffect(1.3)
                }
                .frame(width: availableSize.width, height: availableSize.height)
            }
        }
        .frame(width: availableSize.width, height: availableSize.height)
    }

    // MARK: Gestures

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { val in
                scale = max(1, min(lastScale * val.magnification, 8))
            }
            .onEnded { _ in
                lastScale = scale
                if scale < 1.05 {
                    withAnimation(.spring(response: 0.3)) {
                        scale = 1; lastScale = 1
                        offset = .zero; lastOffset = .zero
                    }
                }
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { val in
                guard scale > 1.01 else { return }
                offset = CGSize(
                    width: lastOffset.width + val.translation.width,
                    height: lastOffset.height + val.translation.height
                )
            }
            .onEnded { _ in
                guard scale > 1.01 else { return }
                lastOffset = offset
            }
    }

    private var verticalDismissGesture: some Gesture {
        DragGesture(minimumDistance: 15, coordinateSpace: .global)
            .onChanged { val in
                guard scale <= 1.01 else { return }
                let isMoreVertical = abs(val.translation.height) > abs(val.translation.width)
                guard isMoreVertical && val.translation.height > 0 else { return }
                onSwipeDown(val.translation.height)
            }
            .onEnded { val in
                guard scale <= 1.01 else { return }
                onSwipeEnd(val.translation.height > 0 ? val.translation.height : 0)
            }
    }

    private func doubleTap() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
            if scale > 1.05 {
                scale = 1; lastScale = 1
                offset = .zero; lastOffset = .zero
            } else {
                scale = 2.5; lastScale = 2.5
            }
        }
    }
}
