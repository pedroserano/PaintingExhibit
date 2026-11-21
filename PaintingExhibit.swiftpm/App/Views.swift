import SwiftUI
import Photos
import ImageIO

struct ContentView: View {
    @EnvironmentObject var library: Library

    var body: some View {
        NavigationStack {
            Group {
                if !library.accessChecked {
                    ProgressView()
                } else if !library.authorized {
                    AccessView()
                } else if library.albumID == nil {
                    AlbumPickerView()
                } else {
                    GalleryView()
                }
            }
        }
        .task { await library.requestAccess() }
    }
}

// MARK: Photos access

struct AccessView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Photos access needed", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Painting Exhibit needs to read your paintings album. Turn on access in Settings.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: Album picker

struct AlbumPickerView: View {
    @EnvironmentObject var library: Library
    @State private var albums: [PHAssetCollection] = []

    var body: some View {
        List(albums, id: \.localIdentifier) { album in
            Button {
                library.albumID = album.localIdentifier
            } label: {
                Label(album.localizedTitle ?? "Untitled album", systemImage: "rectangle.stack")
            }
        }
        .navigationTitle("Choose your paintings album")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { albums = library.albums() }
    }
}

// MARK: Gallery grid

struct GalleryView: View {
    @EnvironmentObject var library: Library
    @State private var selected: Painting?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            if library.isProcessing {
                ProgressView(value: Double(library.progressDone), total: Double(max(library.progressTotal, 1))) {
                    Text("Preparing paintings: \(library.progressDone) of \(library.progressTotal)")
                        .font(.footnote)
                }
                .padding(.horizontal)
            }
            if let error = library.lastError {
                Text(error).font(.footnote).foregroundStyle(.orange).padding(.horizontal)
            }
            if library.paintings.isEmpty && !library.isProcessing {
                ContentUnavailableView("No paintings yet", systemImage: "photo.artframe",
                                       description: Text("Add photos to the album and they'll appear here."))
                    .padding(.top, 80)
            }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(library.paintings) { painting in
                    Button { selected = painting } label: {
                        Thumbnail(painting: painting)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle(library.albumTitle ?? "Exhibit")
        .toolbar {
            Menu {
                Toggle(isOn: $library.keepFramesByDefault) {
                    Label("Show frames", systemImage: "square.dashed")
                }
                Divider()
                Button("Check for new paintings", systemImage: "arrow.clockwise") {
                    Task { await library.processNew() }
                }
                Button("Reprocess all", systemImage: "wand.and.stars") {
                    Task { await library.processNew(reprocessAll: true) }
                }
                Button("Change album", systemImage: "rectangle.stack") {
                    library.albumID = nil
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(library.isProcessing)
        }
        .refreshable { await library.processNew() }
        .task { await library.processNew() }
        .fullScreenCover(item: $selected) { painting in
            ExhibitView(startID: painting.id)
                .environmentObject(library)
        }
    }
}

struct Thumbnail: View {
    @EnvironmentObject var library: Library
    let painting: Painting
    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(Color(white: 0.11))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
                        .padding(12)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .task(id: painting.renderedAt) {
                guard let url = await library.imageURL(for: painting) else { return }
                image = await ImageLoader.load(url, maxPixel: 450)
            }
    }
}

// MARK: Full-screen exhibit

struct ExhibitView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var current: String
    @State private var showLabel = true

    init(startID: String) {
        _current = State(initialValue: startID)
    }

    private var currentPainting: Painting? {
        library.paintings.first { $0.id == current }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            TabView(selection: $current) {
                ForEach(library.paintings) { painting in
                    PaintingPage(painting: painting, showLabel: showLabel) {
                        withAnimation(.easeInOut(duration: 0.2)) { showLabel.toggle() }
                    }
                    .tag(painting.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            if showLabel {
                HStack {
                    if let painting = currentPainting, painting.settings.frameFound {
                        let keeps = library.keepsFrame(painting)
                        Button {
                            library.setKeepFrame(!keeps, for: painting.id)
                        } label: {
                            Label(keeps ? "Remove frame" : "Show frame", systemImage: keeps ? "crop" : "square.dashed")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                    }
                }
                .padding()
                .transition(.opacity)
            }
        }
        .statusBarHidden()
    }
}

struct PaintingPage: View {
    @EnvironmentObject var library: Library
    let painting: Painting
    let showLabel: Bool
    let toggleLabel: () -> Void

    @State private var image: UIImage?
    @State private var zoomed = false

    var body: some View {
        ZStack(alignment: .bottom) {
            if let image {
                ZoomableImage(image: image, onTap: toggleLabel, onZoomChange: { zoomed = $0 })
                    .ignoresSafeArea()
            } else {
                ProgressView()
            }

            if showLabel && !zoomed {
                WallLabel(painting: painting, keepsFrame: library.keepsFrame(painting))
                    .padding(.bottom, 32)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: painting.renderedAt) {
            guard let url = await library.imageURL(for: painting) else { return }
            image = await ImageLoader.load(url, maxPixel: 3000)
        }
    }
}

/// A museum-style caption. In phase 1 it shows only what the photo itself knows,
/// plus what the processing did, to help tune the results.
struct WallLabel: View {
    let painting: Painting
    let keepsFrame: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Not yet identified")
                .font(.system(.headline, design: .serif))
            if let date = painting.takenAt {
                Text("Photographed \(date.formatted(date: .long, time: .omitted))")
                    .font(.system(.subheadline, design: .serif))
            }
            Text(processingSummary)
                .font(.caption)
                .foregroundStyle(.black.opacity(0.55))
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 3))
        .shadow(radius: 6)
    }

    private var processingSummary: String {
        let s = painting.settings
        var parts: [String] = []
        parts.append(s.cropFound ? "cropped" : "no edges found")
        if s.frameFound {
            parts.append(s.keptFrame ? "frame kept" : "frame removed")
        } else if s.cropFound {
            parts.append("no frame found")
        }
        if s.cropFound {
            parts.append("light colour corrected \(Int((s.lightStrength * 100).rounded()))%")
        }
        if s.unevenLightFixed { parts.append("spotlight evened") }
        if keepsFrame != s.keptFrame { parts.append("updating…") }
        return parts.joined(separator: " · ")
    }
}

// MARK: Zooming

/// Pinch and double-tap zoom backed by UIScrollView. When the painting isn't zoomed, or a pan
/// reaches its edge, the swipe passes to the exhibit so you move to the next painting.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    var onTap: () -> Void
    var onZoomChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> ZoomingScrollView {
        let view = ZoomingScrollView()
        view.delegate = context.coordinator
        view.image = image

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTapped))
        singleTap.require(toFail: doubleTap)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(singleTap)
        return view
    }

    func updateUIView(_ view: ZoomingScrollView, context: Context) {
        context.coordinator.parent = self
        if view.image !== image { view.image = image }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableImage
        private var wasZoomed = false

        init(parent: ZoomableImage) { self.parent = parent }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ZoomingScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? ZoomingScrollView)?.centerContent()
            let zoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            if zoomed != wasZoomed {
                wasZoomed = zoomed
                let report = parent.onZoomChange
                DispatchQueue.main.async { report(zoomed) }
            }
        }

        @objc func singleTapped() { parent.onTap() }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? ZoomingScrollView else { return }
            if view.zoomScale > view.minimumZoomScale + 0.01 {
                view.setZoomScale(view.minimumZoomScale, animated: true)
            } else {
                let point = gesture.location(in: view.imageView)
                let scale: CGFloat = 2.5
                let size = CGSize(width: view.bounds.width / scale, height: view.bounds.height / scale)
                view.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                     width: size.width, height: size.height), animated: true)
            }
        }
    }
}

final class ZoomingScrollView: UIScrollView {
    let imageView = UIImageView()
    private let margin: CGFloat = 24
    private var laidOutSize: CGSize = .zero

    var image: UIImage? {
        get { imageView.image }
        set {
            imageView.image = newValue
            laidOutSize = .zero
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        minimumZoomScale = 1
        maximumZoomScale = 6
        bouncesZoom = true
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = imageView.image, bounds.width > 0, bounds.height > 0,
              image.size.width > 0, image.size.height > 0 else { return }
        if bounds.size != laidOutSize {
            // First layout, a new image or a rotation: fit the painting with a margin.
            laidOutSize = bounds.size
            zoomScale = minimumZoomScale
            let available = CGSize(width: max(1, bounds.width - 2 * margin), height: max(1, bounds.height - 2 * margin))
            let fit = min(available.width / image.size.width, available.height / image.size.height)
            let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
            imageView.frame = CGRect(origin: .zero, size: size)
            contentSize = size
            centerContent()
            contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
        } else {
            centerContent()
        }
    }

    /// Keeps the painting centred while it is smaller than the screen.
    func centerContent() {
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        let dy = max(0, (bounds.height - contentSize.height) / 2)
        let insets = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
        if contentInset != insets { contentInset = insets }
    }
}

// MARK: Image loading

enum ImageLoader {
    /// Loads a downscaled image from disk off the main thread.
    static func load(_ url: URL, maxPixel: Int) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                return nil
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
    }
}
