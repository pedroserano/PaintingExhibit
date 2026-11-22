import SwiftUI

/// Settings for identifying paintings with Google's reverse image search.
struct IdentifySettings: View {
    @EnvironmentObject var library: Library
    @State private var key = ""

    var body: some View {
        Section {
            Toggle("Identify new paintings automatically", isOn: $library.identifyAutomatically)
            Toggle("Also compare with famous paintings worldwide", isOn: $library.searchFamous)
        } header: {
            Text("Identify paintings")
        } footer: {
            Text("""
            Free, with no account: the app reads caption labels in your photos, works out the museum from \
            where each photo was taken, and compares your photo with that museum's paintings from Wikidata, on \
            this device. The first photo from a museum fetches its paintings once, which can take a while for a \
            large museum. Famous paintings worldwide (about 5,000, those with articles in at least five \
            Wikipedias) are fetched once too, about 130 MB, so a well-known painting is recognised wherever you \
            saw it. Only names and IDs are looked up; your photos stay on the device.
            """)
        }

        Section {
            if library.hasGoogleKey {
                LabeledContent("Google Cloud Vision key", value: "Saved")
                Button("Remove Key", role: .destructive) { library.setGoogleKey(nil) }
            } else {
                SecureField("Google Cloud Vision API key", text: $key)
                    .textContentType(.password)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                Button("Save Key") {
                    library.setGoogleKey(key)
                    key = ""
                }
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if library.hasGoogleKey {
                LabeledContent("Google lookups this month", value: "\(library.lookupsThisMonth) of \(Library.monthlyLookupLimit)")
            }
        } header: {
            Text("Google reverse image search (optional)")
        } footer: {
            Text("""
            For paintings the free search can't place, with a free Google Cloud Vision key of your own. \
            Only the cropped painting goes to Google, without its location or other photo details. Google's \
            first 1,000 lookups a month are free; the app stops at \(Library.monthlyLookupLimit). The key is \
            kept in the Keychain.
            """)
        }
    }
}

/// The side panel beside the painting: what's known about which painting this is (the match, the other
/// candidates, the pages found), and a place to confirm, choose another or type the details. It follows the
/// painting shown as you move through the exhibit.
struct DetailsPanel: View {
    @EnvironmentObject var library: Library
    let paintingID: String

    @State private var title = ""
    @State private var artist = ""
    @State private var year = ""
    @State private var museum = ""
    @State private var error: String?
    @State private var lookupName = ""
    @State private var lookupNote: String?

    private var painting: Painting? { library.paintings.first { $0.id == paintingID } }
    /// What's known, from whichever photo of this painting knows most.
    private var identity: Identification? { library.identity(of: paintingID) }
    private var searching: Bool { library.searching.contains(paintingID) }

    var body: some View {
        Form {
            statusSection
            SamePaintingSection(paintingID: paintingID)
            if let painting { LookUpSection(painting: painting).id(painting.id) }
            nameSection
            if let identity, !identity.candidates.isEmpty { candidatesSection(identity) }
            detailsSection
            if let identity, !identity.pages.isEmpty || !identity.clues.isEmpty { webSection(identity) }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadFields)
        .onChange(of: paintingID) {
            error = nil
            lookupName = ""
            lookupNote = nil
            loadFields()
        }
        .onChange(of: identity) { loadFields() }
    }

    private var searchButton: some View {
        Button {
            Task {
                error = nil
                do { try await library.identify(paintingID) } catch { self.error = error.localizedDescription }
                loadFields()
            }
        } label: {
            Label(identity?.searchedAt == nil ? "Search" : "Search Again", systemImage: "magnifyingglass")
        }
        .disabled(searching)
    }

    private func loadFields() {
        title = identity?.title ?? ""
        artist = identity?.artist ?? ""
        year = identity?.year ?? ""
        museum = identity?.museum ?? ""
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            HStack {
                Text("Which painting is this?").font(.headline)
                Spacer()
                searchButton
            }
            if searching {
                HStack { ProgressView(); Text("Searching…") }
            } else if let identity {
                Text(statusText(identity)).font(.callout)
                if identity.isIdentified, identity.status != .confirmed {
                    HStack {
                        Button("That's Right") { library.acceptMatch(for: paintingID) }
                        Button("Not This Painting", role: .destructive) {
                            library.rejectMatch(for: paintingID)
                            loadFields()
                        }
                    }
                    .buttonStyle(.bordered)
                }
                if let link = identity.link, let url = URL(string: link) {
                    Link("About this work", destination: url)
                }
            } else {
                Text("Not searched for yet. Search looks for a caption label and in the museum where you took the photo, or you can type the details below.")
                    .font(.callout)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
        }
    }

    private func statusText(_ i: Identification) -> String {
        let name = [i.title, i.artist].compactMap { $0 }.joined(separator: " by ")
        let seen = i.museums.first.map { " Photographed at \($0)." } ?? ""
        let via = i.via.map { " Found from \($0)." } ?? ""
        switch i.status {
        case .matched: return "Identified as \(name). The work's image matches your photo.\(via)\(seen)"
        case .possible:
            return (i.distance == nil
                ? "Possibly \(name). There was no image to compare with yours, so please check."
                : "Possibly \(name). The images are alike but not certainly the same work: please check.") + via + seen
        case .confirmed: return name.isEmpty ? "Details set by you." : "\(name), confirmed by you."
        case .unidentified:
            return (i.candidates.isEmpty ? "No match found. You can type the details below."
                                         : "No confident match. If one of these is it, choose it; or type the details below.") + seen
        }
    }

    private func candidatesSection(_ identity: Identification) -> some View {
        Section("Candidates") {
            ForEach(identity.candidates) { c in
                HStack(alignment: .top, spacing: 12) {
                    AsyncImage(url: c.imageURL.flatMap(URL.init(string:))) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Color.gray.opacity(0.2)
                    }
                    .frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title).font(.headline)
                        let line = [c.artist, c.year].compactMap { $0 }.joined(separator: ", ")
                        if !line.isEmpty { Text(line).font(.subheadline) }
                        if let museum = c.museum { Text(museum).font(.caption).foregroundStyle(.secondary) }
                        Text(likeness(c.distance)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if identity.wikidata == c.wikidata && identity.status == .confirmed {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("This One") {
                            library.confirm(c, for: paintingID)
                            loadFields()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    /// Finding the work by a name: what Apple's Look Up shows, a label, anything.
    private var nameSection: some View {
        Section {
            HStack {
                TextField("Painting's name", text: $lookupName)
                    .onSubmit(findByName)
                Button("Find", action: findByName)
                    .disabled(lookupName.trimmingCharacters(in: .whitespaces).isEmpty || searching)
            }
            if let lookupNote { Text(lookupNote).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("Find by name")
        } footer: {
            Text("Type or paste the name Apple's Look Up (above) shows, or from a label. The app finds the work and checks its image against your photo.")
        }
    }

    private func findByName() {
        let name = lookupName
        lookupNote = nil
        Task {
            let matched = await library.find(named: name, for: paintingID)
            loadFields()
            lookupNote = matched ? nil
                : (identity?.candidates.isEmpty ?? true) ? "No work by that name was found." : "No image matched for certain: if one of the candidates is it, choose This One."
            if matched { lookupName = "" }
        }
    }

    private func likeness(_ distance: Float?) -> String {
        guard let d = distance else { return "No image to compare" }
        if d <= Identifier.sameWork { return "Looks the same as your photo" }
        if d <= Identifier.likelyWork { return "Looks similar" }
        return "Looks different"
    }

    private var detailsSection: some View {
        Section {
            TextField("Title", text: $title)
            TextField("Artist", text: $artist)
            TextField("Year", text: $year)
            TextField("Museum", text: $museum)
            Button("Save Details") {
                library.setDetails(title: title, artist: artist, year: year, museum: museum, for: paintingID)
            }
            .disabled(title == (identity?.title ?? "") && artist == (identity?.artist ?? "")
                      && year == (identity?.year ?? "") && museum == (identity?.museum ?? ""))
        } header: {
            Text("Details")
        } footer: {
            Text("Details you save are kept: a later search never replaces them. Clear the title to mark the painting unidentified.")
        }
    }

    private func webSection(_ identity: Identification) -> some View {
        Section("Found on the web") {
            if let guess = identity.guess { LabeledContent("Google's guess", value: guess) }
            if !identity.clues.isEmpty {
                LabeledContent("Related", value: identity.clues.joined(separator: ", "))
            }
            ForEach(identity.pages) { page in
                if let url = URL(string: page.url) {
                    Link(page.title, destination: url).lineLimit(2)
                }
            }
        }
    }
}
