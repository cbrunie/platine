import SwiftUI

/// La discothèque, rangée comme la Bibliothèque de Musique : les rayons en
/// haut, les disques fraîchement pressés en dessous.
struct LibraryView: View {
    @Environment(\.client) private var client
    @Environment(Session.self) private var session
    @State private var recent: [LocalAlbum]?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    #if !targetEnvironment(macCatalyst)
                    PageTitle("Discothèque") {
                        if session.isAdmin {
                            NavigationLink { LibraryControlsView() } label: { HeaderIcon("shield") }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Admin")
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, -12)
                    #endif
                    VStack(spacing: 0) {
                        category("Playlists", "music.note.list") { PlaylistsView() }
                        category("Artistes", "music.microphone") { ArtistsView() }
                        category("Albums", "square.stack") { AlbumsView() }
                        category("Morceaux", "music.note") { TracksView() }
                    }
                    .padding(.horizontal)

                    if recent?.isEmpty != true {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Fraîchement pressés").font(.display(20, relativeTo: .title3))
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                                if recent == nil { SkeletonGrid(count: 6) }
                                ForEach(recent ?? []) { album in
                                    NavigationLink(value: album) { AlbumCard(album: album) }.buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .pageBackground()
            #if targetEnvironment(macCatalyst)
            .navigationTitle("Discothèque")
            .toolbar {
                if session.isAdmin {
                    NavigationLink { LibraryControlsView() } label: { Label("Admin", systemImage: "shield") }
                }
            }
            #else
            .underEmptyBar()
            .titleAfterHeader("Discothèque", after: 60)
            #endif
            .platineDestinations(ownHeader: true)
            .task { recent = (try? await client.recentAlbums()) ?? [] }
            .refreshable { recent = (try? await client.recentAlbums()) ?? [] }
        }
    }

    private func category(_ title: String, _ symbol: String, @ViewBuilder destination: () -> some View) -> some View {
        NavigationLink(value: Route("library-\(title)", page: destination)) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.title3).foregroundStyle(Color.sage).frame(width: 30)
                Text(title).font(.title3)
                Spacer()
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5).padding(.leading, 44) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

// MARK: Albums

/// Ranger une liste de la discothèque : par ordre alphabétique, ou par écoutes.
enum LibrarySort: String {
    case name, listens
}

/// Le menu de tri, dans la barre de navigation.
private struct SortMenu: View {
    @Binding var sort: LibrarySort

    var body: some View {
        Menu {
            Picker("Trier par", selection: $sort) {
                Label("Ordre alphabétique", systemImage: "textformat.abc").tag(LibrarySort.name)
                Label("Nombre d'écoutes", systemImage: "chart.bar").tag(LibrarySort.listens)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Trier")
    }
}

/// Les écoutes connues, par album et par artiste. Le serveur n'a pas d'identifiant commun avec
/// la discothèque : on rapproche par titre et artiste.
struct ListenCounts: Codable, Equatable {
    private var albums: [String: Int] = [:]
    private var artists: [String: Int] = [:]

    init(_ top: [HomeItem] = []) {
        for item in top {
            guard let count = item.listenCount, let artist = item.artistName else { continue }
            albums[Self.key(item.name, artist)] = count
            artists[Discography.titleKey(artist), default: 0] += count
        }
    }

    /// Les dernières connues : le serveur peut mettre longtemps à les redemander à ListenBrainz ou
    /// Last.fm, on trie avec celles-ci en attendant. Effacées à la déconnexion.
    static var saved: ListenCounts? {
        UserDefaults.standard.data(forKey: "listenCounts").flatMap { try? JSONDecoder().decode(ListenCounts.self, from: $0) }
    }

    static func fresh(using client: DroppedNeedle) async throws -> ListenCounts {
        let counts = ListenCounts(try await client.yourTopAlbums().items)
        UserDefaults.standard.set(try? JSONEncoder().encode(counts), forKey: "listenCounts")
        return counts
    }

    private static func key(_ album: String, _ artist: String) -> String {
        Discography.titleKey(album) + "|" + Discography.titleKey(artist)
    }

    func count(album: String, artist: String) -> Int? { albums[Self.key(album, artist)] }
    func count(artist: String) -> Int? { artists[Discography.titleKey(artist)] }

    /// Les plus écoutés d'abord ; ceux qu'on ne connaît pas à la suite, par ordre alphabétique.
    static func ranked<Item>(_ items: [Item], name: (Item) -> String, count: (Item) -> Int?) -> [Item] {
        // Chaque compte normalise des titres par expression régulière : une seule fois par élément.
        items.map { (item: $0, count: count($0) ?? -1) }.sorted { a, b in
            a.count == b.count ? name(a.item).localizedStandardCompare(name(b.item)) == .orderedAscending : a.count > b.count
        }.map(\.item)
    }
}

/// D'où viennent les chiffres, et pourquoi tout n'en a pas.
private struct ListensNote: View {
    var unavailable = false

    var body: some View {
        Text(unavailable ? "Écoutes indisponibles pour l'instant : la liste reste par ordre alphabétique."
             : "Écoutes de ton historique ListenBrainz ou Last.fm, sur tes 100 albums les plus écoutés.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Tous les albums de la discothèque.
struct AlbumsView: View {
    @Environment(\.client) private var client
    @AppStorage("albumsSort") private var sort = LibrarySort.name
    @State private var sections: [LetterSection<LocalAlbum>] = []
    @State private var ranked: [LocalAlbum] = []
    @State private var listens = ListenCounts.saved
    @State private var listensFailed = false
    @State private var tracker = LetterTracker()
    @State private var total: Int?
    @State private var loaded = false
    @State private var error: String?

    private var ready: Bool { loaded && (sort == .name || listens != nil || listensFailed) }

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if !ready {
                    LazyVGrid(columns: columns, spacing: 20) { SkeletonGrid(count: 24) }.padding()
                } else if sort == .name {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.items) { album in
                                    NavigationLink(value: album) { AlbumCard(album: album) }.buttonStyle(.plain)
                                        .id(album.id)
                                        .tracksLetter(section.letter, id: album.id, in: tracker)
                                }
                            } header: {
                                Text(section.letter).font(.display(20, relativeTo: .title3))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding()
                } else {
                    ListensNote(unavailable: listens == nil).padding([.horizontal, .top])
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(ranked) { album in
                            NavigationLink(value: album) {
                                VStack(alignment: .leading, spacing: 2) {
                                    AlbumCard(album: album)
                                    if let count = listens?.count(album: album.name, artist: album.artistName) {
                                        Text("\(count.formatted()) écoutes").font(.caption.weight(.medium)).foregroundStyle(Color.sage)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
            .defaultScrollAnchor(DebugScreen.anchor)
            .scrollIndicators(.never)
            .tracksListTop(in: tracker)
            .safeAreaInset(edge: .trailing, spacing: 0) {
                if sort == .name, !sections.isEmpty {
                    AlphabetRail(available: sections.map(\.letter), tracker: tracker) { letter in
                        if let first = sections.first(where: { $0.letter == letter })?.items.first {
                            proxy.scrollTo(first.id, anchor: .top)
                        }
                    }
                }
            }
        }
        .overlay {
            if let error, sections.isEmpty {
                ContentUnavailableView("Impossible de charger", systemImage: "wifi.exclamationmark", description: Text(error))
            } else if total == 0 {
                ContentUnavailableView("Aucun disque dans les bacs", systemImage: "music.note.house")
            }
        }
        .pageBackground()
        .navigationTitle("Albums")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { SortMenu(sort: $sort) } }
        .task {
            guard sections.isEmpty else { return }
            // La liste gardée sur l'appareil d'abord, puis le serveur.
            await DroppedNeedle.$fromDisk.withValue(true) { await load() }
            await load()
        }
        .task { await loadListens() }
        .refreshable { await load() }
    }

    private func load() async {
        var albums: [LocalAlbum] = []
        do {
            var cursor: String?
            repeat {
                let page = try await client.albums(after: cursor)
                albums += page.items
                total = page.total
                cursor = page.next
            } while cursor != nil
            sections = Alphabet.sections(albums, name: \.name)
            rank()
            error = nil
        } catch is CancellationError {
        } catch {
            if DroppedNeedle.fromDisk { return }
            self.error = error.localizedDescription
            if total == nil { total = -1 }
        }
        loaded = true
    }

    private func loadListens() async {
        do {
            listens = try await ListenCounts.fresh(using: client)
            rank()
        } catch {
            listensFailed = !Task.isCancelled
        }
    }

    private func rank() {
        ranked = ListenCounts.ranked(sections.flatMap(\.items), name: \.name) {
            listens?.count(album: $0.name, artist: $0.artistName)
        }
    }
}

// MARK: Artistes

/// Les artistes de la discothèque, en médaillons ronds comme dans Musique.
struct ArtistsView: View {
    @Environment(\.client) private var client
    @AppStorage("artistsSort") private var sort = LibrarySort.name
    @State private var sections: [LetterSection<LibraryArtist>] = []
    @State private var ranked: [LibraryArtist] = []
    @State private var listens = ListenCounts.saved
    @State private var listensFailed = false
    @State private var tracker = LetterTracker()
    @State private var total: Int?
    @State private var loaded = false

    private var ready: Bool { loaded && (sort == .name || listens != nil || listensFailed) }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if !ready {
                    SkeletonRows(count: 12, side: 48, round: true)
                } else if sort == .name {
                    ForEach(sections) { section in
                        ListHeading(title: section.letter)
                        ForEach(section.items) { artist in
                            row(artist)
                                .id(artist.id)
                                .tracksLetter(section.letter, id: artist.id, in: tracker)
                                .listRowBackground(Color.clear)
                        }
                    }
                } else {
                    ListensNote(unavailable: listens == nil).listRowBackground(Color.clear).listRowSeparator(.hidden)
                    ForEach(ranked) { row($0) }
                }
            }
            .listStyle(.plain)
            .defaultScrollAnchor(DebugScreen.anchor)
            .scrollIndicators(.never)
            .tracksListTop(in: tracker)
            // Par-dessus la liste, comme l'index natif : elle garde toute sa largeur.
            .overlay(alignment: .trailing) {
                if sort == .name, ready, !sections.isEmpty {
                    AlphabetRail(available: sections.map(\.letter), tracker: tracker) { letter in
                        if let first = sections.first(where: { $0.letter == letter })?.items.first {
                            proxy.scrollTo(first.id, anchor: .top)
                        }
                    }
                }
            }
        }
        .pageBackground()
        .navigationTitle("Artistes")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { SortMenu(sort: $sort) } }
        .task {
            guard sections.isEmpty else { return }
            await DroppedNeedle.$fromDisk.withValue(true) { await load() }
            await load()
        }
        .task { await loadListens() }
    }

    @ViewBuilder
    private func row(_ artist: LibraryArtist) -> some View {
        let content = HStack(spacing: 14) {
            Cover(path: ArtistDirectory.shared.ref(id: artist.musicbrainzArtistId, named: artist.name)
                .map { DroppedNeedle.artistImage($0.id) }, size: 48, radius: 24)
            Text(artist.name).oneLine()
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if sort == .listens, let count = listens?.count(artist: artist.name) {
                    Text(count.formatted()).font(.subheadline.monospacedDigit().weight(.medium)).foregroundStyle(Color.sage)
                        .accessibilityLabel("\(count) écoutes")
                }
                Text("^[\(artist.albumCount ?? 0) album](inflect: true) · ^[\(artist.trackCount ?? 0) plage](inflect: true)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize()
        }
        // La place de la réglette, posée sur le bord de la liste.
        .padding(.trailing, sort == .name ? 12 : 0)
        Group {
            if let ref = ArtistDirectory.shared.ref(id: artist.musicbrainzArtistId, named: artist.name) {
                NavigationLink(value: ref) { content }.navigationLinkIndicatorVisibility(.hidden)
            } else {
                content
            }
        }
        .macRowSpacing()
        .listRowBackground(Color.clear)
    }

    private func load() async {
        var artists: [LibraryArtist] = []
        var cursor: String?
        repeat {
            guard let page = try? await client.libraryArtists(after: cursor) else {
                if DroppedNeedle.fromDisk { return }
                break
            }
            artists += page.items
            total = page.total
            cursor = page.next
        } while cursor != nil
        if total == nil { total = artists.count }
        sections = Alphabet.sections(artists, name: \.name)
        rank()
        loaded = true
    }

    private func loadListens() async {
        do {
            listens = try await ListenCounts.fresh(using: client)
            rank()
        } catch {
            listensFailed = !Task.isCancelled
        }
    }

    private func rank() {
        ranked = ListenCounts.ranked(sections.flatMap(\.items), name: \.name) { listens?.count(artist: $0.name) }
    }
}

// MARK: Morceaux

/// Tous les morceaux, par titre, avec une recherche ; un tap lance la liste.
struct TracksView: View {
    @Environment(\.client) private var client
    @Environment(Player.self) private var player
    @State private var tracks: [Track] = []
    @State private var sections: [LetterSection<Track>] = []
    @State private var tracker = LetterTracker()
    @State private var total: Int?
    @State private var search = ""

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if total == nil { SkeletonRows(count: 12) }
                if total != nil, !tracks.isEmpty {
                    Button { player.play(tracks.shuffled(), using: client) } label: {
                        Label("Lecture aléatoire", systemImage: "shuffle").frame(maxWidth: .infinity).foregroundStyle(Color.base100)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                ForEach(total == nil ? [] : sections) { section in
                    ListHeading(title: section.letter)
                    ForEach(section.items) { track in
                        TrackRow(track: track) {
                            player.play(tracks, from: tracks.firstIndex(of: track) ?? 0, using: client)
                        }
                        .padding(.trailing, search.isEmpty ? 12 : 0)
                        .id(track.id)
                        .tracksLetter(section.letter, id: track.id, in: tracker)
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.plain)
            .defaultScrollAnchor(DebugScreen.anchor)
            .scrollIndicators(.never)
            .tracksListTop(in: tracker)
            .overlay(alignment: .trailing) {
                if search.isEmpty, total != nil, !sections.isEmpty {
                    AlphabetRail(available: sections.map(\.letter), tracker: tracker) { letter in
                        if let first = sections.first(where: { $0.letter == letter })?.items.first {
                            proxy.scrollTo(first.id, anchor: .top)
                        }
                    }
                }
            }
        }
        .overlay { if total == 0 { ContentUnavailableView.search(text: search) } }
        .pageBackground()
        .navigationTitle("Morceaux")
        .searchable(text: $search, prompt: "Chercher une plage")
        .task(id: search) {
            try? await Task.sleep(for: .milliseconds(search.isEmpty ? 0 : 400))
            guard !Task.isCancelled else { return }
            if search.isEmpty, sections.isEmpty {
                // Toutes les plages gardées sur l'appareil d'abord, puis le serveur.
                await DroppedNeedle.$fromDisk.withValue(true) { await load() }
            } else {
                total = nil
            }
            await load()
        }
    }

    private func load() async {
        var loaded: [Track] = []
        var cursor: String?
        repeat {
            guard let page = try? await client.libraryTracks(after: cursor, search: search) else {
                if DroppedNeedle.fromDisk { return }
                break
            }
            guard !Task.isCancelled else { return }
            loaded += page.items.map(\.track)
            cursor = page.next
        } while cursor != nil
        sections = Alphabet.sections(loaded, name: \.title)
        tracks = sections.flatMap(\.items)
        total = loaded.count
    }
}

// MARK: Playlists

/// Les playlists : les siennes et celles qu'on partage avec soi.
struct PlaylistsView: View {
    @Environment(\.client) private var client
    @Environment(Player.self) private var player
    @State private var playlists: [PlaylistSummary]?
    @State private var importing = false
    @State private var naming = false
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                if playlists == nil { SkeletonGrid(count: 7) }
                ForEach(playlists ?? []) { playlist in
                    NavigationLink(value: Route("playlist-\(playlist.id)") { PlaylistView(summary: playlist) }) {
                        VStack(alignment: .leading, spacing: 6) {
                            PlaylistArtwork(covers: playlist.covers)
                                .hoverPlay("Lire \(playlist.name)", active: playlist.source.same(as: player.currentSource)) {
                                    let source = playlist.source
                                    let tracks = await source.tracks(using: client)
                                    if !tracks.isEmpty { player.play(tracks, source: source, using: client) }
                                }
                            Text(playlist.name).font(.subheadline.weight(.medium)).oneLine()
                            Text(playlist.isOwner == false ? "De \(playlist.ownerName ?? "quelqu'un")"
                                 : "^[\(playlist.trackCount ?? 0) plage](inflect: true)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .pageBackground()
        .navigationTitle("Playlists")
        .toolbar {
            // Un symbole système : la barre d'outils du Mac affiche les images à leur taille d'origine.
            // Un vrai libellé : un bouton à icône seule est rempli de sauge par la barre d’outils du Mac.
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { name = ""; naming = true } label: {
                    Label("Nouvelle", systemImage: "plus").labelStyle(.titleAndIcon)
                }
                .help("Nouvelle playlist")
                Button { importing = true } label: {
                    Label("Spotify", systemImage: "square.and.arrow.down").labelStyle(.titleAndIcon)
                }
                .help("Importer depuis Spotify")
            }
        }
        .navigationDestination(isPresented: $importing) { SpotifyImportView() }
        .alert("Nouvelle playlist", isPresented: $naming) {
            TextField("Nom", text: $name)
            Button("Annuler", role: .cancel) {}
            Button("Créer") { create() }
        }
        .alert("Playlists", isPresented: .constant(error != nil)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .onAppear { Task { await load() } }
        .refreshable { await load() }
    }

    private func load() async {
        do { playlists = try await client.playlists().playlists } catch { self.error = error.localizedDescription }
    }

    private func create() {
        guard !name.isEmpty else { return }
        Task {
            do {
                _ = try await client.createPlaylist(name)
                await load()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// La pochette d'une playlist : sa propre image, ou quatre pochettes en mosaïque.
struct PlaylistArtwork: View {
    let covers: [String?]

    var body: some View {
        Color.base300
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if covers.count >= 4 {
                    Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                        GridRow { tile(0); tile(1) }
                        GridRow { tile(2); tile(3) }
                    }
                } else if let first = covers.first {
                    Cover(path: first, size: nil, radius: 0)
                } else {
                    Image(systemName: "music.note.list").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .clipShape(.rect(cornerRadius: 10))
    }

    private func tile(_ index: Int) -> some View { Cover(path: covers[index], size: nil, radius: 0) }
}

/// Une playlist : la lire, la renommer, réordonner, retirer des plages, la supprimer.
struct PlaylistView: View {
    let summary: PlaylistSummary

    @Environment(\.client) private var client
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var detail: PlaylistDetail?
    @State private var loaded = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var deleting = false
    @State private var error: String?

    private var playable: [Track] { detail?.tracks.compactMap(\.track) ?? [] }
    private var owned: Bool { (detail?.isOwner ?? summary.isOwner) != false }
    private var source: PlaySource { summary.source }

    var body: some View {
        List {
            header
            if !loaded { SkeletonRows(count: min(summary.trackCount ?? 8, 15)) }
            entries
            if let detail, !detail.tracks.isEmpty { notes(detail) }
        }
        .listStyle(.plain)
        .pageBackground()
        .navigationBarTitleDisplayMode(.inline)
        .heroBar(title: detail?.name ?? summary.name)
        .toolbar {
            if owned {
                Menu {
                    Button("Renommer", systemImage: "pencil") { newName = detail?.name ?? summary.name; renaming = true }
                    EditButton()
                    Button("Supprimer la playlist", systemImage: "trash", role: .destructive) { deleting = true }
                } label: { Image(systemName: "ellipsis") }
            }
        }
        .alert("Renommer", isPresented: $renaming) {
            TextField("Nom", text: $newName)
            Button("Annuler", role: .cancel) {}
            Button("Enregistrer") { rename() }
        }
        .confirmationDialog("Supprimer cette playlist ?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) { delete() }
        }
        .alert("Playlist", isPresented: .constant(error != nil)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .task { await load() }
    }

    private var header: some View {
        VStack(spacing: 10) {
            PlaylistArtwork(covers: summary.covers).frame(width: 220)
            Text(detail?.name ?? summary.name).font(.display(24, relativeTo: .title2))
            if summary.isOwner == false, let owner = summary.ownerName {
                Text("De \(owner)").foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Button { player.play(playable.shuffled(), source: source, using: client) } label: {
                    Image(systemName: "shuffle").frame(width: 30, height: 30)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle)
                Button { player.play(playable, source: source, using: client) } label: {
                    Label("Lecture", systemImage: "play.fill").font(.headline).frame(width: 140, height: 30)
                }
                .buttonStyle(.glassProminent).tint(.white).foregroundStyle(.black)
                Button { player.playNext(playable, using: client) } label: {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward").frame(width: 30, height: 30)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle)
            }
            .disabled(playable.isEmpty)
        }
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var entries: some View {
        ForEach(detail?.tracks ?? []) { entry in
            if let track = entry.track {
                TrackRow(track: track) {
                    if let index = playable.firstIndex(of: track) { player.play(playable, from: index, source: source, using: client) }
                }
            } else {
                // Pas encore dans les bacs : visible, mais pas jouable.
                AlbumRow(cover: entry.coverUrl, title: entry.trackName, subtitle: entry.artistName,
                         detail: "Pas dans la discothèque") { EmptyView() }
                    .opacity(0.5)
            }
        }
        .onDelete { remove($0) }
        .onMove { move($0, $1) }
        .deleteDisabled(!owned)
        .moveDisabled(!owned)
    }

    @ViewBuilder
    private func notes(_ detail: PlaylistDetail) -> some View {
        let seconds = detail.totalDuration ?? detail.tracks.compactMap(\.duration).reduce(0, +)
        PageFooter(lines: [Dates.summary(tracks: detail.tracks.count, seconds: seconds),
                           Dates.day(seconds: detail.updatedAt).map { "Modifiée le \($0)" }].compactMap(\.self))
        let formats = Set(detail.tracks.compactMap { $0.format?.uppercased() }).sorted().joined(separator: ", ")
        let facts = FactsTable.known([
            ("Créée le", Dates.day(seconds: detail.createdAt)),
            ("Propriétaire", detail.isOwner == false ? detail.ownerName ?? summary.ownerName : "Toi"),
            ("Visibilité", detail.isPublic.map { $0 ? "Publique" : "Privée" }),
            ("Durée", seconds > 0 ? Dates.length(seconds: seconds) : nil),
            ("Dans tes bacs", playable.count == detail.tracks.count ? nil : "\(playable.count) sur \(detail.tracks.count) plages"),
            ("Artistes", Credits.artists(detail.tracks.map(\.artistName))),
            ("Albums", Set(detail.tracks.map(\.albumName)).count.formatted()),
            ("Formats", formats),
        ])
        VStack(alignment: .leading, spacing: 12) {
            Text("Notes de pochette").font(.display(20, relativeTo: .title3))
            FactsTable(facts: facts)
        }
        .padding(.vertical, 20)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func load() async {
        do { detail = try await client.playlist(summary.id) } catch { self.error = error.localizedDescription }
        loaded = true
    }

    private func remove(_ offsets: IndexSet) {
        let ids = offsets.compactMap { detail?.tracks[$0].id }
        Task {
            for id in ids { try? await client.removeTrack(id, from: summary.id) }
            await load()
        }
    }

    private func move(_ offsets: IndexSet, _ destination: Int) {
        guard let from = offsets.first, let entry = detail?.tracks[from] else { return }
        let position = destination > from ? destination - 1 : destination
        Task {
            do { try await client.moveTrack(entry.id, in: summary.id, to: position) } catch { self.error = error.localizedDescription }
            await load()
        }
    }

    private func rename() {
        Task {
            do { detail = try await client.renamePlaylist(summary.id, to: newName) } catch { self.error = error.localizedDescription }
        }
    }

    private func delete() {
        Task {
            do {
                try await client.deletePlaylist(summary.id)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Choisir la playlist où ranger des plages, ou en créer une.
struct PlaylistPicker: View {
    let tracks: [Track]

    @Environment(\.client) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [PlaylistSummary]?
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Nouvelle playlist", text: $name)
                        Button("Créer") { create() }.disabled(name.isEmpty)
                    }
                }
                .listRowBackground(Color.base200)
                Section {
                    ForEach((playlists ?? []).filter { $0.isOwner != false }) { playlist in
                        Button { add(to: playlist.id) } label: {
                            HStack(spacing: 12) {
                                PlaylistArtwork(covers: playlist.covers).frame(width: 44)
                                Text(playlist.name).foregroundStyle(.primary)
                            }
                        }
                    }
                }
                .listRowBackground(Color.base200)
            }
            .scrollContentBackground(.hidden)
            .background(Color.base100)
            .navigationTitle("Ajouter à une playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } } }
            .overlay { if playlists == nil { ProgressView() } }
            .alert("Playlist", isPresented: .constant(error != nil)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
            .task { playlists = (try? await client.playlists().playlists) ?? [] }
        }
        .presentationDetents([.medium, .large])
    }

    private func add(to playlist: String) {
        Task {
            do {
                try await client.add(tracks, to: playlist)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func create() {
        Task {
            do {
                let created = try await client.createPlaylist(name)
                add(to: created.id)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// « Récemment ajoutés » : les derniers albums entrés dans la discothèque.
struct RecentAlbumsView: View {
    @Environment(\.client) private var client
    @State private var albums: [LocalAlbum]?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 20)], spacing: 24) {
                if albums == nil { SkeletonGrid() }
                ForEach(albums ?? []) { album in
                    NavigationLink(value: album) { AlbumCard(album: album) }.buttonStyle(.plain)
                }
            }
            .padding()
        }
        .pageBackground()
        .navigationTitle("Récemment ajoutés")
        .task { albums = (try? await client.recentAlbums()) ?? [] }
    }
}
