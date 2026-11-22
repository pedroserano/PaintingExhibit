import Foundation
import SwiftUI

/// What one painting's shared record holds: your edits (crop, white balance, frame choice) and its
/// identification, each with when it last changed, so the newer one wins when devices meet.
struct SharedEntry: Codable {
    var keepFrame: Bool?
    var manualCrop: ManualCrop?
    var colour: ColourAdjust?
    var editedAt: Date?
    var identification: Identification?
    var identifiedAt: Date?
    /// The finished recipe (crop, frame, lighting) and the processing version it was made with: another device
    /// uses it instead of analysing the photo again, and only draws the image.
    var recipe: ProcessingSettings?
    var recipeVersion: Int?
}

/// A folder you choose (normally in iCloud Drive) that the app keeps its shareable data in, so the Mac, iPhone
/// and iPad work from the same edits, identifications and museum data. A free Apple account can't use the
/// app's own iCloud storage, but any app may use a folder you pick, remembered with a bookmark.
///
/// Inside it: edits.json (each painting's shared record, keyed by its iCloud Photos ID, which is the same on
/// every device), crop-fixes.jsonl (the record of crops fixed by hand) and Museums/ (museum paintings fetched
/// for identifying). Reads and writes are coordinated with iCloud Drive.
enum SharedFolder {
    private static let bookmarkKey = "sharedFolderBookmark"
    nonisolated(unsafe) private static var resolved: URL?

    /// The folder, if one is chosen and still reachable.
    static var url: URL? {
        if let resolved { return resolved }
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: bookmarkResolutionOptions,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        if stale, let fresh = try? url.bookmarkData(options: bookmarkCreationOptions, includingResourceValuesForKeys: nil,
                                                    relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        resolved = url
        return url
    }

    /// The folder's name as shown in Settings.
    static var displayName: String? { url?.lastPathComponent }

    /// Chooses the folder (or, with nil, stops sharing).
    static func choose(_ url: URL?) {
        resolved?.stopAccessingSecurityScopedResource()
        resolved = nil
        guard let url else {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return
        }
        _ = url.startAccessingSecurityScopedResource()
        if let data = try? url.bookmarkData(options: bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
        resolved = url
    }

    // On iPhone and iPad a bookmark to a picked folder carries its access; the Mac app isn't sandboxed.
    private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = []
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = []

    // MARK: Files

    static func file(_ name: String) -> URL? { url?.appendingPathComponent(name) }

    /// Reads a file, asking iCloud Drive for it first if it isn't on this device yet. Nil if it isn't there.
    static func read(_ name: String) -> Data? {
        guard let target = file(name) else { return nil }
        try? FileManager.default.startDownloadingUbiquitousItem(at: target)
        var data: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: target, options: [], error: &error) { url in
            data = try? Data(contentsOf: url)
        }
        return data
    }

    /// Writes a whole file, coordinated with iCloud Drive.
    static func write(_ data: Data, to name: String) {
        guard let target = file(name) else { return }
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &error) { url in
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Adds a line to the end of a file.
    static func append(_ line: String, to name: String) {
        guard let target = file(name) else { return }
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: target, options: [], error: &error) { url in
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Where museum data is kept: the shared folder when one is chosen.
    static var museumsFolder: URL? {
        guard let url = file("Museums") else { return nil }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Settings: the folder edits, identifications and museum data are shared through.
struct ShareSettings: View {
    @EnvironmentObject var library: Library
    @State private var choosing = false

    var body: some View {
        Section {
            if let name = library.sharedFolderName {
                LabeledContent("Shared folder", value: name)
                HStack {
                    Button("Change Folder…") { choosing = true }
                    Button("Stop Sharing", role: .destructive) { library.chooseSharedFolder(nil) }
                }
            } else {
                Button("Choose Folder…") { choosing = true }
            }
        } header: {
            Text("Share between devices")
        } footer: {
            Text("""
            Choose the same folder in iCloud Drive (for example iCloud Drive › Painting Exhibit) on each of your \
            devices. Your crops, white balance, frame choices and identifications are kept there and shared, \
            and each museum's paintings are fetched only once for all of them.
            """)
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { library.chooseSharedFolder(url) }
        }
    }
}

/// In the gallery until a shared folder is chosen: a quick way to share with your other devices.
struct SharePrompt: View {
    @EnvironmentObject var library: Library
    @State private var choosing = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "icloud").font(.title3).foregroundStyle(.secondary)
            Text("Using Painting Exhibit on another device? Choose the shared folder (iCloud Drive › Painting Exhibit) to use its crops, edits and identifications instead of redoing them.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Choose Shared Folder…") { choosing = true }
                .buttonStyle(.bordered)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { library.chooseSharedFolder(url) }
        }
    }
}

/// Before anything is processed on a device without a shared folder: share with your other devices, or work
/// on this one alone.
struct ShareChoice: View {
    @EnvironmentObject var library: Library
    @State private var choosing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Before preparing your paintings", systemImage: "icloud").font(.headline)
            Text("If you use Painting Exhibit on another device, choose the shared folder (iCloud Drive › Painting Exhibit) so this one uses the crops, edits and identifications already made there instead of redoing them.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Choose Shared Folder…") { choosing = true }
                    .buttonStyle(.borderedProminent)
                Button("Not Now (prepare on this device)") { library.workAlone() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .padding()
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { library.chooseSharedFolder(url) }
        }
    }
}
