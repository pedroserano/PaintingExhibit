import SwiftUI

/// How the gallery is split into galleries: one long album, or a gallery for each visit, museum or artist.
enum GalleryGrouping: String, CaseIterable, Identifiable {
    case none, visit, museum, artist
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Album Order"
        case .visit: return "Visit"
        case .museum: return "Museum"
        case .artist: return "Artist"
        }
    }

    var symbol: String {
        switch self {
        case .none: return "square.grid.2x2"
        case .visit: return "calendar"
        case .museum: return "building.columns"
        case .artist: return "paintpalette"
        }
    }
}

/// One gallery: a heading and its paintings, in album order.
struct GallerySection: Identifiable {
    var id: String
    var title: String
    var subtitle: String?
    var paintings: [Painting]
}

extension GalleryGrouping {
    /// The paintings split into galleries.
    @MainActor
    func sections(of paintings: [Painting], library: Library) -> [GallerySection] {
        switch self {
        case .none:
            return [GallerySection(id: "all", title: "", paintings: paintings)]

        case .visit:
            // A visit: photos taken the same day with no gap of more than three hours. Undated photos go last.
            var sections: [GallerySection] = []
            var current: [Painting] = []
            var last: Date?
            let dated = paintings.filter { $0.takenAt != nil }.sorted { $0.takenAt! < $1.takenAt! }
            func close() {
                guard let first = current.first?.takenAt else { return }
                let places = current.compactMap { Self.place(of: $0, library: library) }
                let place = Dictionary(grouping: places, by: { $0 }).max { $0.value.count < $1.value.count }?.key
                let date = first.formatted(date: .long, time: .omitted)
                sections.append(GallerySection(id: "visit-\(first.timeIntervalSince1970)", title: place ?? date,
                                               subtitle: place == nil ? nil : date, paintings: current))
                current = []
            }
            for p in dated {
                if let last, let t = p.takenAt,
                   !Calendar.current.isDate(last, inSameDayAs: t) || t.timeIntervalSince(last) > 3 * 3600 {
                    close()
                }
                current.append(p)
                last = p.takenAt
            }
            close()
            let undated = paintings.filter { $0.takenAt == nil }
            if !undated.isEmpty {
                sections.append(GallerySection(id: "visit-undated", title: "Date not known", paintings: undated))
            }
            return sections

        case .museum:
            return keyed(paintings, unknown: "Museum not known") { Self.place(of: $0, library: library) }

        case .artist:
            return keyed(paintings, unknown: "Artist not known") { p in
                guard let i = library.identity(of: p.id), i.isIdentified else { return nil }
                return i.artist
            }
        }
    }

    /// Paintings grouped by a name, the groups in alphabetical order and the unknown ones last.
    private func keyed(_ paintings: [Painting], unknown: String, key: (Painting) -> String?) -> [GallerySection] {
        var groups: [String: [Painting]] = [:]
        var unknowns: [Painting] = []
        for p in paintings {
            if let k = key(p), !k.isEmpty { groups[k, default: []].append(p) } else { unknowns.append(p) }
        }
        var sections = groups.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { GallerySection(id: "\(rawValue)-\($0)", title: $0, paintings: groups[$0]!) }
        if !unknowns.isEmpty {
            sections.append(GallerySection(id: "\(rawValue)-unknown", title: unknown, paintings: unknowns))
        }
        return sections
    }

    /// Where the painting was seen: the museum the photo was taken in (from its location) or, failing that, the
    /// museum that holds the identified work.
    @MainActor
    static func place(of painting: Painting, library: Library) -> String? {
        let identity = library.identity(of: painting.id)
        if let seen = painting.identification?.museums.first ?? identity?.museums.first { return seen }
        if let identity, identity.isIdentified { return identity.museum }
        return nil
    }
}

/// In the details panel: the other photos of this painting, to choose which one the exhibit shows, or to say
/// one is a different painting.
struct SamePaintingSection: View {
    @EnvironmentObject var library: Library
    let paintingID: String

    var body: some View {
        let photos = library.photos(of: paintingID)
        let me = library.paintings.first { $0.id == paintingID }
        if photos.count > 1 {
            Section {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(photos, id: \.self) { id in
                            if let p = library.paintings.first(where: { $0.id == id }) {
                                Thumbnail(painting: p)
                                    .frame(width: 84, height: 84)
                                    .overlay(alignment: .topTrailing) {
                                        if id == photos.first {
                                            Image(systemName: "star.circle.fill")
                                                .symbolRenderingMode(.multicolor)
                                                .foregroundStyle(.yellow)
                                                .padding(3)
                                        }
                                    }
                                    .overlay {
                                        if id == paintingID {
                                            RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2)
                                        }
                                    }
                                    .contextMenu {
                                        Button("Show This Photo for the Painting", systemImage: "star") {
                                            library.choosePhoto(id)
                                        }
                                        Button("Show in Photos", systemImage: "photo.on.rectangle") {
                                            library.showInPhotos(id)
                                        }
                                        Button("Not the Same Painting", systemImage: "rectangle.badge.xmark") {
                                            library.separatePhoto(id)
                                        }
                                    }
                                    .onTapGesture { library.choosePhoto(id) }
                                    .help("Click to show this photo for the painting; right-click for more")
                            }
                        }
                    }
                }
                if photos.first != paintingID {
                    Button("Show This Photo for the Painting") { library.choosePhoto(paintingID) }
                }
                Button("Not the Same Painting", role: .destructive) { library.separatePhoto(paintingID) }
            } header: {
                Text("Photos of this painting (\(photos.count))")
            } footer: {
                Text("The starred photo is the one shown\(library.hideDuplicates ? "; the others are hidden from the gallery and exhibit" : ""). Tap another to show it instead. Identifying one photo identifies them all.")
            }
        } else if me?.separate == true {
            Section {
                Button("Group with Look-alikes Again") { library.joinLookAlikes(paintingID) }
            } footer: {
                Text("You said this photo shows a different painting from the photos it looked like.")
            }
        }
    }
}
