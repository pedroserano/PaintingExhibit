import Foundation
import CoreGraphics
import ImageIO
import Vision

/// A museum (or one of its buildings or galleries) as Wikidata knows it.
struct Museum: Codable, Hashable {
    var q: String
    var name: String
}

/// One painting in a museum's collection, with the image Wikidata has for it.
struct IndexedWork: Codable, Hashable {
    var q: String
    var title: String
    var artist: String?
    var year: String?
    var museum: String?
    var image: String
    var link: String?

    var candidate: Candidate {
        Candidate(title: title, artist: artist, year: year, museum: museum, wikidata: q,
                  imageURL: Identifier.largeImage(image), link: link)
    }
}

/// A searchable copy of the paintings in the museums where a photo was taken: each painting's image
/// fingerprint (Apple's Vision feature print of a small thumbnail), kept on the device. Built once per museum
/// from Wikidata and Wikimedia Commons, both free and open, and reused for every photo taken there.
final class MuseumIndex: @unchecked Sendable {
    let key: String
    private(set) var works: [IndexedWork] = []
    private var vectors: [Float] = []
    private var dimension = 0
    /// Works whose thumbnail couldn't be fetched, with how many times it was tried.
    private var failures: [String: Int] = [:]
    /// All of the museums' paintings with images, as last listed.
    private var listed: [IndexedWork] = []

    /// Small thumbnails keep the download modest (about 15 KB a painting); they are only used to shortlist.
    static let thumbnailWidth = 250

    init(key: String) { self.key = key }

    var remaining: [IndexedWork] {
        let have = Set(works.map(\.q))
        return listed.filter { !have.contains($0.q) && (failures[$0.q] ?? 0) < 3 }
    }
    /// When the museums' paintings were last listed (a museum with none is then complete too).
    private var listedAt: Date?
    var isComplete: Bool { listedAt != nil && remaining.isEmpty }
    var total: Int { listed.count }

    // MARK: Searching

    /// The `count` works whose fingerprints are closest to the photo's, closest first.
    func nearest(to print: [Float], count: Int) -> [(work: IndexedWork, distance: Float)] {
        guard dimension > 0, print.count == dimension else { return [] }
        var scored: [(Int, Float)] = []
        scored.reserveCapacity(works.count)
        vectors.withUnsafeBufferPointer { v in
            for i in 0..<works.count {
                var sum: Float = 0
                let base = i * dimension
                for k in 0..<dimension {
                    let d = print[k] - v[base + k]
                    sum += d * d
                }
                scored.append((i, sum))
            }
        }
        return scored.sorted { $0.1 < $1.1 }.prefix(count).map { (works[$0.0], $0.1.squareRoot()) }
    }

    // MARK: Building

    /// Lists the museums' paintings (once) and fingerprints those not done yet, reporting progress as it
    /// goes and saving every so often, so an interrupted build picks up where it stopped.
    func build(for museums: [Museum], progress: @escaping @Sendable (Int, Int) async -> Void) async {
        if listedAt == nil || !isComplete, let fresh = await Self.listWorks(in: museums) {
            listed = fresh
            listedAt = Date()
        }
        let todo = remaining
        guard !todo.isEmpty else { save(); return }
        let session = Self.session
        var done = works.count
        await progress(done, listed.count)
        await withTaskGroup(of: (IndexedWork, [Float]?).self) { group in
            var queue = todo.makeIterator()
            func addNext() -> Bool {
                guard let work = queue.next() else { return false }
                group.addTask {
                    (work, await Self.thumbnailPrint(work.image, session: session))
                }
                return true
            }
            for _ in 0..<6 { _ = addNext() }
            var sinceSave = 0
            for await (work, print) in group {
                if let print, dimension == 0 || print.count == dimension {
                    dimension = print.count
                    works.append(work)
                    vectors.append(contentsOf: print)
                    failures[work.q] = nil
                } else {
                    failures[work.q, default: 0] += 1
                }
                done += 1
                sinceSave += 1
                if sinceSave >= 200 { save(); sinceSave = 0 }
                await progress(min(done, listed.count), listed.count)
                _ = addNext()
            }
        }
        save()
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": Identifier.userAgent]
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 30
        return config.urlSession
    }()

    private static func thumbnailPrint(_ image: String, session: URLSession) async -> [Float]? {
        guard let url = URL(string: Identifier.httpsImage(image) + "?width=\(thumbnailWidth)") else { return nil }
        for attempt in 0..<3 {
            if let (data, response) = try? await session.data(from: url) {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200, let print = Identifier.featurePrintVector(data) { return print }
                if status == 404 { return nil }
            }
            // Wikimedia asks clients to slow down when busy: back off and try again.
            try? await Task.sleep(nanoseconds: UInt64(2_000_000_000 * (attempt + 1)))
        }
        return nil
    }

    /// The museums' paintings that have an image, from Wikidata: those in their collections or at their
    /// locations.
    static func listWorks(in museums: [Museum]) async -> [IndexedWork]? {
        let values = museums.map { "wd:\($0.q)" }.joined(separator: " ")
        guard !values.isEmpty else { return [] }
        let query = """
            SELECT ?w ?wLabel ?creatorLabel ?inception ?img ?mLabel ?article WHERE {
              VALUES ?m { \(values) }
              { ?w wdt:P195 ?m } UNION { ?w wdt:P276 ?m }
              ?w wdt:P31 wd:Q3305213 .
              ?w wdt:P18 ?img .
              OPTIONAL { ?w wdt:P170 ?creator }
              OPTIONAL { ?w wdt:P571 ?inception }
              OPTIONAL { ?article schema:about ?w ; schema:isPartOf <https://en.wikipedia.org/> }
              SERVICE wikibase:label { bd:serviceParam wikibase:language "en,fr,de,nl,it,es". }
            }
            """
        guard let rows = await Identifier.sparql(query, timeout: 120) else { return nil }
        var seen = Set<String>()
        var works: [IndexedWork] = []
        for row in rows {
            guard let item = row["w"], let title = Identifier.label(row["wLabel"]), let image = row["img"] else { continue }
            let q = String(item.split(separator: "/").last ?? "")
            guard seen.insert(q).inserted else { continue }
            works.append(IndexedWork(q: q, title: title, artist: Identifier.label(row["creatorLabel"]),
                                     year: Identifier.year(row["inception"]), museum: Identifier.label(row["mLabel"]),
                                     image: image, link: row["article"] ?? Identifier.httpsImage(item)))
        }
        return works
    }

    // MARK: Saving

    private struct Saved: Codable {
        var works: [IndexedWork]
        var dimension: Int
        var failures: [String: Int]
        var listed: [IndexedWork]
        var listedAt: Date?
    }

    static var folder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaintingExhibit/Museums", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var metaURL: URL { Self.folder.appendingPathComponent(key + ".json") }
    private var vectorURL: URL { Self.folder.appendingPathComponent(key + ".f32") }

    func save() {
        let meta = Saved(works: works, dimension: dimension, failures: failures, listed: listed, listedAt: listedAt)
        guard let data = try? JSONEncoder().encode(meta) else { return }
        let bytes = vectors.withUnsafeBufferPointer { Data(buffer: $0) }
        try? bytes.write(to: vectorURL, options: .atomic)
        try? data.write(to: metaURL, options: .atomic)
    }

    static func load(key: String) -> MuseumIndex {
        let index = MuseumIndex(key: key)
        guard let data = try? Data(contentsOf: index.metaURL),
              let meta = try? JSONDecoder().decode(Saved.self, from: data),
              let bytes = try? Data(contentsOf: index.vectorURL) else { return index }
        let vectors: [Float] = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard vectors.count == meta.works.count * meta.dimension else { return index }
        index.works = meta.works
        index.vectors = vectors
        index.dimension = meta.dimension
        index.failures = meta.failures
        index.listed = meta.listed
        index.listedAt = meta.listedAt
        return index
    }
}

private extension URLSessionConfiguration {
    var urlSession: URLSession { URLSession(configuration: self) }
}

/// Works out which museums a photo was taken in from its location, using Wikidata's places.
enum MuseumFinder {
    /// The places within 1.5 km that have paintings in Wikidata (in their collection or at their location),
    /// nearest first: museums, and their buildings and galleries. Indoor locations are often a few hundred
    /// metres out, and a large museum's recorded point can be far from the gallery you were in.
    static func museums(near latitude: Double, _ longitude: Double) async -> [Museum] {
        let query = """
            SELECT ?m ?mLabel ?dist WHERE {
              SERVICE wikibase:around {
                ?m wdt:P625 ?loc .
                bd:serviceParam wikibase:center "Point(\(longitude) \(latitude))"^^geo:wktLiteral .
                bd:serviceParam wikibase:radius "1.5" .
                bd:serviceParam wikibase:distance ?dist .
              }
              FILTER EXISTS { { ?w wdt:P195 ?m } UNION { ?w wdt:P276 ?m } ?w wdt:P31 wd:Q3305213 . }
              SERVICE wikibase:label { bd:serviceParam wikibase:language "en,fr,de,es,it". }
            } ORDER BY ?dist LIMIT 6
            """
        guard let rows = await Identifier.sparql(query, timeout: 60) else { return [] }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let item = row["m"] else { return nil }
            let q = String(item.split(separator: "/").last ?? "")
            guard seen.insert(q).inserted else { return nil }
            return Museum(q: q, name: Identifier.label(row["mLabel"]) ?? q)
        }
        .prefix(4).map { $0 }
    }
}
