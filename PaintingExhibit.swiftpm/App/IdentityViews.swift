import SwiftUI

/// Settings for identifying paintings with Google's reverse image search.
struct IdentifySettings: View {
    @EnvironmentObject var library: Library
    @State private var key = ""

    var body: some View {
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
            Toggle("Identify new paintings automatically", isOn: $library.identifyAutomatically)
            LabeledContent("Lookups this month", value: "\(library.lookupsThisMonth) of \(Library.monthlyLookupLimit)")
        } header: {
            Text("Identify paintings")
        } footer: {
            Text("""
            Each painting is looked up once with Google's reverse image search, then matched to the work in \
            Wikidata for its artist, date and museum, and checked by comparing the two images on this device. \
            Only the cropped painting goes to Google, without its location or other photo details. \
            Google's first 1,000 lookups a month are free; the app stops at \(Library.monthlyLookupLimit). \
            The key is kept in the Keychain.
            """)
        }
    }
}

/// What's known about which painting this is: the match, the other candidates, the pages Google found,
/// and a place to confirm, choose another or type the details.
struct IdentityView: View {
    @EnvironmentObject var library: Library
    let paintingID: String
    let close: () -> Void

    @State private var title = ""
    @State private var artist = ""
    @State private var year = ""
    @State private var museum = ""
    @State private var error: String?

    private var painting: Painting? { library.paintings.first { $0.id == paintingID } }
    private var identity: Identification? { painting?.identification }
    private var searching: Bool { library.searching.contains(paintingID) }

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                if let identity, !identity.candidates.isEmpty { candidatesSection(identity) }
                detailsSection
                if let identity, !identity.pages.isEmpty || !identity.clues.isEmpty { webSection(identity) }
            }
            .formStyle(.grouped)
            .navigationTitle("Which painting is this?")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            error = nil
                            do { try await library.identify(paintingID) } catch { self.error = error.localizedDescription }
                            loadFields()
                        }
                    } label: {
                        Label(identity?.searchedAt == nil ? "Search" : "Search Again", systemImage: "magnifyingglass")
                    }
                    .disabled(searching || !library.hasGoogleKey || library.lookupsLeft == 0)
                }
            }
            .onAppear(perform: loadFields)
        }
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
                Text(library.hasGoogleKey ? "Not searched for yet." : "Add a Google Cloud Vision API key in Settings to search for this painting, or type its details below.")
                    .font(.callout)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
        }
    }

    private func statusText(_ i: Identification) -> String {
        let name = [i.title, i.artist].compactMap { $0 }.joined(separator: " by ")
        switch i.status {
        case .matched: return "Identified as \(name). The museum's image matches your photo."
        case .possible:
            return i.distance == nil
                ? "Possibly \(name). There was no image to compare with yours, so please check."
                : "Possibly \(name). The images are alike but not certainly the same work: please check."
        case .confirmed: return name.isEmpty ? "Details set by you." : "\(name), confirmed by you."
        case .unidentified:
            return i.candidates.isEmpty ? "No match found. You can type the details below."
                                        : "No confident match. If one of these is it, choose it; or type the details below."
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
