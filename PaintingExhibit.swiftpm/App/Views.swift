import SwiftUI
import Photos
import ImageIO

#if os(iOS)
import UIKit
#else
import AppKit
#endif

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
            #if os(iOS)
            Text("Painting Exhibit needs to read your paintings album. Turn on access in Settings.")
            #else
            Text("Painting Exhibit needs to read your paintings album. Turn on access in System Settings › Privacy & Security › Photos.")
            #endif
        } actions: {
            Button("Open Settings") { openPrivacySettings() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func openPrivacySettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
            NSWorkspace.shared.open(url)
        }
        #endif
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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { albums = library.albums() }
    }
}

// MARK: Settings

struct SettingsView: View {
    @EnvironmentObject var library: Library

    var body: some View {
        Form {
            Section {
                Toggle("Show frames", isOn: $library.keepFramesByDefault)
            } footer: {
                Text("You can still show or remove the frame on each painting.")
            }

            IdentifySettings()

            Section {
                Toggle("Save edits to Photos", isOn: $library.saveEditsToPhotos)
                if library.editedInPhotosCount > 0 {
                    Button("Remove Edits from Photos (\(library.editedInPhotosCount))", role: .destructive) {
                        Task { await library.removeEditsFromPhotos() }
                    }
                    .disabled(library.isProcessing)
                }
            } footer: {
                Text("""
                Also adds each painting's crop and corrections to the photo in Photos, as an edit. \
                Photos keeps the original, so you can undo it with Revert to Original in Photos, \
                or for all paintings with the button above. You'll be asked to allow each batch of changes. \
                Reverting also removes any edits made in Photos before this app's edit.
                """)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Gallery grid

struct GalleryView: View {
    @EnvironmentObject var library: Library
    @State private var selected: Painting?
    @State private var showSettings = false
    /// The painting picked out with the arrow keys (Return or Space opens it).
    @State private var highlighted: String?
    @State private var columnCount = 1
    @State private var reviewOnly = false
    @FocusState private var gridFocused: Bool

    /// The paintings shown: all of them, or only possible matches waiting to be checked.
    private var shown: [Painting] {
        reviewOnly ? library.paintings.filter { $0.identification?.status == .possible } : library.paintings
    }

    private static let minimumWidth: CGFloat = 150, spacing: CGFloat = 12
    private let columns = [GridItem(.adaptive(minimum: GalleryView.minimumWidth), spacing: GalleryView.spacing)]

    private func open(_ painting: Painting) {
        highlighted = painting.id
        selected = painting
    }

    /// Moves the highlight by `delta` paintings (a whole row for up and down).
    private func move(_ delta: Int) -> KeyPress.Result {
        let ids = shown.map(\.id)
        guard !ids.isEmpty else { return .ignored }
        let now = highlighted.flatMap { ids.firstIndex(of: $0) }
        let next = now.map { min(max($0 + delta, 0), ids.count - 1) } ?? 0
        highlighted = ids[next]
        return .handled
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            if library.isProcessing {
                ProgressView(value: Double(library.progressDone), total: Double(max(library.progressTotal, 1))) {
                    Text("Preparing paintings: \(library.progressDone) of \(library.progressTotal)")
                        .font(.footnote)
                }
                .padding(.horizontal)
            }
            if library.isIdentifying {
                ProgressView(value: Double(library.identifyDone), total: Double(max(library.identifyTotal, 1))) {
                    Text("Identifying paintings: \(library.identifyDone) of \(library.identifyTotal)")
                        .font(.footnote)
                }
                .padding(.horizontal)
            }
            if let museum = library.indexingMuseum {
                ProgressView(value: Double(library.indexDone), total: Double(max(library.indexTotal, 1))) {
                    Text(library.indexTotal == 0 ? "Listing the paintings of \(museum)…"
                         : "Fetching the paintings of \(museum) to compare with yours: \(library.indexDone) of \(library.indexTotal) (once only)")
                        .font(.footnote)
                }
                .padding(.horizontal)
            }
            if reviewOnly {
                Text(shown.isEmpty ? "No matches left to check." :
                        "Possible matches to check: open each one and confirm it, choose another, or type the details.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            }
            if let error = library.lastError {
                Text(error).font(.footnote).foregroundStyle(.orange).padding(.horizontal)
            }
            if library.paintings.isEmpty && !library.isProcessing {
                ContentUnavailableView("No paintings yet", systemImage: "photo.artframe",
                                       description: Text("Add photos to the album and they'll appear here."))
                    .padding(.top, 80)
            }
            LazyVGrid(columns: columns, spacing: Self.spacing) {
                ForEach(shown) { painting in
                    Button { open(painting) } label: {
                        Thumbnail(painting: painting)
                            .overlay {
                                if highlighted == painting.id {
                                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 3)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .id(painting.id)
                }
            }
            .padding()
            .background {
                // How many thumbnails fit across, so up and down move a whole row.
                GeometryReader { geo in
                    Color.clear
                        .onAppear { columnCount = Self.columns(for: geo.size.width) }
                        .onChange(of: geo.size.width) { _, width in columnCount = Self.columns(for: width) }
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($gridFocused)
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.rightArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-columnCount) }
        .onKeyPress(.downArrow) { move(columnCount) }
        .onKeyPress(.return) { openHighlighted() }
        .onKeyPress(.space) { openHighlighted() }
        .onChange(of: highlighted) { _, id in
            if let id { withAnimation { proxy.scrollTo(id) } }
        }
        .onAppear { gridFocused = true }
        .onChange(of: selected) { _, painting in
            if painting == nil { gridFocused = true }
        }
        }
        .navigationTitle(reviewOnly ? "To Review" : (library.albumTitle ?? "Exhibit"))
        .toolbar {
            if library.toReviewCount > 0 || reviewOnly {
                Toggle(isOn: $reviewOnly) {
                    Label("To Review (\(library.toReviewCount))", systemImage: "questionmark.circle")
                }
                .help("Show only possible matches to check")
            }
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
                Button("Identify paintings", systemImage: "magnifyingglass") {
                    Task { await library.identifyPending(force: true) }
                }
                .disabled(library.isIdentifying)
                #if os(iOS)
                Divider()
                Button("Settings", systemImage: "gearshape") { showSettings = true }
                #endif
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(library.isProcessing)
        }
        .refreshable { await library.processNew() }
        .task { await library.processNew() }
        #if os(iOS)
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Done") { showSettings = false } }
            }
        }
        .fullScreenCover(item: $selected) { painting in
            ExhibitView(startID: painting.id, only: reviewOnly ? shown.map(\.id) : nil) { last in
                highlighted = last; selected = nil
            }
            .environmentObject(library)
        }
        #else
        .overlay {
            if let painting = selected {
                ExhibitView(startID: painting.id, only: reviewOnly ? shown.map(\.id) : nil) { last in
                    highlighted = last; selected = nil
                }
            }
        }
        #endif
    }

    private func openHighlighted() -> KeyPress.Result {
        guard let id = highlighted, let painting = shown.first(where: { $0.id == id }) else {
            return move(0)
        }
        open(painting)
        return .handled
    }

    private static func columns(for width: CGFloat) -> Int {
        max(1, Int((width - 32 + spacing) / (minimumWidth + spacing)))
    }
}

struct Thumbnail: View {
    @EnvironmentObject var library: Library
    let painting: Painting
    @State private var image: CGImage?

    var body: some View {
        Rectangle()
            .fill(Color(white: 0.11))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
                        .padding(12)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .task(id: painting.renderedAt) {
                guard let url = await library.imageURL(for: painting) else { return }
                image = await ImageLoader.load(url, maxPixel: 450)
            }
    }
}

// MARK: Full-screen exhibit

struct ExhibitView: View {
    @EnvironmentObject var library: Library
    @State private var current: String
    @State private var showLabel = true
    @State private var adjusting: Painting?
    @State private var identifying: Painting?
    @State private var lookingUp: Painting?
    @State private var colouring: Painting?
    @FocusState private var focused: Bool
    /// The paintings to move through: those in `only`, in album order, or all of them.
    private let only: [String]?
    /// Closes the exhibit, passing the painting it ended on.
    let onClose: (String) -> Void

    init(startID: String, only: [String]? = nil, close: @escaping (String) -> Void) {
        _current = State(initialValue: startID)
        self.only = only
        self.onClose = close
    }

    private var list: [Painting] {
        guard let only else { return library.paintings }
        let wanted = Set(only)
        return library.paintings.filter { wanted.contains($0.id) }
    }

    private func close() { onClose(current) }

    private var currentPainting: Painting? {
        library.paintings.first { $0.id == current }
    }

    private func toggleLabel() {
        withAnimation(.easeInOut(duration: 0.2)) { showLabel.toggle() }
    }

    var body: some View {
        layout
        // Arrow keys move between paintings, Space shows or hides the label, Escape closes. The exhibit keeps
        // keyboard focus, taking it back after a button is used or the crop editor closes.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.upArrow) { step(-1); return .handled }
        .onKeyPress(.downArrow) { step(1); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(.space) { toggleLabel(); return .handled }
        .onAppear { focused = true }
        .onChange(of: current) { focused = true }
        .onChange(of: showLabel) { focused = true }
        .onChange(of: adjusting) { _, editing in if editing == nil { focused = true } }
        .onChange(of: identifying) { _, open in if open == nil { focused = true } }
        .onChange(of: lookingUp) { _, open in if open == nil { focused = true } }
        .onChange(of: colouring) { _, open in if open == nil { focused = true } }
        .sheet(item: $colouring) { painting in
            ColourView(painting: painting) { colouring = nil }
                .environmentObject(library)
                #if os(macOS)
                .frame(minWidth: 720, minHeight: 640)
                #endif
        }
        .sheet(item: $lookingUp) { painting in
            LookUpView(painting: painting) { lookingUp = nil }
                .environmentObject(library)
                #if os(macOS)
                .frame(minWidth: 700, minHeight: 600)
                #endif
        }
        .sheet(item: $identifying) { painting in
            IdentityView(paintingID: painting.id) { identifying = nil }
                .environmentObject(library)
                #if os(macOS)
                .frame(minWidth: 620, minHeight: 560)
                #endif
        }
        #if os(iOS)
        .statusBarHidden()
        .fullScreenCover(item: $adjusting) { painting in
            CropEditor(painting: painting) { adjusting = nil }
        }
        #else
        .sheet(item: $adjusting) { painting in
            CropEditor(painting: painting) { adjusting = nil }
                .frame(minWidth: 760, minHeight: 620)
        }
        #endif
    }

    #if os(macOS)
    /// On the Mac the buttons, painting and caption are stacked, never overlapping: the painting gets the space
    /// between the bars, and all of the window when Space hides them.
    private var layout: some View {
        VStack(spacing: 0) {
            if showLabel {
                controls
                    .background(.bar)
                Divider()
            }
            pages
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            if showLabel, let painting = currentPainting {
                Divider()
                CaptionBar(painting: painting, keepsFrame: library.keepsFrame(painting))
            }
        }
    }
    #else
    private var layout: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            pages
            if showLabel {
                controls.transition(.opacity)
            }
        }
    }
    #endif

    private var index: Int? { list.firstIndex { $0.id == current } }

    private func step(_ delta: Int) {
        guard let i = index else { return }
        let next = i + delta
        guard list.indices.contains(next) else { return }
        #if os(iOS)
        withAnimation { current = list[next].id }
        #else
        current = list[next].id
        #endif
    }

    #if os(iOS)
    /// Swipe between paintings.
    private var pages: some View {
        TabView(selection: $current) {
            ForEach(list) { painting in
                PaintingPage(painting: painting, showLabel: showLabel, toggleLabel: toggleLabel)
                    .tag(painting.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
    }
    #else
    /// One painting at a time; arrow keys or the side buttons move through the gallery.
    private var pages: some View {
        ZStack {
            if let painting = currentPainting {
                PaintingPage(painting: painting, showLabel: showLabel, toggleLabel: toggleLabel)
                    .id(painting.id)
            }
            if showLabel {
                HStack {
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }
                        .disabled(index == 0)
                    Spacer()
                    Button { step(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(index == nil || index == list.count - 1)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 20)
            }
        }
    }

    #endif

    private var controls: some View {
        HStack(spacing: 8) {
            #if os(macOS)
            Button(action: close) {
                Label("Gallery", systemImage: "chevron.left")
            }
            .keyboardShortcut(.cancelAction)
            .help("Back to the gallery (Esc)")
            Divider().frame(height: 18)
            #endif
            if let painting = currentPainting {
                barButton("Adjust Crop", "crop.rotate") { adjusting = painting }
                barButton("White Balance", "eyedropper.halffull") { colouring = painting }
                if painting.settings.frameFound, painting.manualCrop == nil {
                    let keeps = library.keepsFrame(painting)
                    barButton(keeps ? "Remove Frame" : "Show Frame", keeps ? "crop" : "square.dashed") {
                        library.setKeepFrame(!keeps, for: painting.id)
                    }
                }
                barButton(painting.identification == nil ? "Identify" : "Details", "magnifyingglass") { identifying = painting }
                barButton("Look Up", "info.circle") { lookingUp = painting }
                    .help("Apple's Visual Look Up")
            }
            Spacer()
            #if os(iOS)
            Button(action: close) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            #endif
        }
        #if os(macOS)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        #else
        .padding()
        #endif
    }

    /// A button in the exhibit's bar: standard on the Mac, white over the painting on iPhone and iPad.
    private func barButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                #if os(iOS)
                .font(.subheadline)
                #endif
        }
        .buttonStyle(.bordered)
        .focusable(false)
        #if os(iOS)
        .tint(.white)
        #endif
    }
}

struct PaintingPage: View {
    @EnvironmentObject var library: Library
    let painting: Painting
    let showLabel: Bool
    let toggleLabel: () -> Void

    @State private var image: CGImage?
    @State private var zoomed = false

    var body: some View {
        ZStack(alignment: .bottom) {
            if let image {
                #if os(iOS)
                ZoomableImage(image: image, onTap: toggleLabel, onZoomChange: { zoomed = $0 })
                    .ignoresSafeArea()
                #else
                ZoomableImage(image: image, onTap: toggleLabel, onZoomChange: { zoomed = $0 })
                #endif
            } else {
                ProgressView()
            }

            #if os(iOS)
            if showLabel && !zoomed {
                WallLabel(painting: painting, keepsFrame: library.keepsFrame(painting))
                    .padding(.bottom, 32)
                    .transition(.opacity)
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: painting.renderedAt) {
            guard let url = await library.imageURL(for: painting) else { return }
            image = await ImageLoader.load(url, maxPixel: 3000)
        }
    }
}

/// What a painting's caption says: what it is (once identified), when it was photographed, and what the
/// processing did.
struct CaptionText {
    let painting: Painting
    let keepsFrame: Bool

    private var identity: Identification? { painting.identification }
    var isIdentified: Bool { identity?.isIdentified == true && identity?.title != nil }
    var title: String {
        if isIdentified, let title = identity?.title { return title }
        return identity == nil ? "Not yet identified" : "Unidentified"
    }
    var byline: String? {
        guard isIdentified, let id = identity else { return nil }
        let line = [id.artist, id.year].compactMap { $0 }.joined(separator: ", ")
        return line.isEmpty ? nil : line
    }
    var place: String? {
        if isIdentified, let museum = identity?.museum { return museum }
        return identity?.museums.first.map { "Seen at \($0)" }
    }
    var photographed: String? {
        painting.takenAt.map { "Photographed \($0.formatted(date: .long, time: .omitted))" }
    }
    var summary: String {
        let s = painting.settings
        var parts: [String] = []
        if painting.manualCrop != nil {
            parts.append("cropped by hand")
        } else {
            parts.append(s.cropFound ? "cropped" : "no edges found")
        }
        if s.frameFound && painting.manualCrop == nil {
            parts.append(s.keptFrame ? "frame kept" : "frame removed")
        } else if s.cropFound {
            parts.append("no frame found")
        }
        if s.unevenLightFixed { parts.append("spotlight evened") }
        if s.colour != nil { parts.append("white balance set by hand") }
        if painting.photosRecipe != nil { parts.append("saved to Photos") }
        if keepsFrame != s.keptFrame && painting.manualCrop == nil { parts.append("updating…") }
        switch identity?.status {
        case .matched?: parts.append("identified")
        case .possible?: parts.append("possible match, to check")
        case .confirmed?: parts.append("identity confirmed")
        default: break
        }
        return parts.joined(separator: " · ")
    }
}

/// A museum-style wall label over the painting, on iPhone and iPad (tap the painting to hide it).
struct WallLabel: View {
    let painting: Painting
    let keepsFrame: Bool

    var body: some View {
        let text = CaptionText(painting: painting, keepsFrame: keepsFrame)
        VStack(alignment: .leading, spacing: 4) {
            Text(text.title)
                .font(.system(.headline, design: .serif))
                .italic(text.isIdentified)
            if let byline = text.byline { Text(byline).font(.system(.subheadline, design: .serif)) }
            if let place = text.place { Text(place).font(.system(.footnote, design: .serif)) }
            if let photographed = text.photographed { Text(photographed).font(.system(.subheadline, design: .serif)) }
            Text(text.summary)
                .font(.caption)
                .foregroundStyle(.black.opacity(0.55))
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 3))
        .shadow(radius: 6)
    }
}

/// The caption on the Mac: a bar below the painting in the system's style, never covering it.
struct CaptionBar: View {
    let painting: Painting
    let keepsFrame: Bool

    var body: some View {
        let text = CaptionText(painting: painting, keepsFrame: keepsFrame)
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(text.title)
                        .font(.headline)
                        .italic(text.isIdentified)
                    if let byline = text.byline {
                        Text(byline).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if let place = text.place {
                    Text(place).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                if let photographed = text.photographed {
                    Text(photographed).font(.caption).foregroundStyle(.secondary)
                }
                Text(text.summary).font(.caption).foregroundStyle(.tertiary)
            }
            .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

// MARK: Zooming

#if os(iOS)
/// Pinch and double-tap zoom backed by UIScrollView. When the painting isn't zoomed, or a pan
/// reaches its edge, the swipe passes to the exhibit so you move to the next painting.
struct ZoomableImage: UIViewRepresentable {
    let image: CGImage
    var onTap: () -> Void
    var onZoomChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> ZoomingScrollView {
        let view = ZoomingScrollView()
        view.delegate = context.coordinator
        view.cgImage = image

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
        if view.cgImage !== image { view.cgImage = image }
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

    var cgImage: CGImage? {
        didSet {
            imageView.image = cgImage.map { UIImage(cgImage: $0) }
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
#else
/// Trackpad pinch, scroll and double-click zoom backed by NSScrollView. A single click shows or hides the label.
struct ZoomableImage: NSViewRepresentable {
    let image: CGImage
    var onTap: () -> Void
    var onZoomChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> FittingScrollView {
        let view = FittingScrollView()
        view.cgImage = image
        view.onMagnify = { [weak coordinator = context.coordinator] in coordinator?.magnificationChanged($0) }

        let doubleClick = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleClicked(_:)))
        doubleClick.numberOfClicksRequired = 2
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.clicked))
        click.delegate = context.coordinator
        context.coordinator.doubleClick = doubleClick
        view.addGestureRecognizer(doubleClick)
        view.addGestureRecognizer(click)
        return view
    }

    func updateNSView(_ view: FittingScrollView, context: Context) {
        context.coordinator.parent = self
        if view.cgImage !== image { view.cgImage = image }
    }

    final class Coordinator: NSObject, NSGestureRecognizerDelegate {
        var parent: ZoomableImage
        weak var doubleClick: NSClickGestureRecognizer?
        private var wasZoomed = false

        init(parent: ZoomableImage) { self.parent = parent }

        func magnificationChanged(_ magnification: CGFloat) {
            let zoomed = magnification > 1.01
            if zoomed != wasZoomed {
                wasZoomed = zoomed
                let report = parent.onZoomChange
                DispatchQueue.main.async { report(zoomed) }
            }
        }

        @objc func clicked() { parent.onTap() }

        @objc func doubleClicked(_ gesture: NSClickGestureRecognizer) {
            guard let view = gesture.view as? FittingScrollView, let doc = view.documentView else { return }
            if view.magnification > 1.01 {
                view.animator().magnification = 1
                magnificationChanged(1)
            } else {
                let point = gesture.location(in: doc)
                view.animator().setMagnification(2.5, centeredAt: point)
                magnificationChanged(2.5)
            }
        }

        func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                               shouldRequireFailureOf other: NSGestureRecognizer) -> Bool {
            other === doubleClick
        }
    }
}

final class FittingScrollView: NSScrollView {
    private let imageView = NSImageView()
    private let margin: CGFloat = 24
    private var laidOutSize: CGSize = .zero
    var onMagnify: ((CGFloat) -> Void)?

    var cgImage: CGImage? {
        didSet {
            imageView.image = cgImage.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            laidOutSize = .zero
            needsLayout = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        contentView = CenteringClipView()
        drawsBackground = false
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        allowsMagnification = true
        minMagnification = 1
        maxMagnification = 6
        imageView.imageScaling = .scaleProportionallyUpOrDown
        documentView = imageView
        NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: self, queue: .main) {
            [weak self] _ in
            guard let self else { return }
            self.onMagnify?(self.magnification)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        guard let image = cgImage, bounds.width > 0, bounds.height > 0 else { return }
        if bounds.size != laidOutSize {
            // First layout, a new image or a window resize: fit the painting with a margin.
            laidOutSize = bounds.size
            magnification = 1
            onMagnify?(1)
            let available = CGSize(width: max(1, bounds.width - 2 * (margin + 32)), height: max(1, bounds.height - 2 * margin))
            let w = CGFloat(image.width), h = CGFloat(image.height)
            let fit = min(available.width / w, available.height / h)
            imageView.frame = CGRect(x: 0, y: 0, width: w * fit, height: h * fit)
        }
    }
}

/// Keeps the document centred while it is smaller than the view.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}
#endif

// MARK: Image loading

enum ImageLoader {
    /// Loads a downscaled image from disk off the main thread.
    static func load(_ url: URL, maxPixel: Int) async -> CGImage? {
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
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }
}
