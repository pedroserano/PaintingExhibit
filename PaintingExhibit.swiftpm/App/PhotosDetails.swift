import Foundation
#if os(macOS)
import AppKit
#endif

/// The details written to a photo in Photos for its identified painting.
struct PhotoDetails: Codable, Equatable {
    var title: String
    var caption: String
    var keywords: [String]

    static let none = PhotoDetails(title: "", caption: "", keywords: [])
}

/// Mac only: writes each identified painting's title, artist, year and museum to its photos in Photos (title,
/// caption and keywords), where iCloud Photos carries them to your other devices. Apple gives iPhone and iPad
/// apps no way to do this; on the Mac it goes through the Photos app's scripting.
///
/// Only paintings you confirmed are written (an automatic match can be wrong). A title
/// or caption you wrote yourself is never replaced, and keywords you added are kept: the app changes only what is
/// empty or what it wrote itself (remembered in photos-details.json).
extension Library {
    /// Writes the details shortly, after changes have settled.
    func scheduleDetailsToPhotos(after delay: Double = 3) {
        #if os(macOS)
        guard writeDetailsToPhotos else { return }
        detailsTask?.cancel()
        detailsTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await self?.writeDetailsToPhotosNow()
        }
        #endif
    }

    /// What a photo should carry: the details of the painting it shows, if you confirmed it.
    func wantedDetails(for id: String) -> PhotoDetails? {
        guard let i = identity(of: id), i.status == .confirmed else { return nil }
        return details(of: i)
    }

    /// The title, caption and keywords for an identification.
    private func details(of i: Identification) -> PhotoDetails? {
        guard let title = i.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return nil }
        func clean(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
            return s
        }
        let byline = [clean(i.artist), clean(i.year)].compactMap { $0 }.joined(separator: ", ")
        let caption = [byline.isEmpty ? nil : byline, clean(i.museum)].compactMap { $0 }.joined(separator: ". ")
        let keywords = [clean(i.artist), clean(i.museum)].compactMap { $0 }
        return PhotoDetails(title: title, caption: caption, keywords: keywords)
    }

    #if os(macOS)
    private func writeDetailsToPhotosNow() async {
        // The first build also wrote automatic matches; take those away again (once), where they're unchanged.
        let sweepKey = "detailsMatchesCleared"
        let sweep = !UserDefaults.standard.bool(forKey: sweepKey)
        var written: [(String, PhotoDetails, PhotoDetails?)] = [], cleared: [(String, PhotoDetails, PhotoDetails?)] = []
        for p in paintings {
            if let wanted = wantedDetails(for: p.id) {
                if detailsWritten[p.id] != wanted { written.append((p.id, wanted, detailsWritten[p.id])) }
            } else if let old = detailsWritten[p.id] {
                cleared.append((p.id, .none, old))
            } else if sweep, let i = identity(of: p.id), i.status == .matched, let old = details(of: i) {
                cleared.append((p.id, .none, old))
            }
        }
        let todo = written + cleared
        guard !todo.isEmpty else {
            UserDefaults.standard.set(true, forKey: sweepKey)
            return
        }
        detailsDone = 0
        detailsTotal = todo.count
        defer { detailsTotal = 0 }
        var finished = true
        for (id, details, old) in todo {
            if Task.isCancelled || !writeDetailsToPhotos { finished = false; break }
            if let message = Self.write(details, over: old, to: id) {
                if message.contains("-1743") || message.lowercased().contains("not allowed") {
                    lastError = "Painting Exhibit isn't allowed to control Photos. Allow it in System Settings › Privacy & Security › Automation, then turn Write details to Photos off and on."
                    finished = false
                    break
                }
                // A photo no longer in Photos: forget it and go on.
                detailsWritten[id] = nil
            } else {
                detailsWritten[id] = details == .none ? nil : details
            }
            detailsDone += 1
            saveDetailsWritten()
            await Task.yield()
        }
        saveDetailsWritten()
        if finished { UserDefaults.standard.set(true, forKey: sweepKey) }
    }

    private func saveDetailsWritten() {
        if let data = try? JSONEncoder().encode(detailsWritten) { try? data.write(to: detailsURL, options: .atomic) }
    }

    /// Writes one photo's details through Photos' scripting. The title and caption are set only when empty or
    /// still what this app wrote before; the app's old keywords are swapped for the new ones and yours are kept.
    /// Returns an error message, or nil when done.
    private static func write(_ new: PhotoDetails, over old: PhotoDetails?, to id: String) -> String? {
        func text(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        func list(_ items: [String]) -> String { "{" + items.map(text).joined(separator: ", ") + "}" }
        let old = old ?? .none
        let source = """
            tell application "Photos"
                set m to media item id \(text(id))
                set t to name of m
                if t is missing value then set t to ""
                if t is "" or t is \(text(old.title)) then set name of m to \(text(new.title))
                set d to description of m
                if d is missing value then set d to ""
                if d is "" or d is \(text(old.caption)) then set description of m to \(text(new.caption))
                set k to keywords of m
                if k is missing value then set k to {}
                set kept to {}
                repeat with x in k
                    set x to x as text
                    if x is not in \(list(old.keywords)) and x is not in kept then set end of kept to x
                end repeat
                repeat with x in \(list(new.keywords))
                    set x to x as text
                    if x is not in kept then set end of kept to x
                end repeat
                set keywords of m to kept
            end tell
            """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return nil }
        let number = error[NSAppleScript.errorNumber] as? Int ?? 0
        return "\(number): \(error[NSAppleScript.errorMessage] as? String ?? "unknown error")"
    }
    #endif
}
