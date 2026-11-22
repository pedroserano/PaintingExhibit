import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision
import Security

/// What is known about which painting a photo shows, and how it was found.
struct Identification: Codable, Hashable {
    enum Status: String, Codable {
        /// Found by the search and confirmed by comparing images on the device.
        case matched
        /// Found by the search, but the images couldn't confirm it: worth a look.
        case possible
        /// The search found nothing that fits.
        case unidentified
        /// Chosen or typed by hand. Never replaced by an automatic search.
        case confirmed
    }

    var status: Status
    var searchedAt: Date?
    var title: String?
    var artist: String?
    var year: String?
    var museum: String?
    /// The work's Wikidata item (Q-number), when it has one.
    var wikidata: String?
    /// A page about the work: Wikipedia when there is an article, else Wikidata or the page Google found.
    var link: String?
    /// Google's best guess at what the picture shows, in its own words.
    var guess: String?
    /// The names Google associates with the picture (artist, subject, place), most relevant first.
    var clues: [String] = []
    /// The works this could be, best first.
    var candidates: [Candidate] = []
    /// Web pages showing the same picture.
    var pages: [WebPage] = []
    /// Visual distance between the photo and the chosen work's image (lower is closer; under about 0.42
    /// is the same painting).
    var distance: Float?
    /// How the match was found: "the caption label", "the museum's collection", "Google".
    var via: String?
    /// The museums the photo was taken in, from its location.
    var museums: [String] = []
    /// Which version of the search found this; older unconfirmed results are searched again.
    var searchVersion: Int?

    var isIdentified: Bool { title != nil && status != .unidentified }
}

/// A work the painting could be.
struct Candidate: Codable, Hashable, Identifiable {
    var id: String { wikidata ?? title }
    var title: String
    var artist: String?
    var year: String?
    var museum: String?
    var wikidata: String?
    var imageURL: String?
    var link: String?
    /// Visual distance from the photo, when the work's image could be compared.
    var distance: Float?
}

struct WebPage: Codable, Hashable, Identifiable {
    var id: String { url }
    var url: String
    var title: String
}

enum IdentifyError: LocalizedError {
    case noKey, google(String), noImage
    var errorDescription: String? {
        switch self {
        case .noKey: return "Add a Google Cloud Vision API key in Settings to identify paintings."
        case .google(let message): return "Google couldn't search: \(message)"
        case .noImage: return "The painting's image couldn't be read."
        }
    }
}

/// Identifies a painting: Google's web detection finds where the picture appears online and what it is
/// called, Wikidata turns that into a work with its artist, date and museum, and Apple's Vision compares the
/// photo with each work's image to confirm the match on the device.
///
/// Only the cropped painting is sent to Google (small, with no location or other photo details). Wikidata
/// and Wikimedia Commons receive only the names and IDs being looked up.
enum Identifier {
    /// Distances (1 − similarity of MobileCLIP fingerprints) at or under this are the same painting. Measured on
    /// the album's Cleveland photos: every match came out 0.02–0.07 against the museum's image, and the nearest
    /// other painting 0.18 or more; between this and `likelyWork` matches are left to be checked.
    static let sameWork: Float = 0.10
    /// Distances at or under this are probably the same painting, or another version of it.
    static let likelyWork: Float = 0.14
    /// Identifies the client to Wikidata and Wikimedia Commons, as they ask.
    static let userAgent = "PaintingExhibit/0.2 (https://github.com/pedroserano/PaintingExhibit)"

    // MARK: The whole search

    static func identify(imageAt url: URL, apiKey: String) async throws -> Identification {
        guard let crop = loadImage(url, maxPixel: 1024), let jpeg = jpegData(crop) else { throw IdentifyError.noImage }
        let web = try await webDetection(jpeg: jpeg, apiKey: apiKey)
        return await resolve(web, photo: crop)
    }

    /// Works out the painting from what Google found, comparing candidates with the photo.
    static func resolve(_ web: WebResult, photo crop: CGImage) async -> Identification {
        let photoPrint = await featurePrint(crop)

        // Works Google's entities are known as in Wikidata; failing that, works whose names Google suggests.
        var works = await artworks(forEntityIDs: web.entities.map(\.id))
        let viaEntities = !works.isEmpty
        if works.isEmpty {
            for name in searchNames(web).prefix(2) {
                works = await artworks(named: name)
                if !works.isEmpty { break }
            }
        }

        let mentioned = (web.entities.map(\.name) + [web.guess ?? ""] + web.pages.map(\.title))
            .joined(separator: " ").lowercased()
        let candidates = await compared(Array(works.prefix(6)), with: photoPrint, mentioned: mentioned)
        func rank(_ c: Candidate) -> Float { Identifier.rank(c, mentioned: mentioned) }

        var result = Identification(status: .unidentified, searchedAt: Date())
        result.via = "Google"
        result.guess = web.guess
        result.clues = Array(web.entities.map(\.name).prefix(6))
        result.pages = Array(web.pages.prefix(8))
        result.candidates = candidates
        if let best = candidates.first {
            if let d = best.distance {
                if d <= likelyWork {
                    result.status = d <= sameWork ? .matched : .possible
                    result.apply(best)
                }
            } else if viaEntities || rank(best) < 0.9 {
                // No image to compare, but Google named this work (or its artist): a lead worth confirming.
                result.status = .possible
                result.apply(best)
            }
        }
        // Google's guess names the work whose image was just found to differ: no lead after all.
        let guessRuledOut = candidates.contains { c in
            (c.distance ?? 0) > likelyWork && c.title.caseInsensitiveCompare(web.guess ?? "") == .orderedSame
        }
        if result.title == nil, !guessRuledOut, let guess = web.guess, !guess.isEmpty {
            // No work found: keep Google's guess as a lead to confirm by hand.
            result.status = .possible
            result.title = guess.prefix(1).uppercased() + guess.dropFirst()
            result.link = web.pages.first?.url
        }
        if result.title == nil { result.status = .unidentified }
        return result
    }

    // MARK: Comparing candidates

    /// Closest image first. A work with no image to compare ranks just behind a likely match when its artist
    /// is mentioned (by Google, or on the caption label), and behind the rest when not.
    static func rank(_ c: Candidate, mentioned: String) -> Float {
        if let d = c.distance { return d }
        let artistMentioned = c.artist.map { !mentioned.isEmpty && mentioned.contains($0.lowercased()) } ?? false
        return artistMentioned ? likelyWork + 0.001 : 0.9
    }

    /// The candidates with each one's image compared with the photo, best first.
    static func compared(_ works: [Candidate], with photoPrint: [Float]?, mentioned: String) async -> [Candidate] {
        var candidates: [Candidate] = []
        for work in works {
            var c = work
            if c.distance == nil, let photoPrint, let image = c.imageURL, let print = await remotePrint(image) {
                c.distance = distance(photoPrint, print)
            }
            candidates.append(c)
        }
        return candidates.enumerated()
            .sorted { (rank($0.element, mentioned: mentioned), $0.offset) < (rank($1.element, mentioned: mentioned), $1.offset) }
            .map(\.element)
    }

    // MARK: Free sources: the museum's collection and the caption label

    /// Looks the photo up among the paintings of the museums it was taken in: the nearest few by thumbnail
    /// fingerprint, then each checked against the work's large image.
    static func fromMuseum(_ index: MuseumIndex, photo crop: CGImage) async -> Identification? {
        guard let photoPrint = await featurePrint(crop) else { return nil }
        let shortlist = await Task.detached { index.nearest(to: photoPrint, count: 4) }.value
        guard !shortlist.isEmpty else { return nil }
        let candidates = await compared(shortlist.map(\.work.candidate), with: photoPrint, mentioned: "")
        var result = Identification(status: .unidentified, searchedAt: Date())
        result.via = "the museum's collection"
        result.candidates = candidates.filter { ($0.distance ?? 1) <= 0.25 }
        if let best = candidates.first, let d = best.distance, d <= likelyWork {
            result.status = d <= sameWork ? .matched : .possible
            result.apply(best)
        }
        return result
    }

    /// Looks up the works named on a caption label (read from the photo, or from a label photo taken just
    /// before or after it). A work whose title and artist both appear on the label is taken as a match even when
    /// its image can't be compared; otherwise the image decides.
    static func fromLabel(_ lines: [String], photo crop: CGImage) async -> Identification? {
        let text = lines.joined(separator: " ").lowercased()
        let titles = labelTitleLines(lines)
        guard !titles.isEmpty else { return nil }
        // Each title-like line searched with the label's other short lines (one is usually the artist), which
        // finds works by their description ("painting by Édouard Manet"), then by its name alone.
        var works: [Candidate] = []
        func add(_ found: [Candidate]) {
            for w in found.prefix(6) where !works.contains(where: { $0.wikidata == w.wikidata }) { works.append(w) }
        }
        let short = Array(titles.prefix(4))
        for (i, line) in short.enumerated() {
            for other in short where other != line && i < 3 {
                add(await artworks(searching: "\(line) \(other)"))
            }
        }
        for line in short.prefix(3) where works.count < 12 { add(await artworks(named: line)) }
        // Works whose artist is on the label first: a title alone is often shared ("Portrait of a Man").
        let named = { (c: Candidate) in c.artist.map { text.contains($0.lowercased()) } ?? false }
        works = works.filter(named) + works.filter { !named($0) }
        guard !works.isEmpty else { return nil }
        let candidates = await compared(Array(works.prefix(6)), with: await featurePrint(crop), mentioned: text)
        var result = Identification(status: .unidentified, searchedAt: Date())
        result.via = "the caption label"
        result.candidates = candidates
        if let best = candidates.first {
            if let d = best.distance, d <= likelyWork {
                result.status = d <= sameWork || named(best) ? .matched : .possible
                result.apply(best)
            } else if best.distance == nil && named(best) {
                result.status = .matched
                result.apply(best)
            }
        }
        return result
    }

    /// Looks up a work by a name you give (from Apple's Look Up, a label, anywhere): Wikidata's works by that
    /// name, each compared with the photo.
    static func fromName(_ name: String, photo crop: CGImage) async -> Identification {
        var works: [Candidate] = []
        for found in [await artworks(searching: name), await artworks(named: name)] {
            for w in found.prefix(8) where !works.contains(where: { $0.wikidata == w.wikidata }) { works.append(w) }
        }
        let candidates = await compared(Array(works.prefix(10)), with: await featurePrint(crop), mentioned: name.lowercased())
        var result = Identification(status: .unidentified, searchedAt: Date())
        result.via = "the name you gave"
        result.candidates = candidates
        if let best = candidates.first, let d = best.distance, d <= likelyWork {
            result.status = .matched
            result.apply(best)
        }
        return result
    }

    /// The lines of a caption label that could be a work's title: a few words of letters, not the medium,
    /// dimensions, dates, credit line or museum boilerplate.
    static func labelTitleLines(_ lines: [String]) -> [String] {
        let skip = ["oil on", "on canvas", "on panel", "on paper", "gift of", "purchase", "fund", "collection",
                    "bequest", "museum", "acrylic", "tempera", "watercolor", "watercolour", "gouache", "graphite",
                    "courtesy", "lent by", "inches", " cm", "copyright", "©"]
        return lines.compactMap { raw in
            // Dates and life dates follow titles and names: "Chrysanthemum, 1906–42", "(Dutch, 1872–1944)".
            let undated = raw.replacingOccurrences(of: "[,(]?\\s*(c\\.?|ca\\.?|about)?\\s*\\d{3,4}.*$", with: "",
                                                   options: [.regularExpression, .caseInsensitive])
            let line = undated.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            let words = line.split(separator: " ")
            let letters = line.filter(\.isLetter).count
            guard !words.isEmpty, words.count <= 10, letters >= 5,
                  Double(letters) / Double(max(line.count, 1)) > 0.6,
                  !skip.contains(where: { line.lowercased().contains($0) }) else { return nil }
            return line
        }
    }


    // MARK: Google Cloud Vision web detection

    struct WebResult {
        var guess: String?
        var entities: [(id: String, name: String, score: Double)] = []
        var pages: [WebPage] = []
    }

    static func webDetection(jpeg: Data, apiKey: String) async throws -> WebResult {
        var request = URLRequest(url: URL(string: "https://vision.googleapis.com/v1/images:annotate")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        let body: [String: Any] = [
            "requests": [[
                "image": ["content": jpeg.base64EncodedString()],
                "features": [["type": "WEB_DETECTION", "maxResults": 15]],
                "imageContext": ["webDetectionParams": ["includeGeoResults": false]]
            ]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return try parseWebDetection(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func parseWebDetection(_ data: Data, status: Int) throws -> WebResult {
        struct Envelope: Decodable {
            struct Failure: Decodable { var message: String? }
            struct Response: Decodable {
                struct Web: Decodable {
                    struct Entity: Decodable { var entityId: String?; var description: String?; var score: Double? }
                    struct Page: Decodable { var url: String?; var pageTitle: String? }
                    struct Label: Decodable { var label: String? }
                    var webEntities: [Entity]?
                    var pagesWithMatchingImages: [Page]?
                    var bestGuessLabels: [Label]?
                }
                var webDetection: Web?
                var error: Failure?
            }
            var responses: [Response]?
            var error: Failure?
        }
        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        if let message = envelope?.error?.message ?? envelope?.responses?.first?.error?.message {
            throw IdentifyError.google(message)
        }
        guard status == 200, let first = envelope?.responses?.first else {
            throw IdentifyError.google("unexpected reply (HTTP \(status))")
        }
        // A picture Google knows nothing about comes back with no web detection at all.
        let web = first.webDetection ?? Envelope.Response.Web()
        var result = WebResult()
        result.guess = web.bestGuessLabels?.compactMap(\.label).first
        result.entities = (web.webEntities ?? []).compactMap { e in
            guard let id = e.entityId, let name = e.description, !name.isEmpty else { return nil }
            return (id, name, e.score ?? 0)
        }
        result.pages = (web.pagesWithMatchingImages ?? []).compactMap { p in
            guard let url = p.url else { return nil }
            return WebPage(url: url, title: cleanTitle(p.pageTitle ?? url))
        }
        return result
    }

    /// A page title without HTML tags and entities.
    static func cleanTitle(_ title: String) -> String {
        var t = title.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            t = t.replacingOccurrences(of: entity, with: char)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Names to look up in Wikidata when none of Google's entities is a known work: its best guess, then the
    /// main part of the matching pages' titles ("Water Lilies - Wikipedia" → "Water Lilies").
    static func searchNames(_ web: WebResult) -> [String] {
        var names: [String] = []
        if let guess = web.guess, guess.count > 3 { names.append(guess) }
        for page in web.pages {
            let main = page.title.components(separatedBy: CharacterSet(charactersIn: "|–—"))
                .first?.components(separatedBy: " - ").first?
                .replacingOccurrences(of: "File:", with: "")
                .replacingOccurrences(of: "\\.(jpe?g|png|tiff?)$", with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespaces) ?? ""
            if main.count > 3, !names.contains(where: { $0.caseInsensitiveCompare(main) == .orderedSame }) { names.append(main) }
        }
        return names
    }

    // MARK: Wikidata

    /// Paintings found by Wikidata's full-text search, which also reads descriptions ("painting by
    /// Édouard Manet"), most relevant first.
    static func artworks(searching text: String) async -> [Candidate] {
        var components = URLComponents(string: "https://www.wikidata.org/w/api.php")!
        components.queryItems = [
            .init(name: "action", value: "query"), .init(name: "list", value: "search"), .init(name: "format", value: "json"),
            .init(name: "srsearch", value: "\(text) haswbstatement:P31=Q3305213"), .init(name: "srlimit", value: "8"),
            .init(name: "srprop", value: "")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = (json["query"] as? [String: Any])?["search"] as? [[String: Any]] else { return [] }
        let ids = hits.compactMap { $0["title"] as? String }.filter { $0.hasPrefix("Q") }
        guard !ids.isEmpty else { return [] }
        return await artworks(query: """
            SELECT ?item ?itemLabel ?creatorLabel ?inception ?collectionLabel ?img ?article WHERE {
              VALUES ?item { \(ids.map { "wd:\($0)" }.joined(separator: " ")) }
              \(details)
            }
            """, order: nil).sorted { a, b in
                (ids.firstIndex(of: a.wikidata ?? "") ?? 99) < (ids.firstIndex(of: b.wikidata ?? "") ?? 99)
            }
    }

    /// Works of art (things with a creator) that are Google entities: Wikidata records Freebase and Google
    /// Knowledge Graph IDs, the IDs Google's web detection uses.
    static func artworks(forEntityIDs ids: [String]) async -> [Candidate] {
        let quoted = ids.prefix(15).map { "\"\(sparqlEscape($0))\"" }.joined(separator: " ")
        guard !quoted.isEmpty else { return [] }
        return await artworks(query: """
            SELECT ?item ?itemLabel ?creatorLabel ?inception ?collectionLabel ?img ?article ?mid WHERE {
              VALUES ?mid { \(quoted) }
              { ?item wdt:P646 ?mid } UNION { ?item wdt:P2671 ?mid }
              \(details)
            }
            """, order: ids)
    }

    /// Works of art whose name matches, most relevant first.
    static func artworks(named name: String) async -> [Candidate] {
        await artworks(query: """
            SELECT ?item ?itemLabel ?creatorLabel ?inception ?collectionLabel ?img ?article ?num WHERE {
              SERVICE wikibase:mwapi {
                bd:serviceParam wikibase:api "EntitySearch"; wikibase:endpoint "www.wikidata.org";
                  mwapi:search "\(sparqlEscape(name))"; mwapi:language "en".
                ?item wikibase:apiOutputItem mwapi:item. ?num wikibase:apiOrdinal true.
              }
              \(details)
            } ORDER BY ?num LIMIT 40
            """, order: nil)
    }

    private static let details = """
        ?item wdt:P170 ?creator .
        OPTIONAL { ?item wdt:P571 ?inception }
        OPTIONAL { ?item wdt:P195 ?collection }
        OPTIONAL { ?item wdt:P18 ?img }
        OPTIONAL { ?article schema:about ?item ; schema:isPartOf <https://en.wikipedia.org/> }
        SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
        """

    private static func artworks(query: String, order: [String]?) async -> [Candidate] {
        guard let rows = await sparql(query, timeout: 30) else { return [] }
        var byItem: [String: (Candidate, Int)] = [:]
        for (rowIndex, row) in rows.enumerated() {
            guard let item = row["item"], let title = label(row["itemLabel"]) else { continue }
            let q = String(item.split(separator: "/").last ?? "")
            let rank = order.flatMap { o in row["mid"].flatMap { o.firstIndex(of: $0) } } ?? rowIndex
            if var existing = byItem[q] {
                existing.0.museum = existing.0.museum ?? label(row["collectionLabel"])
                existing.1 = min(existing.1, rank)
                byItem[q] = existing
                continue
            }
            let candidate = Candidate(title: title, artist: label(row["creatorLabel"]), year: year(row["inception"]),
                                      museum: label(row["collectionLabel"]), wikidata: q,
                                      imageURL: row["img"].map(largeImage), link: row["article"] ?? httpsImage(item))
            byItem[q] = (candidate, rank)
        }
        return byItem.values.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// Runs a Wikidata query, returning each row's values by name; nil if it couldn't be run.
    static func sparql(_ query: String, timeout: TimeInterval) async -> [[String: String]]? {
        var components = URLComponents(string: "https://query.wikidata.org/sparql")!
        components.queryItems = [URLQueryItem(name: "query", value: query)]
        var request = URLRequest(url: components.url!)
        request.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout
        for attempt in 0..<2 {
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rows = (json["results"] as? [String: Any])?["bindings"] as? [[String: Any]] {
                return rows.map { row in
                    row.compactMapValues { ($0 as? [String: Any])?["value"] as? String }
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(3_000_000_000 * (attempt + 1)))
        }
        return nil
    }

    /// A label, or nil for one Wikidata couldn't name (it then gives an ID or a blank-node link).
    static func label(_ s: String?) -> String? {
        guard let s, !s.isEmpty, !s.hasPrefix("http"), s.range(of: "^Q\\d+$", options: .regularExpression) == nil else { return nil }
        return s
    }

    /// The year of a Wikidata date ("1851-01-01T00:00:00Z" → "1851").
    static func year(_ s: String?) -> String? {
        guard let s, let m = s.range(of: "^-?\\d{1,4}", options: .regularExpression) else { return nil }
        return String(s[m])
    }

    static func httpsImage(_ s: String) -> String { s.replacingOccurrences(of: "http://", with: "https://") }

    /// A work's Commons image at the size the on-device check was measured with.
    static func largeImage(_ s: String) -> String { httpsImage(s) + "?width=960" }

    private static func sparqlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: Comparing images on the device

    /// The photo's (or a work's) fingerprint from Apple's MobileCLIP model, on the device.
    static func featurePrint(_ image: CGImage) async -> [Float]? {
        guard let embedder = await Embedder.shared() else { return nil }
        return embedder.vector(image)
    }

    /// How different two fingerprints are: 0 the same picture, around 0.1 or less the same painting
    /// photographed differently, 0.15 and more different paintings.
    static func distance(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        return 1 - zip(a, b).map(*).reduce(0, +)
    }

    /// The fingerprint of an image file's contents.
    static func featurePrintVector(_ data: Data) async -> [Float]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return await featurePrint(image)
    }

    private static func remotePrint(_ urlString: String) async -> [Float]? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return await featurePrintVector(data)
    }

    // MARK: Reading text

    /// The lines of text in a photo (a caption label, a sign), read on the device.
    static func readText(imageData: Data) -> [String] {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first, best.confidence > 0.4 else { return nil }
            return best.string
        }
    }

    // MARK: Images

    static func loadImage(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary)
    }

    /// A JPEG of the image alone: no location, date or other photo details.
    static func jpegData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

extension Identification {
    /// Takes a candidate's details as the painting's.
    mutating func apply(_ c: Candidate) {
        title = c.title
        artist = c.artist
        year = c.year
        museum = c.museum
        wikidata = c.wikidata
        link = c.link
        distance = c.distance
    }
}

// MARK: Keeping the API key

/// The Google Cloud Vision API key, kept in the Keychain.
enum APIKeyStore {
    private static let service = "com.pedroserano.PaintingExhibit.google-vision"

    static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String?) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
        guard let key, !key.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
