import SwiftUI
import Photos

/// One painting from the album. Photos keeps the picture; this is the edit recipe
/// plus a little information from the photo.
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
    /// The recipe last saved to Photos as an edit, or nil when the photo carries no edit from this app.
    var photosRecipe: ProcessingSettings?
    /// The photo was edited elsewhere after this app saved an edit to it, so the app leaves it alone.
    var photosLeftAlone: Bool?
    /// Corners set by hand, used instead of the automatic crop (kept when paintings are processed again).
    var manualCrop: ManualCrop?
}

/// One crop fixed by hand: what the app chose and what the person chose instead. Kept as a record to
/// measure and improve the automatic cropping against.
struct CropFix: Codable {
    var date: Date
    var photo: String
    var processingVersion: Int
    /// The crop being replaced, in the photo with lens distortion `lensK` undone; nil when nothing was cropped.
    var automatic: [NormPoint]?
    /// Whether the crop being replaced had itself been set by hand.
    var replacedManual: Bool
    /// The corners set by hand; nil when the person went back to the automatic crop.
    var manual: [NormPoint]?
    var lensK: Double?
    var frameRemoved: Bool
}

/// Keeps the edit recipes, watches the paintings album, and draws paintings from Photos.
///
/// Recipes live in Application Support; rendered images live in Caches, where the system may clear
/// them, and are redrawn from Photos on demand. Photos is changed only when "Save edits to Photos"
/// is on, and then only as a revertible edit: Photos keeps the original.
@MainActor
final class Library: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    /// Bump this when the analysis changes, so older recipes are worked out again.
    static let processingVersion = 12
    /// Identifies this app's edits in Photos, so it can recognise and redo them.
    nonisolated static let adjustmentFormat = "com.pedroserano.PaintingExhibit.recipe"
    /// Long side of the photo when drawing an edit for Photos (the exhibit cache uses less).
    nonisolated static let photosEditMaxDimension: CGFloat = 5000

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
    /// Whether the crop and corrections are also saved to Photos as an edit (off unless chosen).
    @Published var saveEditsToPhotos: Bool {
        didSet {
            UserDefaults.standard.set(saveEditsToPhotos, forKey: "saveEditsToPhotos")
            if saveEditsToPhotos && !oldValue { Task { await processNew() } }
        }
    }

    var editedInPhotosCount: Int { paintings.filter { $0.photosRecipe != nil }.count }

    let cacheFolder: URL
    private let indexURL: URL
    private var albumFetch: PHFetchResult<PHAsset>?
    private var stale: Set<String> = []          // photos edited elsewhere since they were analysed
    /// Every crop fixed by hand, one JSON record per line (in the app's Application Support folder), for
    /// measuring and improving the automatic cropping.
    let fixesURL: URL
    private var ownWrites: [String: Date] = [:]  // photos this app just changed, so their change notice is ignored
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
            .appendingPathComponent("PaintingExhibit", isDirectory: true)
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        try? fm.createDirectory(at: caches, withIntermediateDirectories: true)
        indexURL = support.appendingPathComponent("index.json")
        fixesURL = support.appendingPathComponent("crop-fixes.jsonl")
        cacheFolder = caches
        let defaults = UserDefaults.standard
        _albumID = Published(initialValue: defaults.string(forKey: "albumID"))
        _keepFramesByDefault = Published(initialValue: defaults.bool(forKey: "keepFramesByDefault"))
        _saveEditsToPhotos = Published(initialValue: defaults.bool(forKey: "saveEditsToPhotos"))
        super.init()

        #if os(iOS)
        // Version 0.1 kept full copies in the app's own Documents folder and cache; the new cache replaces them.
        // (iOS only: on the Mac these folders would be the user's own.)
        for old in [fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Paintings"),
                    fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Paintings")] {
            try? fm.removeItem(at: old)
        }
        #endif
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
            for asset in details.changedObjects where change.changeDetails(for: asset)?.assetContentChanged == true {
                let id = asset.localIdentifier
                if let at = ownWrites[id], Date().timeIntervalSince(at) < 120 { continue }
                // Edited elsewhere (cropped, rotated, reverted in Photos): analyse it again.
                stale.insert(id)
                // If it carried this app's edit, someone else has taken over: don't save over their change.
                if let i = paintings.firstIndex(where: { $0.id == id }), paintings[i].photosRecipe != nil {
                    paintings[i].photosRecipe = nil
                    paintings[i].photosLeftAlone = true
                    save()
                }
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

    // MARK: Fixing a crop by hand

    /// The photo as the crop's corners refer to it, for setting them by hand.
    func editorPhoto(for painting: Painting) async -> CGImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [painting.id], options: nil).firstObject,
              let data = try? await Self.source(for: asset).data else { return nil }
        let lensK = painting.manualCrop?.lensK ?? painting.settings.lensK
        return try? await Task.detached(priority: .userInitiated) {
            try PaintingProcessor.preparedPhoto(imageData: data, lensK: lensK)
        }.value
    }

    /// The crop now shown, as corners in that photo.
    func currentCrop(of painting: Painting) -> [NormPoint] {
        painting.manualCrop?.quad ?? PaintingProcessor.cropQuad(of: painting.settings)
    }

    /// Uses corners set by hand for one painting (or, with nil, goes back to the automatic crop), redraws it,
    /// and records the fix.
    func setManualCrop(_ quad: [NormPoint]?, for id: String) {
        guard let i = paintings.firstIndex(where: { $0.id == id }) else { return }
        let painting = paintings[i]
        let lensK = painting.manualCrop?.lensK ?? painting.settings.lensK
        let replaced = painting.manualCrop?.quad ?? (painting.settings.paintingQuad == nil ? nil : currentCrop(of: painting))
        let fix = CropFix(date: Date(), photo: id, processingVersion: Self.processingVersion,
                          automatic: replaced, replacedManual: painting.manualCrop != nil, manual: quad,
                          lensK: lensK, frameRemoved: painting.settings.frameRemoved)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let line = try? encoder.encode(fix), var text = String(data: line, encoding: .utf8) {
            text += "\n"
            if let handle = try? FileHandle(forWritingTo: fixesURL) {
                handle.seekToEndOfFile()
                handle.write(Data(text.utf8))
                try? handle.close()
            } else {
                try? Data(text.utf8).write(to: fixesURL)
            }
        }
        paintings[i].manualCrop = quad.map { ManualCrop(quad: $0, lensK: lensK) }
        stale.insert(id)
        save()
        Task { await processNew() }
    }

    // MARK: Processing

    private enum Job { case analyze, redraw }

    /// Brings every painting in the album up to date: analyses new or edited photos (or all of them when
    /// `reprocessAll` is true), redraws paintings whose frame choice changed, drops paintings removed
    /// from the album, and saves edits to Photos when that is on. Calls made while a run is going are
    /// folded into another pass.
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
            await writeEditsToPhotos()
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
            if p.manualCrop == nil, p.settings.keptFrame != self.keepsFrame(p) {
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
                let data = try await Self.source(for: asset).data
                let previous = paintings.first { $0.id == id }
                let keep = previous?.keepFrame ?? keepFramesByDefault
                let fileName = previous?.fileName ?? Self.fileName(for: id)
                let manual = previous?.manualCrop
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
                        try PaintingProcessor.analyzeAndRender(imageData: data, keepFrame: keep, manual: manual, writeTo: url)
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
                    version: Self.processingVersion,
                    photosRecipe: previous?.photosRecipe,
                    photosLeftAlone: previous?.photosLeftAlone,
                    manualCrop: manual
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

    // MARK: Saving edits to Photos

    /// Saves each painting's crop and corrections to Photos as an edit, when that setting is on.
    /// Photos keeps the original, so the edit can be reverted there or with `removeEditsFromPhotos`.
    /// All edits in a pass are saved in one change, so the system asks for permission once.
    private func writeEditsToPhotos() async {
        guard saveEditsToPhotos else { return }
        let todo = paintings.filter { $0.photosLeftAlone != true && $0.photosRecipe != $0.settings }
        guard !todo.isEmpty else { return }

        var edits: [(asset: PHAsset, output: PHContentEditingOutput, recipe: ProcessingSettings)] = []
        progressDone = 0
        progressTotal = todo.count
        for painting in todo {
            defer { progressDone += 1 }
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [painting.id], options: nil).firstObject else { continue }
            do {
                let source = try await Self.source(for: asset)
                if let format = source.existingFormat, format != Self.adjustmentFormat, painting.photosRecipe != nil {
                    // Edited elsewhere after this app saved its edit: leave it alone.
                    markLeftAlone(painting.id)
                    continue
                }
                let output = PHContentEditingOutput(contentEditingInput: source.input)
                output.adjustmentData = PHAdjustmentData(
                    formatIdentifier: Self.adjustmentFormat,
                    formatVersion: "1",
                    data: try JSONEncoder().encode(painting.settings)
                )
                let target = output.renderedContentURL
                let recipe = painting.settings
                let data = source.data
                _ = try await Task.detached(priority: .utility) {
                    try PaintingProcessor.render(imageData: data, settings: recipe,
                                                 maxDimension: Library.photosEditMaxDimension, writeTo: target)
                }.value
                edits.append((asset, output, recipe))
            } catch {
                lastError = "An edit couldn't be prepared for Photos: \(error.localizedDescription)"
            }
        }
        guard !edits.isEmpty else { return }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                for edit in edits {
                    PHAssetChangeRequest(for: edit.asset).contentEditingOutput = edit.output
                }
            }
            let now = Date()
            for edit in edits {
                let id = edit.asset.localIdentifier
                ownWrites[id] = now
                if let i = paintings.firstIndex(where: { $0.id == id }) {
                    paintings[i].photosRecipe = edit.recipe
                }
            }
            save()
        } catch {
            // Most often "Don't Allow" on the permission prompt.
            lastError = "Photos didn't save the edits: \(error.localizedDescription)"
        }
    }

    /// Reverts every photo this app saved an edit to, and turns saving edits off.
    /// Revert to Original also removes edits made in Photos before this app's edit.
    func removeEditsFromPhotos() async {
        saveEditsToPhotos = false
        let ids = paintings.filter { $0.photosRecipe != nil }.map(\.id)
        guard !ids.isEmpty else { return }
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in assets.append(asset) }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for asset in assets {
                    PHAssetChangeRequest(for: asset).revertAssetContentToOriginal()
                }
            }
            let now = Date()
            for asset in assets { ownWrites[asset.localIdentifier] = now }
            for i in paintings.indices where ids.contains(paintings[i].id) {
                paintings[i].photosRecipe = nil
            }
            save()
        } catch {
            lastError = "Photos didn't remove the edits: \(error.localizedDescription)"
        }
    }

    private func markLeftAlone(_ id: String) {
        guard let i = paintings.firstIndex(where: { $0.id == id }) else { return }
        paintings[i].photosRecipe = nil
        paintings[i].photosLeftAlone = true
        save()
    }

    // MARK: Drawing on demand

    /// The rendered image for a painting. If the system has cleared it from the cache, it is redrawn
    /// from Photos with the saved recipe.
    func imageURL(for painting: Painting) async -> URL? {
        let url = cacheFolder.appendingPathComponent(painting.fileName)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        if let running = renders[painting.id] { return await running.value }

        let settings = painting.settings
        let task = Task<URL?, Never> {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [painting.id], options: nil).firstObject,
                  let data = try? await Library.source(for: asset).data
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

    // MARK: Reading photos

    /// The image a recipe applies to. For a photo carrying this app's edit, that is the image under the
    /// edit (not the app's own output); otherwise it is the photo as it looks in Photos.
    private struct Source {
        var data: Data
        var input: PHContentEditingInput
        /// The format of the edit the photo carries now, if any.
        var existingFormat: String?
    }

    private final class FormatBox: @unchecked Sendable { var format: String? }

    private static func source(for asset: PHAsset) async throws -> Source {
        let seen = FormatBox()
        let input: PHContentEditingInput = try await withCheckedThrowingContinuation { continuation in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = true   // download from iCloud if needed
            options.canHandleAdjustmentData = { adjustment in
                seen.format = adjustment.formatIdentifier
                return adjustment.formatIdentifier == Library.adjustmentFormat
            }
            asset.requestContentEditingInput(with: options) { input, info in
                if let input {
                    continuation.resume(returning: input)
                } else {
                    let error = (info[PHContentEditingInputErrorKey] as? Error) ?? ProcessingError.noImage
                    continuation.resume(throwing: error)
                }
            }
        }
        guard let url = input.fullSizeImageURL else { throw ProcessingError.noImage }
        let data = try await Task.detached { try Data(contentsOf: url) }.value
        return Source(data: data, input: input, existingFormat: seen.format)
    }

    // MARK: Helpers

    private func sortByAlbum(_ order: [String: Int]) {
        paintings.sort { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
    }

    private static func fileName(for id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_") + ".jpg"
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
