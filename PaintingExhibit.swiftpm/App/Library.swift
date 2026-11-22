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
    /// Text read from the photo (a caption label in the frame, a sign), kept for identification.
    var photoText: [String]?
    /// Which painting this is, once searched for (kept when paintings are processed again).
    var identification: Identification?
    /// When the crop, white balance or frame choice was last changed by hand, and the identification last
    /// changed, for sharing between devices (the newer wins).
    var editedAt: Date?
    var identifiedAt: Date?
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
    /// The photo's iCloud Photos ID, the same on every device (the Photos ID differs).
    var cloud: String?
}

/// Keeps the edit recipes, watches the paintings album, and draws paintings from Photos.
///
/// Recipes live in Application Support; rendered images live in Caches, where the system may clear
/// them, and are redrawn from Photos on demand. Photos is changed only when "Save edits to Photos"
/// is on, and then only as a revertible edit: Photos keeps the original.
@MainActor
final class Library: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    /// Bump this when the analysis changes, so older recipes are worked out again.
    static let processingVersion = 15
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

    // MARK: Identification settings

    /// Google's web detection is free for the first 1,000 lookups a month; the app stops below that.
    static let monthlyLookupLimit = 900
    /// Whether a Google Cloud Vision API key is saved (the key itself stays in the Keychain).
    @Published private(set) var hasGoogleKey = APIKeyStore.load() != nil
    /// Whether new paintings are looked up on their own, once processed.
    @Published var identifyAutomatically: Bool {
        didSet {
            UserDefaults.standard.set(identifyAutomatically, forKey: "identifyAutomatically")
            if identifyAutomatically && !oldValue { Task { await identifyPending() } }
        }
    }
    @Published private(set) var isIdentifying = false
    @Published private(set) var identifyDone = 0
    @Published private(set) var identifyTotal = 0
    /// Paintings being looked up right now, one at a time.
    @Published private(set) var searching: Set<String> = []
    /// The museum whose paintings are being fetched for searching, with progress.
    @Published private(set) var indexingMuseum: String?
    @Published private(set) var indexDone = 0
    @Published private(set) var indexTotal = 0
    private var museumIndexes: [String: MuseumIndex] = [:]
    /// Museums whose paintings were fetched (or tried) since the app started: each is tried once a session.
    private var museumsFetched: Set<String> = []
    private var museumsNear: [String: [Museum]] = [:]

    private static var monthKey: String {
        let c = Calendar.current.dateComponents([.year, .month], from: Date())
        return "googleLookups-\(c.year ?? 0)-\(c.month ?? 0)"
    }
    var lookupsThisMonth: Int { UserDefaults.standard.integer(forKey: Self.monthKey) }
    var lookupsLeft: Int { max(0, Self.monthlyLookupLimit - lookupsThisMonth) }
    var toReviewCount: Int { paintings.filter { $0.identification?.status == .possible }.count }

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
        _identifyAutomatically = Published(initialValue: defaults.object(forKey: "identifyAutomatically") as? Bool ?? true)
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
        edited(id)
        Task { await processNew() }
    }

    // MARK: Sharing between devices

    @Published private(set) var sharedFolderName: String? = SharedFolder.displayName
    private var cloudIDs: [String: String] = [:]     // Photos ID on this device → iCloud Photos ID
    private var syncing = false
    private var syncAgain = false

    /// Chooses the folder to share edits, identifications and museum data through (nil: stop sharing), and
    /// brings what's already there in.
    func chooseSharedFolder(_ url: URL?) {
        SharedFolder.choose(url)
        sharedFolderName = SharedFolder.displayName
        if let url {
            // Carry over the crop fixes and museum data fetched so far, so nothing is fetched twice.
            let local = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PaintingExhibit", isDirectory: true)
            let museums = local.appendingPathComponent("Museums")
            let sharedMuseums = url.appendingPathComponent("Museums")
            try? FileManager.default.createDirectory(at: sharedMuseums, withIntermediateDirectories: true)
            for file in (try? FileManager.default.contentsOfDirectory(atPath: museums.path)) ?? [] {
                let target = sharedMuseums.appendingPathComponent(file)
                if !FileManager.default.fileExists(atPath: target.path) {
                    try? FileManager.default.copyItem(at: museums.appendingPathComponent(file), to: target)
                }
            }
            if let fixes = try? String(contentsOf: fixesURL, encoding: .utf8), !fixes.isEmpty,
               SharedFolder.read("crop-fixes.jsonl") == nil {
                SharedFolder.write(Data(fixes.utf8), to: "crop-fixes.jsonl")
            }
        }
        Task { await syncShared() }
    }

    /// The iCloud Photos IDs of this device's photos (the same picture has a different Photos ID on each device).
    private func cloudID(_ localIDs: [String]) -> [String: String] {
        let missing = localIDs.filter { cloudIDs[$0] == nil }
        if !missing.isEmpty {
            for (local, result) in PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: missing) {
                if case .success(let cloud) = result { cloudIDs[local] = cloud.stringValue }
            }
        }
        return cloudIDs
    }

    /// Notes that a painting's edits (crop, colour, frame) changed here, and shares them.
    private func edited(_ id: String) {
        guard let i = paintings.firstIndex(where: { $0.id == id }) else { return }
        paintings[i].editedAt = Date()
        save()
        Task { await syncShared() }
    }

    /// Notes that a painting's identification changed here, and shares it.
    private func identified(_ id: String) {
        guard let i = paintings.firstIndex(where: { $0.id == id }) else { return }
        paintings[i].identifiedAt = Date()
        save()
        Task { await syncShared() }
    }

    /// Brings in what other devices shared and shares what changed here: for each painting the newer edits win,
    /// and an identification confirmed by hand beats an automatic one. Edits from elsewhere redraw the painting.
    func syncShared() async {
        guard SharedFolder.url != nil else { return }
        if syncing { syncAgain = true; return }
        syncing = true
        defer { syncing = false }
        repeat {
            syncAgain = false
            var shared: [String: SharedEntry] = [:]
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let data = await Task.detached(operation: { SharedFolder.read("edits.json") }).value {
                shared = (try? decoder.decode([String: SharedEntry].self, from: data)) ?? [:]
            }
            let ids = cloudID(paintings.map(\.id))
            var changedShared = false, redraw = false
            for i in paintings.indices {
                guard let key = ids[paintings[i].id] else { continue }
                var entry = shared[key] ?? SharedEntry()
                let p = paintings[i]

                // Edits: the newer side wins. Edits made before sharing existed carry no time; they still count
                // as newer than nothing shared.
                let hasEdits = p.manualCrop != nil || p.settings.colour != nil || p.keepFrame != nil
                if p.editedAt == nil, hasEdits {
                    paintings[i].editedAt = p.renderedAt
                }
                let mine = paintings[i].editedAt ?? .distantPast, theirs = entry.editedAt ?? .distantPast
                if theirs > mine {
                    if entry.manualCrop != p.manualCrop || entry.colour != p.settings.colour {
                        paintings[i].manualCrop = entry.manualCrop
                        paintings[i].settings.colour = entry.colour
                        stale.insert(p.id)
                        redraw = true
                    }
                    if entry.keepFrame != p.keepFrame {
                        paintings[i].keepFrame = entry.keepFrame
                        redraw = true
                    }
                    paintings[i].editedAt = entry.editedAt
                } else if mine > theirs {
                    entry.manualCrop = p.manualCrop
                    entry.colour = p.settings.colour
                    entry.keepFrame = p.keepFrame
                    entry.editedAt = paintings[i].editedAt
                    changedShared = true
                }

                // Identification: confirmed by hand beats automatic, then the newer wins.
                func rank(_ id: Identification?, _ at: Date?) -> (Int, Date) {
                    (id?.status == .confirmed ? 2 : id == nil ? 0 : 1, at ?? id?.searchedAt ?? .distantPast)
                }
                let mineID = rank(p.identification, p.identifiedAt), theirsID = rank(entry.identification, entry.identifiedAt)
                if theirsID > mineID, let theirs = entry.identification {
                    paintings[i].identification = theirs
                    paintings[i].identifiedAt = entry.identifiedAt ?? theirs.searchedAt
                } else if mineID > theirsID, let mine = p.identification {
                    entry.identification = mine
                    entry.identifiedAt = p.identifiedAt ?? mine.searchedAt
                    changedShared = true
                }
                shared[key] = entry
            }
            save()
            if changedShared {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                if let data = try? encoder.encode(shared) {
                    await Task.detached { SharedFolder.write(data, to: "edits.json") }.value
                }
            }
            if redraw { Task { await processNew() } }
        } while syncAgain
    }

    // MARK: Showing the original

    /// Opens Photos at the painting's original photo (on iPhone and iPad, which can't open one photo from
    /// another app, it just opens Photos).
    func showInPhotos(_ id: String) {
        #if os(macOS)
        let escaped = id.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
            tell application "Photos"
                activate
                spotlight media item id "\(escaped)"
            end tell
            """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            lastError = "Photos couldn't show the photo: \(error[NSAppleScript.errorMessage] as? String ?? "permission may be needed in System Settings › Privacy & Security › Automation")."
        }
        #else
        if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
        #endif
    }

    // MARK: White balance by hand

    @Published private(set) var recolouring: Set<String> = []

    /// Sets a painting's white balance by hand (nil: back to none) and redraws it. Kept when the painting is
    /// processed again, and saved to Photos with the rest of the edit when that is on.
    func setColour(_ colour: ColourAdjust?, for id: String) async {
        guard let i = paintings.firstIndex(where: { $0.id == id }) else { return }
        let neutral = colour.map { abs($0.warmth) < 0.005 && abs($0.tint) < 0.005 } ?? true
        var settings = paintings[i].settings
        settings.colour = neutral ? nil : colour
        guard settings != paintings[i].settings,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return }
        recolouring.insert(id)
        defer { recolouring.remove(id) }
        let url = cacheFolder.appendingPathComponent(paintings[i].fileName)
        do {
            let data = try await Self.source(for: asset).data
            let fixed = settings
            let drawn = try await Task.detached(priority: .userInitiated) {
                try PaintingProcessor.render(imageData: data, settings: fixed, writeTo: url)
            }.value
            guard let j = paintings.firstIndex(where: { $0.id == id }) else { return }
            paintings[j].settings = drawn
            paintings[j].renderedAt = Date()
            save()
            edited(id)
            if saveEditsToPhotos { await processNew() }
        } catch {
            lastError = "The painting couldn't be redrawn: \(error.localizedDescription)"
        }
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
                          lensK: lensK, frameRemoved: painting.settings.frameRemoved,
                          cloud: cloudID([id])[id])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let line = try? encoder.encode(fix), var text = String(data: line, encoding: .utf8) {
            text += "\n"
            if SharedFolder.url != nil { SharedFolder.append(text, to: "crop-fixes.jsonl") }
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
        edited(id)
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
        await syncShared()
        await identifyPending()
    }

    // MARK: Identifying paintings

    func setGoogleKey(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        APIKeyStore.save(trimmed?.isEmpty == false ? trimmed : nil)
        hasGoogleKey = APIKeyStore.load() != nil
        if hasGoogleKey { Task { await identifyPending() } }
    }

    /// Looks up every painting not yet searched for, when automatic identification is on (or `force`), one at
    /// a time. Free sources come first (the caption label, the museum's collection); Google only with a key.
    func identifyPending(force: Bool = false) async {
        guard identifyAutomatically || force, !isIdentifying else { return }
        // Paintings photographed close together first, so each museum's paintings are fetched once. Paintings
        // the search gave up on are searched again when it improves; matches confirmed by hand never are.
        let pending = paintings.filter { needsSearch($0) }
            .sorted { ($0.takenAt ?? .distantPast) < ($1.takenAt ?? .distantPast) }
            .map(\.id)
        guard !pending.isEmpty else { return }
        isIdentifying = true
        identifyDone = 0
        identifyTotal = pending.count
        defer { isIdentifying = false; indexingMuseum = nil }
        for id in pending {
            guard let p = paintings.first(where: { $0.id == id }), needsSearch(p) else { continue }
            do {
                try await identify(id, useGoogle: true)
            } catch IdentifyError.google(let message) {
                // Google failing (a bad key, the month's limit) stops only Google; the free search carries on.
                lastError = "Google couldn't search: \(message). Other paintings are still searched without it."
            } catch {
                lastError = error.localizedDescription
            }
            identifyDone += 1
            if identifyDone % 25 == 0 { await syncShared() }
        }
        await syncShared()
    }

    /// Bump when the search improves, so paintings it couldn't place are tried again.
    static let searchVersion = 3

    private func needsSearch(_ p: Painting) -> Bool {
        guard let id = p.identification else { return true }
        return id.status == .unidentified && (id.searchVersion ?? 1) < Self.searchVersion
    }

    /// Searches for one painting and stores what was found: first its caption label, then the collections of
    /// the museums where it was photographed, then (if a key is saved and the free search wasn't certain)
    /// Google. A painting confirmed by hand keeps its details; the search only refreshes the other candidates.
    func identify(_ id: String, useGoogle: Bool = true) async throws {
        guard let painting = paintings.first(where: { $0.id == id }),
              let url = await imageURL(for: painting),
              let crop = Identifier.loadImage(url, maxPixel: 1024) else { throw IdentifyError.noImage }
        searching.insert(id)
        defer { searching.remove(id) }

        var results: [Identification] = []
        func settled() -> Bool { results.contains { $0.status == .matched } }

        // 1. The caption label: in the photo itself, or a label photo taken within two minutes of it.
        let lines = await labelLines(for: id)
        if !lines.isEmpty, let found = await Identifier.fromLabel(lines, photo: crop) { results.append(found) }

        // 2. The museums where it was photographed.
        var museums: [Museum] = []
        if !settled(), let lat = painting.latitude, let lon = painting.longitude {
            museums = await museumsNear(lat, lon)
            for museum in museums where !settled() {
                guard let index = await museumIndex(museum) else { continue }
                if let found = await Identifier.fromMuseum(index, photo: crop) { results.append(found) }
            }
        }

        // 3. Google, when a key is saved, as the last resort.
        var googleError: Error?
        if !settled(), useGoogle, let key = APIKeyStore.load(), lookupsLeft > 0 {
            UserDefaults.standard.set(lookupsThisMonth + 1, forKey: Self.monthKey)
            do { results.append(try await Identifier.identify(imageAt: url, apiKey: key)) } catch { googleError = error }
        }

        var found = Self.combine(results)
        found.museums = museums.map(\.name)
        found.searchVersion = Self.searchVersion
        guard let i = paintings.firstIndex(where: { $0.id == id }) else { return }
        if var kept = paintings[i].identification, kept.status == .confirmed {
            kept.candidates = found.candidates
            kept.pages = found.pages
            kept.clues = found.clues
            kept.guess = found.guess
            kept.museums = found.museums
            kept.searchedAt = found.searchedAt
            paintings[i].identification = kept
        } else {
            paintings[i].identification = found
        }
        save()
        if let googleError { throw googleError }
    }

    /// One answer from several searches: a match beats a possible match, the closer image wins between equals,
    /// and every candidate stays on offer.
    private static func combine(_ results: [Identification]) -> Identification {
        func score(_ r: Identification) -> (Int, Float) {
            let order: [Identification.Status: Int] = [.matched: 0, .possible: 1, .unidentified: 2, .confirmed: 0]
            return (order[r.status] ?? 2, r.distance ?? (r.title == nil ? 9 : 0.9))
        }
        var best = results.min { score($0) < score($1) } ?? Identification(status: .unidentified, searchedAt: Date())
        best.searchedAt = Date()
        for r in results {
            for c in r.candidates where !best.candidates.contains(where: { $0.id == c.id }) { best.candidates.append(c) }
            if best.pages.isEmpty { best.pages = r.pages }
            if best.clues.isEmpty { best.clues = r.clues }
            if best.guess == nil { best.guess = r.guess }
        }
        best.candidates.sort { ($0.distance ?? 1) < ($1.distance ?? 1) }
        return best
    }

    /// Text read from the photo and from label photos taken within two minutes of it (photos that are mostly
    /// a caption: at least a few lines of text).
    private func labelLines(for id: String) async -> [String] {
        guard let painting = paintings.first(where: { $0.id == id }) else { return [] }
        var lines = await photoText(for: id)
        if let taken = painting.takenAt {
            let neighbours = paintings.filter { other in
                other.id != id && other.takenAt.map { abs($0.timeIntervalSince(taken)) <= 120 } == true
            }
            for other in neighbours {
                let text = await photoText(for: other.id)
                if text.joined().count >= 30 { lines += text }
            }
        }
        return lines
    }

    /// The text in a photo, read on the device once and kept.
    private func photoText(for id: String) async -> [String] {
        if let known = paintings.first(where: { $0.id == id })?.photoText { return known }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
              let data = try? await Self.source(for: asset).data else { return [] }
        let text = await Task.detached(priority: .utility) { Identifier.readText(imageData: data) }.value
        if let i = paintings.firstIndex(where: { $0.id == id }) {
            paintings[i].photoText = text
            save()
        }
        return text
    }

    /// The museums within 400 m of a place (looked up once per spot).
    private func museumsNear(_ latitude: Double, _ longitude: Double) async -> [Museum] {
        let spot = String(format: "%.3f,%.3f", latitude, longitude)
        if let known = museumsNear[spot] { return known }
        let found = await MuseumFinder.museums(near: latitude, longitude)
        if !found.isEmpty { museumsNear[spot] = found }
        return found
    }

    /// A museum's paintings, ready to search; fetched the first time (which can take a while for a large
    /// museum, with progress shown) and kept on the device.
    private func museumIndex(_ museum: Museum) async -> MuseumIndex? {
        let index = museumIndexes[museum.q] ?? MuseumIndex.load(key: museum.q)
        museumIndexes[museum.q] = index
        if !index.isComplete, museumsFetched.insert(museum.q).inserted {
            indexingMuseum = museum.name
            indexDone = 0
            indexTotal = 0
            await index.build(for: [museum]) { done, total in
                await MainActor.run {
                    self.indexDone = done
                    self.indexTotal = total
                }
            }
            indexingMuseum = nil
        }
        return index.works.isEmpty ? nil : index
    }

    /// Looks a painting up by a name you give. A work by that name whose image matches the photo is taken as
    /// confirmed (you named it, and the images agree); otherwise the works found are offered to choose from.
    /// Returns whether a match was found.
    @discardableResult
    func find(named name: String, for id: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let painting = paintings.first(where: { $0.id == id }),
              let url = await imageURL(for: painting),
              let crop = Identifier.loadImage(url, maxPixel: 1024) else { return false }
        searching.insert(id)
        defer { searching.remove(id) }
        var found = await Identifier.fromName(name, photo: crop)
        guard let i = paintings.firstIndex(where: { $0.id == id }) else { return false }
        let previous = paintings[i].identification
        found.museums = previous?.museums ?? []
        found.searchVersion = Self.searchVersion
        if found.status == .matched {
            found.status = .confirmed
            paintings[i].identification = found
        } else {
            // Keep what was known; put the works found first among the candidates.
            var kept = previous ?? Identification(status: .unidentified, searchedAt: Date())
            kept.candidates = found.candidates + kept.candidates.filter { c in !found.candidates.contains { $0.id == c.id } }
            paintings[i].identification = kept
        }
        save()
        identified(id)
        return found.status == .matched
    }

    /// Takes one of the candidates as the painting, confirmed.
    func confirm(_ candidate: Candidate, for id: String) {
        guard let i = paintings.firstIndex(where: { $0.id == id }) else { return }
        var identity = paintings[i].identification ?? Identification(status: .confirmed)
        identity.apply(candidate)
        identity.status = .confirmed
        paintings[i].identification = identity
        save()
        identified(id)
    }

    /// Sets the painting's details by hand (confirmed), or marks it unidentified when the title is empty.
    func setDetails(title: String, artist: String, year: String, museum: String, for id: String) {
        guard let i = paintings.firstIndex(where: { $0.id == id }) else { return }
        func clean(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        var identity = paintings[i].identification ?? Identification(status: .confirmed)
        let typed = (clean(title), clean(artist), clean(year), clean(museum))
        if typed != (identity.title, identity.artist, identity.year, identity.museum) {
            identity.wikidata = nil
            identity.link = nil
            identity.distance = nil
        }
        (identity.title, identity.artist, identity.year, identity.museum) = typed
        identity.status = typed.0 == nil ? .unidentified : .confirmed
        paintings[i].identification = identity
        save()
        identified(id)
    }

    /// Accepts the automatic match as it is.
    func acceptMatch(for id: String) {
        guard let i = paintings.firstIndex(where: { $0.id == id }), paintings[i].identification?.title != nil else { return }
        paintings[i].identification?.status = .confirmed
        save()
        identified(id)
    }

    /// Rejects the automatic match: the painting is left unidentified, with its candidates kept to choose from.
    func rejectMatch(for id: String) {
        guard let i = paintings.firstIndex(where: { $0.id == id }) else { return }
        var identity = paintings[i].identification ?? Identification(status: .unidentified)
        identity.status = .unidentified
        (identity.title, identity.artist, identity.year, identity.museum) = (nil, nil, nil, nil)
        identity.wikidata = nil
        identity.link = nil
        identity.distance = nil
        paintings[i].identification = identity
        save()
        identified(id)
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
                let colour = previous?.settings.colour
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
                        try PaintingProcessor.analyzeAndRender(imageData: data, keepFrame: keep, manual: manual,
                                                               colour: colour, writeTo: url)
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
                    manualCrop: manual,
                    photoText: previous?.photoText,
                    identification: previous?.identification,
                    editedAt: previous?.editedAt,
                    identifiedAt: previous?.identifiedAt
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
        let todo = paintings.filter { p in
            p.photosLeftAlone != true && !(p.photosRecipe.map { $0.looksSame(as: p.settings) } ?? false)
        }
        guard !todo.isEmpty else { return }
        progressDone = 0
        progressTotal = todo.count
        var failures: [String] = []

        // In small batches: Photos takes or refuses a whole batch, so one photo it won't take can't hold
        // the rest back (a refused batch is tried again one photo at a time).
        for batch in stride(from: 0, to: todo.count, by: 20).map({ Array(todo[$0..<min($0 + 20, todo.count)]) }) {
            var edits: [(asset: PHAsset, output: PHContentEditingOutput, recipe: ProcessingSettings)] = []
            for painting in batch {
                defer { progressDone += 1 }
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [painting.id], options: nil).firstObject else { continue }
                do {
                    let source = try await Self.source(for: asset)
                    if let format = source.existingFormat, format != Self.adjustmentFormat, painting.photosRecipe != nil {
                        // Edited elsewhere after this app saved its edit: leave it alone.
                        markLeftAlone(painting.id)
                        continue
                    }
                    if let existing = source.existingRecipe, existing.looksSame(as: painting.settings) {
                        // Already carries this edit (saved earlier, or by this app on another of your devices).
                        if let i = paintings.firstIndex(where: { $0.id == painting.id }) { paintings[i].photosRecipe = existing }
                        continue
                    }
                    let output = PHContentEditingOutput(contentEditingInput: source.input)
                    output.adjustmentData = PHAdjustmentData(
                        formatIdentifier: Self.adjustmentFormat,
                        formatVersion: "1",
                        data: try JSONEncoder().encode(painting.settings)
                    )
                    // The image in the format Photos asks for (HEIC or JPEG, depending on the photo).
                    let type = output.defaultRenderedContentType ?? .jpeg
                    let target = try output.renderedContentURL(for: type)
                    let recipe = painting.settings
                    let data = source.data
                    _ = try await Task.detached(priority: .utility) {
                        try PaintingProcessor.render(imageData: data, settings: recipe,
                                                     maxDimension: Library.photosEditMaxDimension, writeTo: target, as: type)
                    }.value
                    edits.append((asset, output, recipe))
                } catch {
                    failures.append(Self.describe(error))
                }
            }
            for group in await commit(edits) { failures.append(group) }
        }
        save()
        if failures.isEmpty {
            lastError = nil
        } else {
            let reasons = Dictionary(grouping: failures, by: { $0 }).sorted { $0.value.count > $1.value.count }
                .prefix(2).map { "\($0.key) (\($0.value.count))" }.joined(separator: "; ")
            lastError = "Photos didn't save \(failures.count) of \(todo.count) edits: \(reasons)."
        }
    }

    /// Saves edits to Photos as one change; if Photos refuses it, each photo separately. Returns why any failed.
    private func commit(_ edits: [(asset: PHAsset, output: PHContentEditingOutput, recipe: ProcessingSettings)]) async -> [String] {
        guard !edits.isEmpty else { return [] }
        func saved(_ done: [(asset: PHAsset, output: PHContentEditingOutput, recipe: ProcessingSettings)]) {
            let now = Date()
            for edit in done {
                let id = edit.asset.localIdentifier
                ownWrites[id] = now
                if let i = paintings.firstIndex(where: { $0.id == id }) { paintings[i].photosRecipe = edit.recipe }
            }
            save()
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for edit in edits { PHAssetChangeRequest(for: edit.asset).contentEditingOutput = edit.output }
            }
            saved(edits)
            return []
        } catch {
            guard edits.count > 1 else { return [Self.describe(error)] }
            var failures: [String] = []
            for edit in edits {
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest(for: edit.asset).contentEditingOutput = edit.output
                    }
                    saved([edit])
                } catch {
                    failures.append(Self.describe(error))
                }
            }
            return failures
        }
    }

    /// An error with its code, so a problem can be told apart (Photos' messages are often the same for all).
    private static func describe(_ error: Error) -> String {
        let e = error as NSError
        if e.domain == PHPhotosError.errorDomain, e.code == PHPhotosError.Code.userCancelled.rawValue {
            return "you chose Don't Allow"
        }
        return "\(e.localizedDescription) [\(e.domain) \(e.code)]"
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
        /// The recipe of this app's edit the photo carries now (saved here or on another of your devices).
        var existingRecipe: ProcessingSettings? {
            guard existingFormat == Library.adjustmentFormat, let data = input.adjustmentData?.data else { return nil }
            return try? JSONDecoder().decode(ProcessingSettings.self, from: data)
        }
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
