import SwiftUI
import Photos

/// One painting from the album, after processing.
struct Painting: Codable, Identifiable, Hashable {
    var id: String              // Photos asset identifier
    var fileName: String        // processed JPEG inside the app's Documents/Paintings folder
    var takenAt: Date?
    var latitude: Double?
    var longitude: Double?
    var cropFound: Bool
    var frameRemoved: Bool
    var lightCorrection: Double // 0...1, how much of the wall-based colour correction was applied
    var unevenLightFixed: Bool
    var processedAt: Date
    var version: Int
}

/// Keeps the list of processed paintings and talks to the Photos library.
@MainActor
final class Library: ObservableObject {
    /// Bump this when the processing method changes, so older results are redone.
    static let processingVersion = 1

    @Published var paintings: [Painting] = []
    @Published var authorized = false
    @Published var accessChecked = false
    @Published var isProcessing = false
    @Published var progressDone = 0
    @Published var progressTotal = 0
    @Published var lastError: String?
    @Published var albumID: String? {
        didSet { UserDefaults.standard.set(albumID, forKey: "albumID") }
    }

    let folder: URL
    private var indexURL: URL { folder.appendingPathComponent("index.json") }

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = docs.appendingPathComponent("Paintings", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        albumID = UserDefaults.standard.string(forKey: "albumID")
        load()
    }

    // MARK: Access and albums

    func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorized = (status == .authorized || status == .limited)
        accessChecked = true
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

    func url(for painting: Painting) -> URL {
        folder.appendingPathComponent(painting.fileName)
    }

    // MARK: Processing

    /// Processes photos in the album that are new (or all of them when `reprocessAll` is true),
    /// and drops paintings that were removed from the album.
    func processNew(reprocessAll: Bool = false) async {
        guard !isProcessing, authorized, let albumID,
              let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject
        else { return }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(in: album, options: options)

        var inAlbum: [String] = []
        var todo: [PHAsset] = []
        let existing = Dictionary(paintings.map { ($0.id, $0.version) }, uniquingKeysWith: { a, _ in a })
        assets.enumerateObjects { asset, _, _ in
            inAlbum.append(asset.localIdentifier)
            if reprocessAll || existing[asset.localIdentifier] != Self.processingVersion {
                todo.append(asset)
            }
        }

        // Remove paintings no longer in the album, and keep album order.
        let order = Dictionary(inAlbum.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        paintings = paintings.filter { order[$0.id] != nil }
        sortByAlbum(order)
        save()

        guard !todo.isEmpty else { return }
        isProcessing = true
        progressDone = 0
        progressTotal = todo.count
        lastError = nil

        for asset in todo {
            do {
                let data = try await Self.imageData(for: asset)
                let fileName = asset.localIdentifier.replacingOccurrences(of: "/", with: "_") + ".jpg"
                let url = folder.appendingPathComponent(fileName)
                let result = try await Task.detached(priority: .userInitiated) {
                    try PaintingProcessor.process(imageData: data, writeTo: url)
                }.value

                let painting = Painting(
                    id: asset.localIdentifier,
                    fileName: fileName,
                    takenAt: asset.creationDate,
                    latitude: asset.location?.coordinate.latitude,
                    longitude: asset.location?.coordinate.longitude,
                    cropFound: result.cropFound,
                    frameRemoved: result.frameRemoved,
                    lightCorrection: result.lightCorrection,
                    unevenLightFixed: result.unevenLightFixed,
                    processedAt: Date(),
                    version: Self.processingVersion
                )
                if let i = paintings.firstIndex(where: { $0.id == painting.id }) {
                    paintings[i] = painting
                } else {
                    paintings.append(painting)
                }
                sortByAlbum(order)
                save()
            } catch {
                lastError = "A photo couldn't be processed: \(error.localizedDescription)"
            }
            progressDone += 1
        }
        isProcessing = false
    }

    private func sortByAlbum(_ order: [String: Int]) {
        paintings.sort { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
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
