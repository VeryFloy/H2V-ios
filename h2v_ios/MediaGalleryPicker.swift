import SwiftUI
import Photos
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Media Gallery Picker (Telegram-style)

struct MediaGalleryPicker: View {
    let onSendPhotos: ([PHAsset]) -> Void
    let onPickDocument: () -> Void
    @Environment(\.dismiss) var dismiss

    @State private var allAssets: [PHAsset] = []
    @State private var selected: Set<String> = []
    @State private var authStatus: PHAuthorizationStatus = .notDetermined

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if authStatus == .authorized || authStatus == .limited {
                    galleryGrid
                    if !selected.isEmpty {
                        bottomBar
                    }
                } else if authStatus == .denied || authStatus == .restricted {
                    deniedView
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color.bgApp)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Галерея")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.textPrimary)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Text("Отмена")
                            .font(.system(size: 15))
                            .foregroundColor(.h2vAccent)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                        onPickDocument()
                    } label: {
                        Image(systemName: "doc")
                            .font(.system(size: 15))
                            .foregroundColor(.h2vAccent)
                    }
                }
            }
            .toolbarBackground(Color.bgSurface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .onAppear { requestAccess() }
    }

    private var galleryGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(allAssets, id: \.localIdentifier) { asset in
                    MediaThumbnailCell(
                        asset: asset,
                        isSelected: selected.contains(asset.localIdentifier),
                        selectionIndex: selectionIndex(asset)
                    )
                    .onTapGesture { toggleSelection(asset) }
                }
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            Text("\(selected.count) выбрано")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.textSecondary)

            Spacer()

            Button {
                let assets = allAssets.filter { selected.contains($0.localIdentifier) }
                dismiss()
                onSendPhotos(assets)
            } label: {
                HStack(spacing: 6) {
                    Text("Отправить")
                        .font(.system(size: 15, weight: .semibold))
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(LinearGradient.accentGradient, in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.bgSurface)
    }

    private var deniedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundColor(.textTertiary)
            Text("Нет доступа к фото")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.textPrimary)
            Text("Разрешите доступ в Настройках")
                .font(.system(size: 13))
                .foregroundColor(.textSecondary)
            Button("Открыть Настройки") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.h2vAccent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func requestAccess() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        authStatus = status
        if status == .authorized || status == .limited {
            loadAssets()
        } else if status == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                DispatchQueue.main.async {
                    authStatus = newStatus
                    if newStatus == .authorized || newStatus == .limited {
                        loadAssets()
                    }
                }
            }
        }
    }

    private func loadAssets() {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.fetchLimit = 200
        let result = PHAsset.fetchAssets(with: opts)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        allAssets = assets
    }

    private func toggleSelection(_ asset: PHAsset) {
        let id = asset.localIdentifier
        if selected.contains(id) {
            selected.remove(id)
        } else if selected.count < 10 {
            selected.insert(id)
        }
    }

    private func selectionIndex(_ asset: PHAsset) -> Int? {
        let id = asset.localIdentifier
        guard selected.contains(id) else { return nil }
        let ordered = allAssets.filter { selected.contains($0.localIdentifier) }
        return (ordered.firstIndex(where: { $0.localIdentifier == id }) ?? -1) + 1
    }
}

// MARK: - Thumbnail Cell

struct MediaThumbnailCell: View {
    let asset: PHAsset
    let isSelected: Bool
    var selectionIndex: Int?

    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            GeometryReader { geo in
                if let img = thumbnail {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.width)
                        .clipped()
                } else {
                    Color.bgCard
                        .frame(width: geo.size.width, height: geo.size.width)
                }
            }
            .aspectRatio(1, contentMode: .fit)

            ZStack {
                if isSelected {
                    Circle()
                        .fill(Color.h2vAccent)
                        .frame(width: 24, height: 24)
                    Text("\(selectionIndex ?? 0)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Circle()
                        .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                        .frame(width: 24, height: 24)
                        .background(Color.black.opacity(0.3), in: Circle())
                }
            }
            .padding(5)

            if asset.mediaType == .video {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "video.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.white)
                        Text(formatAssetDuration(asset.duration))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
                }
            }
        }
        .onAppear { loadThumbnail() }
    }

    private func loadThumbnail() {
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic
        opts.isNetworkAccessAllowed = true
        let size = CGSize(width: 200, height: 200)
        PHImageManager.default().requestImage(
            for: asset, targetSize: size, contentMode: .aspectFill, options: opts
        ) { img, _ in
            if let img { thumbnail = img }
        }
    }

    private func formatAssetDuration(_ dur: TimeInterval) -> String {
        let m = Int(dur) / 60
        let s = Int(dur) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - PHAsset → Data helper

private let maxImageDimension: CGFloat = 1920
private let jpegQuality: CGFloat = 0.72

private func resizeAndCompress(_ image: UIImage) -> Data? {
    let w = image.size.width, h = image.size.height
    let maxDim = max(w, h)
    var output = image
    if maxDim > maxImageDimension {
        let scale = maxImageDimension / maxDim
        let newSize = CGSize(width: w * scale, height: h * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        output = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }
    return output.jpegData(compressionQuality: jpegQuality)
}

func loadAssetData(_ asset: PHAsset, completion: @escaping (Data?, String, String) -> Void) {
    if asset.mediaType == .video {
        let opts = PHVideoRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.deliveryMode = .highQualityFormat
        PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { avAsset, _, _ in
            guard let urlAsset = avAsset as? AVURLAsset else {
                completion(nil, "video.mp4", "video/mp4")
                return
            }
            let data = try? Data(contentsOf: urlAsset.url)
            completion(data, "video_\(UUID().uuidString.prefix(8)).mp4", "video/mp4")
        }
    } else {
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.deliveryMode = .highQualityFormat
        opts.isSynchronous = false
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: opts) { data, _, _, _ in
            guard let data, let uiImage = UIImage(data: data) else {
                completion(nil, "photo.jpg", "image/jpeg")
                return
            }
            let jpegData = resizeAndCompress(uiImage)
            let filename = "photo_\(UUID().uuidString.prefix(8)).jpg"
            completion(jpegData, filename, "image/jpeg")
        }
    }
}
