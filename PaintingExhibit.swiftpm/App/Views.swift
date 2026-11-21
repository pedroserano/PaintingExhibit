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
                                       description: Text("Add photos to the album, then pull down to refresh."))
                    .padding(.top, 80)
            }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(library.paintings) { painting in
                    Button { selected = painting } label: {
                        Thumbnail(url: library.url(for: painting), version: painting.processedAt)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle(library.albumTitle ?? "Exhibit")
        .toolbar {
            Menu {
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
    let url: URL
    let version: Date
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
            .task(id: version) { image = await ImageLoader.load(url, maxPixel: 450) }
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

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            TabView(selection: $current) {
                ForEach(library.paintings) { painting in
                    PaintingPage(painting: painting, url: library.url(for: painting), showLabel: showLabel) {
                        withAnimation(.easeInOut(duration: 0.2)) { showLabel.toggle() }
                    }
                    .tag(painting.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            if showLabel {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                }
                .padding()
                .transition(.opacity)
            }
        }
        .statusBarHidden()
    }
}

struct PaintingPage: View {
    let painting: Painting
    let url: URL
    let showLabel: Bool
    let toggleLabel: () -> Void

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        ZStack(alignment: .bottom) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(24)
                    .scaleEffect(scale * pinch)
                    .offset(x: offset.width + drag.width, y: offset.height + drag.height)
                    .gesture(
                        MagnifyGesture()
                            .updating($pinch) { value, state, _ in state = value.magnification }
                            .onEnded { value in
                                scale = min(max(scale * value.magnification, 1), 6)
                                if scale == 1 { offset = .zero }
                            }
                    )
                    .simultaneousGesture(scale > 1 ? panGesture : nil)
                    .onTapGesture(count: 2) {
                        withAnimation { scale = scale > 1 ? 1 : 2.5; offset = .zero }
                    }
                    .onTapGesture { toggleLabel() }
            } else {
                ProgressView()
            }

            if showLabel && scale == 1 {
                WallLabel(painting: painting)
                    .padding(.bottom, 32)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: painting.processedAt) { image = await ImageLoader.load(url, maxPixel: 3000) }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .updating($drag) { value, state, _ in state = value.translation }
            .onEnded { value in
                offset.width += value.translation.width
                offset.height += value.translation.height
            }
    }
}

/// A museum-style caption. In phase 1 it shows only what the photo itself knows,
/// plus what the processing did, to help tune the results.
struct WallLabel: View {
    let painting: Painting

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
        var parts: [String] = []
        parts.append(painting.cropFound ? "cropped" : "no edges found")
        if painting.frameRemoved { parts.append("frame removed") }
        if painting.cropFound {
            parts.append("light colour corrected \(Int((painting.lightCorrection * 100).rounded()))%")
        }
        if painting.unevenLightFixed { parts.append("spotlight evened") }
        return parts.joined(separator: " · ")
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
