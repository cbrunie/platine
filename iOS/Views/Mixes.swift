import SwiftUI

extension Player {
    /// Un mix tiré de quelques albums de la discothèque, mélangés.
    func shuffle(albums: [LocalAlbum], using client: DroppedNeedle) async {
        let picked = Array(albums.prefix(8))
        let found = await withTaskGroup(of: (Int, [LocalTrack]).self) { group in
            for (index, album) in picked.enumerated() {
                let id = album.musicbrainzId
                group.addTask { (index, (try? await client.tracks(of: id)) ?? []) }
            }
            var results: [(Int, [LocalTrack])] = []
            for await result in group { results.append(result) }
            return results
        }
        let tracks = found.flatMap { index, local in local.map { $0.track(in: picked[index]) } }
        if !tracks.isEmpty { play(tracks.shuffled(), using: client) }
    }
}

/// Une pochette de mix : quatre disques en mosaïque, le titre par-dessus.
struct MixCard: View {
    let title: String
    let subtitle: String
    let covers: [String?]
    var width: CGFloat = 170
    /// Le style dont cette carte porte l'emblème, à la place des pochettes.
    var genre: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                if covers.contains(where: { $0 != nil }) {
                    Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                        GridRow { tile(0); tile(1) }
                        GridRow { tile(2); tile(3) }
                    }
                } else {
                    // Sans pochettes, un dégradé propre au titre, comme les genres du web.
                    let hue = Double(title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % 360) / 360
                    LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.55),
                                            Color(hue: hue, saturation: 0.6, brightness: 0.2)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                if let genre {
                    Text(GenreEmblem.emoji(for: genre))
                        .font(.system(size: width * 0.42))
                        .rotationEffect(.degrees(-12))
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                        .padding(width * 0.08)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                Text(title)
                    .font(.display(20, relativeTo: .title3))
                    .lineLimit(2)
                    .padding(10)
            }
            .frame(width: width, height: width)
            .clipShape(.rect(cornerRadius: 10))
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: width)
        .foregroundStyle(.primary)
    }

    private func tile(_ index: Int) -> some View {
        Cover(path: covers.indices.contains(index) ? covers[index] : nil, size: width / 2, radius: 0)
    }
}

/// La pochette d'un Daily Mix : ses artistes en médaillons, son numéro en grand, son style.
struct DailyMixCard: View {
    let mix: HomeSection
    var width: CGFloat = 170

    /// « Daily Mix 1 - Rock » : le numéro et le style.
    private var parts: (number: String, genre: String) {
        let pieces = mix.title.components(separatedBy: " - ")
        let number = pieces[0].split(separator: " ").last.map(String.init) ?? ""
        return (number, pieces.dropFirst().joined(separator: " - "))
    }

    /// Trois artistes différents du mix, sinon trois pochettes.
    private var faces: [String?] {
        var seen = Set<String>()
        let artists = mix.items.compactMap(\.artistMbid).filter { seen.insert($0).inserted }.prefix(3)
        return artists.isEmpty ? Array(mix.items.prefix(3).map(\.artwork)) : artists.map(DroppedNeedle.artistImage)
    }

    var body: some View {
        let (number, genre) = parts
        let hue = Double(genre.unicodeScalars.reduce(7) { $0 &+ Int($1.value) } % 360) / 360
        let tone = Color(hue: hue, saturation: 0.5, brightness: 0.62)
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [tone, Color(hue: hue, saturation: 0.65, brightness: 0.2)],
                               startPoint: .top, endPoint: .bottom)
                HStack(spacing: -width * 0.1) {
                    ForEach(Array(faces.enumerated()), id: \.offset) { _, face in
                        Cover(path: face, size: width * 0.34, radius: width * 0.17)
                            .overlay(Circle().stroke(tone, lineWidth: 3))
                    }
                }
                .padding(width * 0.08)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(number).font(.display(width * 0.32, relativeTo: .largeTitle))
                        if !genre.isEmpty { Text(GenreEmblem.emoji(for: genre)).font(.system(size: width * 0.14)) }
                    }
                    Text(genre).font(.display(width * 0.1, relativeTo: .headline)).lineLimit(1).minimumScaleFactor(0.7)
                }
                .foregroundStyle(.white)
                .padding(width * 0.08)
            }
            .frame(width: width, height: width)
            .clipShape(.rect(cornerRadius: 10))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(mix.title)
            Text("Daily Mix \(number) · fait pour toi").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: width)
        .foregroundStyle(.primary)
    }
}

/// La pochette d'une décennie : une pochette à la couleur de l'époque, l'année en grand, et un
/// disque qui en sort, avec un album de la décennie en étiquette.
struct DecadeCard: View {
    let decade: Decade
    let subtitle: String
    var width: CGFloat = 170

    /// Une teinte par époque : orange psyché, moutarde, néon, sarcelle, bleu, violet, sauge.
    private var hue: Double {
        [1960: 0.06, 1970: 0.11, 1980: 0.9, 1990: 0.48, 2000: 0.6, 2010: 0.76, 2020: 0.27][decade.decade]
            ?? Double(decade.decade % 360) / 360
    }

    /// « 80 » avant 2000, « 2010 » après : « les années 10 » ne se dit pas.
    private var year: String { decade.decade < 2000 ? String(decade.decade % 100) : String(decade.decade) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.7),
                                        Color(hue: hue, saturation: 0.7, brightness: 0.28)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Vinyl(label: decade.albums.first?.cover, side: width * 0.8)
                    .offset(x: width * 0.42, y: width * 0.36)
                VStack(alignment: .leading, spacing: 0) {
                    Text("LES ANNÉES")
                        .font(.system(size: width * 0.07, weight: .heavy))
                        .tracking(width * 0.012)
                        .opacity(0.8)
                    Text(year)
                        .font(.display(width * (year.count > 2 ? 0.26 : 0.4), relativeTo: .largeTitle))
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                }
                .foregroundStyle(.white)
                .padding(width * 0.08)
            }
            .frame(width: width, height: width)
            .clipShape(.rect(cornerRadius: 10))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Les années \(year)")
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: width)
        .foregroundStyle(.primary)
    }
}

/// Un disque vu de face : sillons, étiquette, trou central.
private struct Vinyl: View {
    let label: String?
    let side: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.06))
            ForEach(1 ..< 6, id: \.self) { ring in
                Circle().stroke(.white.opacity(0.07), lineWidth: 1).padding(side * (0.05 + 0.04 * CGFloat(ring)))
            }
            Cover(path: label, size: side * 0.38, radius: side * 0.19)
            Circle().fill(Color(white: 0.06)).frame(width: side * 0.04)
        }
        .frame(width: side, height: side)
        .shadow(color: .black.opacity(0.45), radius: 10, x: -4, y: -2)
    }
}

/// L'emblème d'un style. La liste vient du serveur : on cherche un mot connu, du plus précis au plus large.
enum GenreEmblem {
    // ponytail: recherche par sous-chaîne (« ska » trouverait « skate ») ; des mots entiers si ça arrive.
    private static let emblems: [(String, String)] = [
        ("pop punk", "🛹"), ("dance punk", "🕺"), ("synth funk", "🕺"), ("synth pop", "🎹"), ("electropop", "🎛️"),
        ("dance pop", "💃"), ("indie pop", "🌈"), ("britpop", "💂"), ("indie rock", "📼"), ("garage rock", "🔧"),
        ("blues rock", "🥃"), ("hard rock", "🤘"), ("alternative rock", "🪐"), ("pop rock", "🎙️"),
        ("progressive", "🌀"), ("psychedelic", "🍄"), ("yacht", "⛵️"), ("disco", "🪩"), ("screamo", "😱"),
        ("emo", "🖤"), ("metal", "🤘"), ("punk", "🧷"), ("hip hop", "🎤"), ("rap", "🎤"), ("r&b", "💜"),
        ("soul", "💜"), ("funk", "🕺"), ("jazz", "🎷"), ("blues", "🌧️"), ("reggae", "🌴"), ("ska", "🏁"),
        ("folk", "🪕"), ("country", "🤠"), ("classical", "🎻"), ("opera", "🎭"), ("ambient", "🌌"),
        ("techno", "🤖"), ("house", "🏠"), ("drum and bass", "🥁"), ("trance", "🔮"), ("dubstep", "🔊"),
        ("electronic", "⚡️"), ("dance", "💃"), ("latin", "🌶️"), ("world", "🌍"), ("soundtrack", "🎬"),
        ("lo fi", "📻"), ("rock", "🎸"), ("pop", "🍭"), ("indie", "📼"), ("alternative", "🪐"),
    ]

    static func emoji(for genre: String) -> String {
        let name = genre.lowercased().replacingOccurrences(of: "-", with: " ")
        return emblems.first { name.contains($0.0) }?.1 ?? "💿"
    }
}

/// Un style : le mix de ce qu'on en a, puis ses albums et artistes, chez soi et ailleurs.
struct GenreView: View {
    let name: String

    @Environment(\.client) private var client
    @Environment(Player.self) private var player
    @State private var mixing = false

    var body: some View {
        Loaded(load: { try await client.genre(name) }, shelves: true) { genre in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    let owned = (genre.library?.albums ?? []).filter { $0.mbid != nil }.map(\.album)
                    Button {
                        mixing = true
                        Task {
                            await player.shuffle(albums: owned.shuffled(), using: client)
                            mixing = false
                        }
                    } label: {
                        Label(mixing ? "On sort les disques…" : "Lire le mix \(name)", systemImage: "shuffle")
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(Color.base100)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(owned.isEmpty || mixing)
                    .padding(.horizontal)

                    albums("Dans ta discothèque", genre.library?.albums)
                    artists("Tes artistes", genre.library?.artists)
                    albums("Populaire", genre.popular?.albums)
                    artists("À découvrir", genre.popular?.artists)
                }
                .padding(.vertical)
            }
        }
        .platineBackground()
        .navigationTitle(name.capitalized)
    }

    @ViewBuilder
    private func albums(_ title: String, _ items: [HomeItem]?) -> some View {
        let items = (items ?? []).filter { $0.mbid != nil }
        if !items.isEmpty {
            Shelf(title) {
                ForEach(items) { item in
                    NavigationLink(value: item.album) { AlbumCard(album: item.album, width: 150, playable: item.inLibrary == true) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func artists(_ title: String, _ items: [HomeItem]?) -> some View {
        let items = (items ?? []).compactMap { item in item.artist.map { (item, $0) } }
        if !items.isEmpty {
            Shelf(title) {
                ForEach(items, id: \.1.id) { item, artist in
                    NavigationLink(value: artist) {
                        ArtistBubble(name: item.name, image: item.imageUrl ?? DroppedNeedle.artistImage(artist.id))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// L'exploration de la semaine de ListenBrainz. On joue ce qui est déjà dans
/// les bacs ; le reste s'ouvre pour être demandé au disquaire.
struct WeeklyView: View {
    let weekly: WeeklyExploration

    @Environment(\.client) private var client
    @Environment(Player.self) private var player
    @State private var resolving = false
    @State private var missing = false

    var body: some View {
        List {
            VStack(alignment: .leading, spacing: 8) {
                Text("Choisie pour toi chaque semaine par ListenBrainz.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button { playOwned() } label: {
                    Label(resolving ? "On cherche dans les bacs…" : "Lire ce qui est dans les bacs", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(Color.base100)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(resolving)
                if missing {
                    Text("Aucun de ces morceaux n'est encore dans ta discothèque.")
                        .font(.footnote).foregroundStyle(.yellow)
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            ForEach(Array(weekly.tracks.enumerated()), id: \.offset) { _, track in
                let row = AlbumRow(cover: track.coverUrl ?? DroppedNeedle.cover(nil, album: track.releaseGroupMbid),
                                   title: track.title, subtitle: "\(track.artistName) · \(track.albumName)") {
                    EmptyView()
                }
                if let album = track.releaseGroupMbid {
                    NavigationLink(value: LocalAlbum(musicbrainzId: album, name: track.albumName,
                                                     artistName: track.artistName, artistMbid: track.artistMbid,
                                                     year: nil, trackCount: nil, primaryFormat: nil,
                                                     coverUrl: track.coverUrl)) { row }
                        .listRowBackground(Color.clear)
                } else {
                    row
                }
            }
        }
        .listStyle(.plain)
        .platineBackground()
        .navigationTitle(weekly.title)
    }

    /// Chaque morceau est cherché dans son album local, par titre.
    private func playOwned() {
        resolving = true
        missing = false
        Task {
            let wanted = weekly.tracks
            let found = await withTaskGroup(of: (Int, [LocalTrack]).self) { group in
                for (index, track) in wanted.enumerated() {
                    guard let mbid = track.releaseGroupMbid else { continue }
                    group.addTask { (index, (try? await client.tracks(of: mbid)) ?? []) }
                }
                var results: [(Int, [LocalTrack])] = []
                for await result in group { results.append(result) }
                return results
            }
            resolving = false
            let tracks = found.sorted { $0.0 < $1.0 }.compactMap { index, local -> Track? in
                let want = wanted[index]
                guard let mbid = want.releaseGroupMbid,
                      let match = local.first(where: { $0.title.localizedCaseInsensitiveCompare(want.title) == .orderedSame })
                else { return nil }
                return match.track(in: LocalAlbum(musicbrainzId: mbid, name: want.albumName, artistName: want.artistName,
                                                  artistMbid: want.artistMbid, year: nil, trackCount: nil,
                                                  primaryFormat: nil, coverUrl: want.coverUrl))
            }
            if tracks.isEmpty { missing = true } else { player.play(tracks, using: client) }
        }
    }
}

/// Une section de recommandations en entier : albums en pochettes, artistes en médaillons.
struct DiscoverSectionView: View {
    let section: HomeSection

    var body: some View {
        ScrollView {
            // La radio du mix : on entre dans la page, puis on la lance.
            if section.type == "albums", !section.items.isEmpty {
                NavigationLink(value: Route("mix-radio-\(section.title)") {
                    RadioView(seedType: "items", items: section.items, title: section.title)
                }) {
                    Label("Radio de ce mix", systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .padding([.horizontal, .top])
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: section.type == "artists" ? 110 : 150), spacing: 16)], spacing: 20) {
                ForEach(section.items) { item in
                    if section.type == "artists", let artist = item.artist {
                        NavigationLink(value: artist) {
                            ArtistBubble(name: item.name, image: item.imageUrl ?? DroppedNeedle.artistImage(artist.id), size: 100)
                        }
                        .buttonStyle(.plain)
                    } else if item.mbid != nil {
                        NavigationLink(value: item.album) { AlbumCard(album: item.album, playable: item.inLibrary == true) }.buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
        .platineBackground()
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// « Pioche pour une playlist » : on choisit une playlist, le serveur propose des disques à partir d'elle.
struct PlaylistDiscoveryView: View {
    @Environment(\.client) private var client

    var body: some View {
        Loaded(load: { try await client.playlists().playlists }) { playlists in
            if playlists.isEmpty {
                ContentUnavailableView("Aucune playlist", systemImage: "music.note.list",
                                       description: Text("Crée d'abord une playlist : les suggestions partent d'elle."))
            } else {
                List(playlists) { playlist in
                    NavigationLink(value: Route("playlist-picks-\(playlist.id)") { PlaylistPicksView(playlist: playlist) }) {
                        HStack(spacing: 12) {
                            Cover(path: playlist.covers.first ?? nil, size: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name).lineLimit(1)
                                if let count = playlist.trackCount {
                                    Text("\(count) plages").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .macRowSpacing()
                }
                .listStyle(.plain)
            }
        }
        .platineBackground()
        .navigationTitle("Pioche pour une playlist")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PlaylistPicksView: View {
    let playlist: PlaylistSummary

    @Environment(\.client) private var client

    var body: some View {
        Loaded(load: { try await client.suggestions(for: playlist.id).suggestions }) { section in
            DiscoverSectionView(section: HomeSection(title: "D'après \(playlist.name)", type: section.type, items: section.items))
        }
        .platineBackground()
    }
}

extension PlaylistSummary {
    var source: PlaySource {
        PlaySource(kind: .playlist, id: id, title: name, subtitle: ownerName.map { "De \($0)" } ?? "Playlist",
                   covers: covers.compactMap(\.self))
    }
}

extension PlaySource {
    /// Ses plages, pour la relancer d'un clic.
    func tracks(using client: DroppedNeedle) async -> [Track] {
        switch kind {
        case .album:
            await LocalAlbum(musicbrainzId: id, name: title, artistName: subtitle, artistMbid: nil, year: nil,
                             trackCount: nil, primaryFormat: nil, coverUrl: covers.first).tracks(using: client)
        case .playlist:
            ((try? await client.playlist(id).tracks) ?? []).compactMap(\.track)
        case .radio:
            await RadioSeed(seedType: seedType ?? "", seedID: id, title: title).tracks(using: client)
        }
    }

    /// La page de l'album ou de la playlist, pour y revenir depuis « Dernières écoutes ».
    var route: Route {
        switch kind {
        case .album:
            Route("album-\(id)") {
                AlbumView(album: LocalAlbum(musicbrainzId: id, name: title, artistName: subtitle, artistMbid: nil, year: nil,
                                            trackCount: nil, primaryFormat: nil, coverUrl: covers.first))
            }
        case .playlist:
            Route("playlist-\(id)") {
                PlaylistView(summary: PlaylistSummary(id: id, name: title, trackCount: nil, coverUrls: covers,
                                                      customCoverUrl: nil, isOwner: nil, ownerName: nil))
            }
        case .radio:
            Route("radio-\(id)") { RadioView(seedType: seedType ?? "", seedID: id, title: title) }
        }
    }
}

/// Un album ou une playlist écoutés récemment, à la taille des plages du même rayon.
struct SourceCard: View {
    let source: PlaySource
    var width: CGFloat = 150

    @Environment(Player.self) private var player
    @Environment(\.client) private var client

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if source.kind != .album {
                    PlaylistArtwork(covers: source.covers)
                } else {
                    Cover(path: source.covers.first, size: width, radius: 8)
                }
            }
            .frame(width: width, height: width)
            .hoverPlay("Lire \(source.title)", active: source.same(as: player.currentSource)) {
                let tracks = await source.tracks(using: client)
                if !tracks.isEmpty { player.play(tracks, source: source, using: client) }
            }
            Text(source.title).font(.subheadline.weight(.medium)).lineLimit(1)
            Label(source.subtitle, systemImage: [.playlist: "music.note.list", .radio: "dot.radiowaves.left.and.right"][source.kind] ?? "square.stack")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: width)
        .foregroundStyle(.primary)
    }
}
