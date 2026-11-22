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
    /// Visual distance between the photo and the chosen work's image (lower is closer; under about 0.45
    /// is the same painting).
    var distance: Float?

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
    /// Distances at or under this are the same painting (measured: your photos of a painting against its
    /// museum image came out 0.24–0.47, and details of it up to 0.52; different paintings 0.6 and over).
    static let sameWork: Float = 0.45
    /// Distances at or under this are probably the same painting, or another version of it.
    static let likelyWork: Float = 0.58
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
        let photoPrint = featurePrint(crop)

        // Works Google's entities are known as in Wikidata; failing that, works whose names Google suggests.
        var works = await artworks(forEntityIDs: web.entities.map(\.id))
        let viaEntities = !works.isEmpty
        if works.isEmpty {
            for name in searchNames(web).prefix(2) {
                works = await artworks(named: name)
                if !works.isEmpty { break }
            }
        }

        // Compare the photo with each work's image.
        var candidates: [Candidate] = []
        for work in works.prefix(6) {
            var c = work
            if let photoPrint, let image = c.imageURL, let print = await remotePrint(image) {
                c.distance = distance(photoPrint, print)
            }
            candidates.append(c)
        }
        let mentioned = (web.entities.map(\.name) + [web.guess ?? ""] + web.pages.map(\.title))
            .joined(separator: " ").lowercased()
        // Closest image first. A work with no image to compare ranks just behind a likely match when Google
        // mentions its artist, and behind the rest when it doesn't; otherwise the search's own order holds.
        func rank(_ c: Candidate) -> Float {
            if let d = c.distance { return d }
            let artistMentioned = c.artist.map { mentioned.contains($0.lowercased()) } ?? false
            return artistMentioned ? likelyWork + 0.001 : 0.9
        }
        candidates = candidates.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)

        var result = Identification(status: .unidentified, searchedAt: Date())
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
        var components = URLComponents(string: "https://query.wikidata.org/sparql")!
        components.queryItems = [URLQueryItem(name: "query", value: query)]
        var request = URLRequest(url: components.url!)
        request.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = (json["results"] as? [String: Any])?["bindings"] as? [[String: Any]] else { return [] }

        func value(_ row: [String: Any], _ key: String) -> String? { (row[key] as? [String: Any])?["value"] as? String }
        /// Labels Wikidata couldn't name come back as IDs or blank-node links.
        func label(_ s: String?) -> String? {
            guard let s, !s.hasPrefix("http"), s.range(of: "^Q\\d+$", options: .regularExpression) == nil else { return nil }
            return s
        }
        var byItem: [String: (Candidate, Int)] = [:]
        for (rowIndex, row) in rows.enumerated() {
            guard let item = value(row, "item"), let title = label(value(row, "itemLabel")) else { continue }
            let q = String(item.split(separator: "/").last ?? "")
            let rank = order.flatMap { o in value(row, "mid").flatMap { o.firstIndex(of: $0) } } ?? rowIndex
            if var existing = byItem[q] {
                existing.0.museum = existing.0.museum ?? label(value(row, "collectionLabel"))
                existing.1 = min(existing.1, rank)
                byItem[q] = existing
                continue
            }
            var image = value(row, "img")
            if let i = image {
                image = i.replacingOccurrences(of: "http://", with: "https://") + "?width=640"
            }
            let year = value(row, "inception").flatMap { s -> String? in
                guard let m = s.range(of: "^-?\\d{1,4}", options: .regularExpression) else { return nil }
                return String(s[m])
            }
            let candidate = Candidate(title: title, artist: label(value(row, "creatorLabel")), year: year,
                                      museum: label(value(row, "collectionLabel")), wikidata: q, imageURL: image,
                                      link: value(row, "article") ?? item.replacingOccurrences(of: "http://", with: "https://"))
            byItem[q] = (candidate, rank)
        }
        return byItem.values.sorted { $0.1 < $1.1 }.map(\.0)
    }

    private static func sparqlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: Comparing images on the device

    static func featurePrint(_ image: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.first
    }

    static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float? {
        var d: Float = 0
        do { try a.computeDistance(&d, to: b) } catch { return nil }
        return d
    }

    private static func remotePrint(_ urlString: String) async -> VNFeaturePrintObservation? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return featurePrint(image)
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
