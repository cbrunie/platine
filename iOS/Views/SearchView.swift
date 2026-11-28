import SwiftUI

/// Recherche dans la bibliothèque pour écouter, et dans MusicBrainz pour demander.
struct SearchView: View {
    @Environment(\.client) private var client
    @Environment(Player.self) private var player
    @State private var text = {
        #if DEBUG
        UserDefaults.standard.string(forKey: "platineQuery") ?? ""
        #else
        ""
        #endif
    }()
    @State private var library = LibrarySearch(albums: [], tracks: [])
    @State private var catalogue: [SearchResult] = []
    @State private var artists: [SearchResult] = []
    @State private var error: String?
    // Deux sources de vitesses différentes : la discothèque répond vite, MusicBrainz moins.
    @State private var loadingLibrary = false
    @State private var loadingCatalogue = false
    @State private var recents = SearchHistory.load()

    private var query: String { text.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            List {
                #if !targetEnvironment(macCatalyst)
                // Le titre et le champ dans la page : de l'air au-dessus, et entre les deux.
                VStack(alignment: .leading, spacing: 14) {
                    PageTitle("Rechercher")
                    Coulisse.SearchField(text: $text, prompt: "Un disque, un artiste, une plage…") { remember(query) }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                #endif
                if query.isEmpty { recentSearches }
                if loadingCatalogue, artists.isEmpty { skeletonArtists }
                if !artists.isEmpty {
                    heading("Artistes")
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 14) {
                            ForEach(artists.prefix(10)) { artist in
                                NavigationLink(value: ArtistRef(id: artist.musicbrainzId, name: artist.title)) {
                                    ArtistBubble(name: artist.title,
                                                 image: artist.thumbUrl ?? DroppedNeedle.artistImage(artist.musicbrainzId),
                                                 size: 90)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
                if loadingLibrary, library.tracks.isEmpty, library.albums.isEmpty { skeletonRows("Morceaux") }
                if !library.tracks.isEmpty {
                    heading("Morceaux")
                    ForEach(Array(library.tracks.enumerated()), id: \.element.id) { index, item in
                        TrackRow(track: item.track) {
                            player.play(library.tracks.map(\.track), from: index, using: client)
                        }
                    }
                }
                if !library.albums.isEmpty {
                    heading("Dans ta discothèque")
                    ForEach(library.albums) { album in
                        NavigationLink(value: album) {
                            AlbumRow(cover: album.cover, title: album.name, subtitle: album.artistName) {
                                EmptyView()
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                if loadingCatalogue, catalogue.isEmpty { skeletonRows("Chez le disquaire") }
                if !catalogue.isEmpty {
                    heading("Chez le disquaire")
                    ForEach(catalogue) { album in
                        AlbumRow(
                            cover: album.coverUrl,
                            title: album.title,
                            subtitle: [album.artist, album.year.map(String.init)]
                                .compactMap(\.self).joined(separator: " · ")
                        ) {
                            RequestButton(
                                album: AlbumRequest(
                                    musicbrainzId: album.musicbrainzId,
                                    artist: album.artist,
                                    album: album.title,
                                    year: album.year
                                ),
                                alreadyThere: album.inLibrary || album.requested
                            )
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if loadingLibrary || loadingCatalogue || !isEmpty || query.isEmpty {
                    EmptyView()
                } else if let error {
                    ContentUnavailableView("Recherche impossible", systemImage: "wifi.exclamationmark",
                                           description: Text(error))
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
            .pageBackground()
            #if targetEnvironment(macCatalyst)
            .navigationTitle("Rechercher")
            .searchable(text: $text, prompt: "Un disque, un artiste, une plage…")
            .onSubmit(of: .search) { remember(query) }
            #else
            .underEmptyBar()
            .titleAfterHeader("Rechercher", after: 60)
            #endif
            .platineDestinations(ownHeader: true)
            .task(id: query) { await search(query) }
        }
    }

    private func heading(_ title: String) -> some View { ListHeading(title: title) }

    private var isEmpty: Bool {
        library.tracks.isEmpty && library.albums.isEmpty && catalogue.isEmpty && artists.isEmpty
    }

    private func search(_ query: String) async {
        guard !query.isEmpty else {
            library = LibrarySearch(albums: [], tracks: [])
            catalogue = []
            artists = []
            error = nil
            loadingLibrary = false
            loadingCatalogue = false
            return
        }
        // Le squelette dès la première lettre, sans attendre la fin de la frappe.
        loadingLibrary = true
        loadingCatalogue = true
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        #if DEBUG
        if DebugScreen.slow { try? await Task.sleep(for: .seconds(30)) }
        #endif
        library = LibrarySearch(albums: [], tracks: [])
        catalogue = []
        artists = []
        error = nil
        async let local: Void = searchLibrary(query)
        async let remote: Void = searchCatalogue(query)
        _ = await (local, remote)
        // Une recherche qu'on laisse à l'écran est gardée : pas les « da », « daf »… de la frappe.
        try? await Task.sleep(for: .seconds(2))
        if !Task.isCancelled, !isEmpty { remember(query) }
    }

    /// La bibliothèque peut manquer (pas de dossier local) sans bloquer le catalogue.
    private func searchLibrary(_ query: String) async {
        let found = try? await client.searchLibrary(query)
        guard !Task.isCancelled else { return }
        library = found ?? LibrarySearch(albums: [], tracks: [])
        loadingLibrary = false
    }

    private func searchCatalogue(_ query: String) async {
        do {
            let found = try await client.search(query)
            guard !Task.isCancelled else { return }
            catalogue = found.albums.filter { !$0.inLibrary }
            artists = found.artists ?? []
        } catch {
            // Une requête annulée parce qu'on continue à taper n'est pas une erreur.
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        loadingCatalogue = false
    }

    private func remember(_ query: String) {
        guard !query.isEmpty else { return }
        recents = SearchHistory.adding(query, to: recents)
        SearchHistory.save(recents)
    }

    // MARK: Recherches récentes

    @ViewBuilder
    private var recentSearches: some View {
        if !recents.isEmpty {
            HStack {
                Text("Recherches récentes").font(.display(20, relativeTo: .title3)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Effacer") {
                    recents = []
                    SearchHistory.save([])
                }
                .font(.subheadline)
                .buttonStyle(.borderless)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            ForEach(recents, id: \.self) { recent in
                HStack(spacing: 12) {
                    Button { text = recent } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(Color.sage)
                            Text(recent).oneLine()
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.primary)
                    Button { forget(recent) } label: { Image(systemName: "xmark").font(.caption) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Retirer \(recent)")
                }
                .listRowBackground(Color.clear)
                .macRowSpacing()
            }
        }
    }

    private func forget(_ recent: String) {
        recents.removeAll { $0 == recent }
        SearchHistory.save(recents)
    }

    // MARK: Squelettes

    @ViewBuilder
    private var skeletonArtists: some View {
        heading("Artistes")
        HStack(spacing: 14) {
            ForEach(0 ..< 5, id: \.self) { _ in
                VStack(spacing: 8) {
                    Circle().fill(Color.base300).frame(width: 90, height: 90).pulsing()
                    SkeletonLine(width: 60)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityLabel("Artistes, chargement")
    }

    @ViewBuilder
    private func skeletonRows(_ title: String) -> some View {
        heading(title)
        SkeletonRows(count: 3)
    }
}

/// Les dernières recherches, gardées sur l'appareil et effacées à la déconnexion.
enum SearchHistory {
    static let key = "searchHistory"
    private static let limit = 15

    static func load() -> [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func save(_ recents: [String]) { UserDefaults.standard.set(recents, forKey: key) }

    /// En tête de liste, sans doublon (« Muse » et « muse » comptent pour un), et limité.
    static func adding(_ query: String, to recents: [String]) -> [String] {
        let others = recents.filter { $0.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame }
        return Array(([query] + others).prefix(limit))
    }

    #if DEBUG
    /// ponytail: la vérification, lancée avec `-platineSelfTest YES`.
    static func check() {
        assert(adding("muse", to: ["Daft Punk", "Muse"]) == ["muse", "Daft Punk"])
        assert(adding("Café", to: ["cafe"]) == ["Café"])
        assert(adding("x", to: (1 ... 20).map(String.init)).count == limit)
    }
    #endif
}
