import SwiftUI

// MARK: Briques

/// Un rayon de pochettes qui défile à l'horizontale, comme sur Musique.
struct TVShelf<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.display(36, relativeTo: .title2))
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 48) { content }
                    .padding(.vertical, 30)
            }
            .scrollClipDisabled()
        }
    }
}

/// Une pochette qui se soulève sous le focus, son titre dessous.
struct TVCard<Label: View>: View {
    let cover: String?
    let title: String
    let subtitle: String?
    var size: CGFloat = 280
    @ViewBuilder var button: (AnyView) -> Label

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            button(AnyView(Cover(path: cover, size: size, radius: 12)))
                .buttonStyle(.card)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold)).oneLine()
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).oneLine() }
            }
        }
        .frame(width: size)
    }
}

extension TVCard where Label == Button<AnyView> {
    init(cover: String?, title: String, subtitle: String?, size: CGFloat = 280, action: @escaping () -> Void) {
        self.init(cover: cover, title: title, subtitle: subtitle, size: size) { cover in Button(action: action) { cover } }
    }
}

struct TVAlbumCard: View {
    let album: LocalAlbum

    var body: some View {
        TVCard(cover: album.cover, title: album.name, subtitle: album.artistName) { cover in
            NavigationLink(value: album) { cover }
        }
    }
}

/// Une liste de plages : un clic lance la pile depuis celle-ci.
struct TVTrackList: View {
    let tracks: [Track]
    var numbered = false

    @Environment(Player.self) private var player
    @Environment(\.client) private var client
    @Environment(\.showNowPlaying) private var showNowPlaying

    var body: some View {
        List(tracks.indices, id: \.self) { index in
            let track = tracks[index]
            Button {
                player.play(tracks, from: index, using: client)
                showNowPlaying()
            } label: {
                HStack(spacing: 24) {
                    if numbered {
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 50)
                    } else {
                        Cover(path: track.cover, size: 64)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).oneLine()
                        if !numbered { Text(track.artist).font(.caption).foregroundStyle(.secondary).oneLine() }
                    }
                    Spacer(minLength: 0)
                    if player.current == track {
                        Image(systemName: "waveform")
                            .foregroundStyle(Color.sage)
                            .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                    }
                    if let duration = track.duration {
                        Text(clock(duration)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

extension View {
    /// La page d'un onglet : fond DroppedNeedle et fiches d'albums et de playlists.
    func tvPage() -> some View {
        platineBackground()
            .navigationDestination(for: LocalAlbum.self) { TVAlbumView(album: $0) }
            .navigationDestination(for: PlaylistSummary.self) { TVPlaylistView(summary: $0) }
    }
}

// MARK: Onglets

struct TVHome: View {
    @Environment(Player.self) private var player
    @Environment(\.client) private var client
    @Environment(\.showNowPlaying) private var showNowPlaying
    @State private var crate: [Track] = []
    @State private var recent: [LocalAlbum] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    shelf("Dans le bac", crate)
                    shelf("Dernières écoutes", player.history.map(\.track))
                    if !recent.isEmpty {
                        TVShelf("Fraîchement pressés") { ForEach(recent) { TVAlbumCard(album: $0) } }
                    }
                }
                .padding(.horizontal, 80)
            }
            .tvPage()
            .diskFirstTask {
                crate = (try? await client.crate().items.map(\.track)) ?? crate
                recent = (try? await client.recentAlbums()) ?? recent
            }
        }
    }

    @ViewBuilder
    private func shelf(_ title: String, _ tracks: [Track]) -> some View {
        if !tracks.isEmpty {
            TVShelf(title) {
                ForEach(tracks.indices, id: \.self) { index in
                    TVCard(cover: tracks[index].cover, title: tracks[index].title, subtitle: tracks[index].artist) {
                        player.play(tracks, from: index, using: client)
                        showNowPlaying()
                    }
                }
            }
        }
    }
}

struct TVLibrary: View {
    @Environment(\.client) private var client
    @State private var albums: [LocalAlbum] = []
    /// Le curseur de la page suivante ; nil une fois tout chargé.
    @State private var cursor: String?
    @State private var finished = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 48)], spacing: 60) {
                    ForEach(albums) { album in
                        TVAlbumCard(album: album)
                            .onAppear { if album == albums.last { Task { await more() } } }
                    }
                }
                .padding(.horizontal, 80)
            }
            .tvPage()
            .task { if albums.isEmpty { await more() } }
        }
    }

    private func more() async {
        guard !finished, let page = try? await client.albums(after: cursor) else { return }
        albums += page.items
        cursor = page.next
        finished = page.next == nil
    }
}

struct TVPlaylists: View {
    @Environment(\.client) private var client
    @State private var playlists: [PlaylistSummary] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 48)], spacing: 60) {
                    ForEach(playlists) { playlist in
                        TVCard(cover: playlist.covers.first ?? nil, title: playlist.name,
                               subtitle: playlist.trackCount.map { "\($0) plages" }) { cover in
                            NavigationLink(value: playlist) { cover }
                        }
                    }
                }
                .padding(.horizontal, 80)
            }
            .overlay {
                if loaded && playlists.isEmpty {
                    ContentUnavailableView("Aucune playlist", systemImage: "music.note.list",
                                           description: Text("Crée-en une sur l'iPhone ou le web : elle apparaîtra ici."))
                }
            }
            .tvPage()
            .diskFirstTask {
                playlists = (try? await client.playlists().playlists) ?? playlists
                if !DroppedNeedle.fromDisk || !playlists.isEmpty { loaded = true }
            }
        }
    }
}

struct TVSearch: View {
    @Environment(Player.self) private var player
    @Environment(\.client) private var client
    @Environment(\.showNowPlaying) private var showNowPlaying
    @State private var query = ""
    @State private var results: LibrarySearch?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    if let albums = results?.albums, !albums.isEmpty {
                        TVShelf("Albums") { ForEach(albums) { TVAlbumCard(album: $0) } }
                    }
                    if let found = results?.tracks.map(\.track), !found.isEmpty {
                        TVShelf("Plages") {
                            ForEach(found.indices, id: \.self) { index in
                                TVCard(cover: found[index].cover, title: found[index].title, subtitle: found[index].artist) {
                                    player.play(found, from: index, using: client)
                                    showNowPlaying()
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 80)
            }
            .searchable(text: $query, prompt: "Dans ta discothèque")
            .tvPage()
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(300))
                guard !query.isEmpty, !Task.isCancelled else { return results = nil }
                results = try? await client.searchLibrary(query)
            }
        }
    }
}

// MARK: Fiches

struct TVAlbumView: View {
    let album: LocalAlbum

    @Environment(Player.self) private var player
    @Environment(\.client) private var client
    @Environment(\.showNowPlaying) private var showNowPlaying
    @State private var tracks: [Track] = []

    var body: some View {
        TVSheet(cover: album.cover, title: album.name, subtitle: album.artistName, tracks: tracks, numbered: true)
            .diskFirstTask {
                if let found = try? await client.tracks(of: album.musicbrainzId) { tracks = found.map { $0.track(in: album) } }
            }
    }
}

struct TVPlaylistView: View {
    let summary: PlaylistSummary

    @Environment(\.client) private var client
    @State private var tracks: [Track] = []

    var body: some View {
        TVSheet(cover: summary.covers.first ?? nil, title: summary.name, subtitle: summary.ownerName, tracks: tracks)
            .diskFirstTask { if let found = try? await client.playlist(summary.id).tracks { tracks = found.compactMap(\.track) } }
    }
}

/// Une fiche d'album ou de playlist : la pochette à gauche, les plages à droite.
private struct TVSheet: View {
    let cover: String?
    let title: String
    let subtitle: String?
    let tracks: [Track]
    var numbered = false

    @Environment(Player.self) private var player
    @Environment(\.client) private var client
    @Environment(\.showNowPlaying) private var showNowPlaying

    var body: some View {
        HStack(alignment: .top, spacing: 80) {
            VStack(alignment: .leading, spacing: 20) {
                Cover(path: cover, size: 480, radius: 16)
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                Text(title).font(.display(40, relativeTo: .title)).lineLimit(2)
                if let subtitle { Text(subtitle).font(.title3).foregroundStyle(.secondary) }
                HStack(spacing: 24) {
                    Button("Lecture", systemImage: "play.fill") { play(tracks) }
                    Button("Aléatoire", systemImage: "shuffle") { play(tracks.shuffled()) }
                }
                .disabled(tracks.isEmpty)
            }
            .frame(width: 480)
            TVTrackList(tracks: tracks, numbered: numbered)
        }
        .padding(.horizontal, 80)
        .platineBackground()
    }

    private func play(_ tracks: [Track]) {
        player.play(tracks, using: client)
        showNowPlaying()
    }
}

// MARK: À l'écoute

/// La platine en grand, à gauche ; le morceau et ses commandes à droite.
struct TVNowPlaying: View {
    @Environment(Player.self) private var player

    var body: some View {
        let track = player.current
        HStack(spacing: 100) {
            Turntable(cover: track?.cover, isPlaying: player.isPlaying)
                .frame(width: 760, height: 760)
            VStack(alignment: .leading, spacing: 22) {
                Text(track?.title ?? "Platine à l'arrêt")
                    .font(.display(56, relativeTo: .largeTitle))
                    .lineLimit(2)
                if let track {
                    Text(track.artist).font(.title2).foregroundStyle(.secondary)
                    Text(track.album).font(.title3).foregroundStyle(.secondary)
                    VStack(spacing: 8) {
                        ProgressView(value: min(player.elapsed, max(player.duration, 1)), total: max(player.duration, 1))
                            .tint(Color.sage)
                        HStack {
                            Text(clock(player.elapsed))
                            Spacer()
                            Text("-" + clock(max(player.duration - player.elapsed, 0)))
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .padding(.top, 20)
                    HStack(spacing: 30) {
                        Button { player.previous() } label: { Image(systemName: "backward.fill") }
                        Button { player.toggle() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .contentTransition(.symbolEffect(.replace))
                        }
                        Button { player.next() } label: { Image(systemName: "forward.fill") }
                    }
                    if let next = player.upcoming.first {
                        Text("À suivre : \(next.title) · \(next.artist)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .oneLine()
                    }
                    if let error = player.error {
                        Label("Le disque saute : \(error)", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.yellow)
                    }
                } else {
                    Button("Lire le bac", systemImage: "opticaldisc.fill") { Task { await player.playCrate() } }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                Color.base100
                Cover(path: track?.cover, size: nil, radius: 0)
                    .scaleEffect(2)
                    .blur(radius: 80)
                    .opacity(0.4)
            }
            .ignoresSafeArea()
        }
    }
}
