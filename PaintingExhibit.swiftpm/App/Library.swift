import SwiftUI
import Photos

/// One painting from the album. Photos keeps the only copy of the picture; this is the
/// edit recipe plus a little information from the photo.
struct Painting: Codable, Identifiable, Hashable {
    var id: String              // Photos asset identifier
    var fileName: String        // rendered image in the app's cache (can be deleted and redrawn at any time)
    var takenAt: Date?
    var latitude: Double?
    var longitude: Double?
    var settings: ProcessingSettings
    var keepFrame: Bool?        // the user's choice for this painting; nil follows the default
    var renderedAt: Date
    var version: Int
}

/// Keeps the edit recipes, watches the paintings album, and draws paintings from Photos.
///
/// Nothing is ever written to the Photos library. Recipes live in Application Support;
/// rendered images live in Caches, where iOS may clear them, and are redrawn from Photos on demand.
@MainActor
final class Library: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    /// Bump this when the analysis changes, so older recipes are worked out again.
    static let processingVersion = 2

    @Published var paintings: [Painting] = []
    @Published var authorized = false
    @Published var accessChecked = false
    @Published var isProcessing = false
    @Published var progressDone = 0
    @Published var progressTotal = 0
    @Published var lastError: String?
    @Published var albumID: String? {
        didSet {
            UserDefaults.standard.set(albumID, forKey: "albumID")
            albumFetch = nil
        }
    }
    /// Whether paintings show their frame unless chosen otherwise for that painting.
    @Published var keepFramesByDefault: Bool {
        didSet {
            UserDefaults.standard.set(keepFramesByDefault, forKey: "keepFramesByDefault")
            if oldValue != keepFramesByDefault { Task { await processNew() } }
        }
    }

    let cacheFolder: URL
    private let indexURL: URL
    private var albumFetch: PHFetchResult<PHAsset>?
    private var stale: Set<String> = []          // photos edited in Photos since they were analysed
    private var forceAll = false
    private var anotherPass = false
    private var observing = false
    private var pendingCheck: Task<Void, Never>?
    private var renders: [String: Task<URL?, Never>] = [:]

    override init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaintingExhibit", isDirectory: true)
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Paintings", isDirectory: true)
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        try? fm.createDirectory(at: caches, withIntermediateDirectories: true)
        indexURL = support.appendingPathComponent("index.json")
        cacheFolder = caches
        _albumID = Published(initialValue: UserDefaults.standard.string(forKey: "albumID"))
        _keepFramesByDefault = Published(initialValue: UserDefaults.standard.bool(forKey: "keepFramesByDefault"))
        super.init()

        // Version 0.1 kept full copies in Documents; the cache replaces them.
        let legacy = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Paintings")
        try? fm.removeItem(at: legacy)
        load()
    }

    // MARK: Access and albums

    func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorized = (status == .authorized || status == .limited)
        accessChecked = true
        if authorized && !observing {
            PHPhotoLibrary.shared().register(self)
            observing = true
        }
    }

    func albums() -> [PHAssetCollection] {
        var result: [PHAssetCollection] = []
        let fetched = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        fetched.enumerateObjects { collection, _, _ in result.append(collection) }
        return result.sorted { ($0.localizedTitle ?? "") < ($1.localizedTitle ?? "") }
    }

    var albumTitle: String? {
        guard let albumID else { return nil }
        return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil)
            .firstObject?.localizedTitle
    }

    // MARK: Watching the album

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.libraryChanged(changeInstance) }
    }

    private func libraryChanged(_ change: PHChange) {
        guard let fetch = albumFetch, let details = change.changeDetails(for: fetch) else { return }
        albumFetch = details.fetchResultAfterChanges
        if details.hasIncrementalChanges {
            // A photo edited in Photos (cropped, rotated, adjusted) gets analysed again.
            for asset in details.changedObjects where change.changeDetails(for: asset)?.assetContentChanged == true {
                stale.insert(asset.localIdentifier)
            }
        }
        // Wait a moment so a batch of additions is handled in one go.
        pendingCheck?.cancel()
        pendingCheck = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await processNew()
        }
    }

    // MARK: Frame choice

    func keepsFrame(_ painting: Painting) -> Bool {
        painting.keepFrame ?? keepFramesByDefault
    }

    /// Shows or hides the frame for one painting. Only the drawing changes; nothing is detected again.
    func setKeepFrame(_ keep: Bool, for id: String) {
        guard let i = paintings.firstIndex(where: { $0.id == id }) else { return }
        paintings[i].keepFrame = keep
        save()
        Task { await processNew() }
    }

    // MARK: Processing

    private enum Job { case analyze, redraw }

    /// Brings every painting in the album up to date: analyses new or edited photos (or all of them when
    /// `reprocessAll` is true), redraws paintings whose frame choice changed, and drops paintings
    /// removed from the album. Calls made while a run is going are folded into another pass.
    func processNew(reprocessAll: Bool = false) async {
        if reprocessAll { forceAll = true }
        if isProcessing {
            anotherPass = true
            return
        }
        guard authorized, albumID != nil else { return }
        isProcessing = true
        lastError = nil
        repeat {
            anotherPass = false
            let all = forceAll
            forceAll = false
            await runPass(reprocessAll: all)
        } while anotherPass
        isProcessing = false
    }

    private func runPass(reprocessAll: Bool) async {
        guard let albumID,
              let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject
        else { return }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(in: album, options: options)
        albumFetch = assets

        var inAlbum: [String] = []
        var todo: [(PHAsset, Job)] = []
        let existing = Dictionary(paintings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        assets.enumerateObjects { asset, _, _ in
            let id = asset.localIdentifier
            inAlbum.append(id)
            guard let p = existing[id], !reprocessAll,
                  p.version == Self.processingVersion, !self.stale.contains(id) else {
                todo.append((asset, .analyze))
                return
            }
            if p.settings.keptFrame != self.keepsFrame(p) {
                todo.append((asset, .redraw))
            }
        }

        // Remove paintings no longer in the album (and their cached image), and keep album order.
        let order = Dictionary(inAlbum.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        for gone in paintings where order[gone.id] == nil {
            try? FileManager.default.removeItem(at: cacheFolder.appendingPathComponent(gone.fileName))
        }
        paintings = paintings.filter { order[$0.id] != nil }
        sortByAlbum(order)
        save()

        progressDone = 0
        progressTotal = todo.count
        for (asset, job) in todo {
            let id = asset.localIdentifier
            do {
                let data = try await Self.imageData(for: asset)
                let previous = paintings.first { $0.id == id }
                let keep = previous?.keepFrame ?? keepFramesByDefault
                let fileName = previous?.fileName ?? Self.fileName(for: id)
                let url = cacheFolder.appendingPathComponent(fileName)

                let settings: ProcessingSettings
                if job == .redraw, var recipe = previous?.settings {
                    recipe.keptFrame = keep
                    recipe.blackPoint = nil     // the frame changes the brightness range
                    recipe.exposure = nil
                    let fixed = recipe
                    settings = try await Task.detached(priority: .userInitiated) {
                        try PaintingProcessor.render(imageData: data, settings: fixed, writeTo: url)
                    }.value
                } else {
                    settings = try await Task.detached(priority: .userInitiated) {
                        try PaintingProcessor.analyzeAndRender(imageData: data, keepFrame: keep, writeTo: url)
                    }.value
                }

                let painting = Painting(
                    id: id,
                    fileName: fileName,
                    takenAt: asset.creationDate,
                    latitude: asset.location?.coordinate.latitude,
                    longitude: asset.location?.coordinate.longitude,
                    settings: settings,
                    keepFrame: previous?.keepFrame,
                    renderedAt: Date(),
                    version: Self.processingVersion
                )
                if let i = paintings.firstIndex(where: { $0.id == id }) {
                    paintings[i] = painting
                } else {
                    paintings.append(painting)
                }
                stale.remove(id)
                sortByAlbum(order)
                save()
            } catch {
                lastError = "A photo couldn't be processed: \(error.localizedDescription)"
            }
            progressDone += 1
        }
    }

    // MARK: Drawing on demand

    /// The rendered image for a painting. If iOS has cleared it from the cache, it is redrawn
    /// from the original in Photos with the saved recipe.
    func imageURL(for painting: Painting) async -> URL? {
        let url = cacheFolder.appendingPathComponent(painting.fileName)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        if let running = renders[painting.id] { return await running.value }

        let settings = painting.settings
        let task = Task<URL?, Never> {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [painting.id], options: nil).firstObject,
                  let data = try? await Library.imageData(for: asset)
            else { return nil }
            let drawn = try? await Task.detached(priority: .userInitiated) {
                try PaintingProcessor.render(imageData: data, settings: settings, writeTo: url)
            }.value
            return drawn == nil ? nil : url
        }
        renders[painting.id] = task
        let result = await task.value
        renders[painting.id] = nil
        return result
    }

    // MARK: Helpers

    private func sortByAlbum(_ order: [String: Int]) {
        paintings.sort { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
    }

    private static func fileName(for id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_") + ".jpg"
    }

    private static func imageData(for asset: PHAsset) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true   // download from iCloud if needed
            options.deliveryMode = .highQualityFormat
            options.version = .current
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    let error = (info?[PHImageErrorKey] as? Error) ?? ProcessingError.noImage
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: Saving

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let saved = try? JSONDecoder().decode([Painting].self, from: data) else { return }
        paintings = saved
    }

    private func save() {
        if let data = try? JSONEncoder().encode(paintings) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}
