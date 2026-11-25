import SwiftUI

/// Un artiste, comme dans Musique : grande photo, lecture aléatoire de ce qu'on
/// a de lui, puis ses morceaux phares, ses disques, ses concerts et ses proches.
struct ArtistView: View {
    let artist: ArtistRef

    @Environment(\.client) private var client
    @Environment(Player.self) private var player
    @State private var info: Artist?
    @State private var infoLoaded = false
    // nil tant que ce n'est pas arrivé : la page montre un squelette à la place.
    @State private var discography: Discography?
    /// Les plus gros morceaux qu'on a de l'artiste, une fois chacun.
    @State private var thisIs: [Track]?
    @State private var topSongs: [TopSong]?
    @State private var similar: [SimilarArtist]?
    @State private var concerts: Concerts?
    /// La biographie : nil tant qu'elle n'est pas arrivée.
    @State private var bio: String??
    @State private var topAlbum: TopAlbum?
    @State private var followed = false
    @State private var shuffling = false
    @State private var expandsBio = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                if let topSongs, !topSongs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Morceaux phares").font(.display(20, relativeTo: .title3))
                        ForEach(Array(topSongs.prefix(5).enumerated()), id: \.offset) { index, song in
                            if let album = song.releaseGroupMbid {
                                NavigationLink(value: LocalAlbum(
                                    musicbrainzId: album, name: song.releaseName ?? song.title,
                                    artistName: artist.name, artistMbid: artist.id, year: nil,
                                    trackCount: nil, primaryFormat: nil, coverUrl: nil
                                )) { topSong(song, index: index) }
                                    .buttonStyle(.plain)
                            } else {
                                topSong(song, index: index)
                            }
                        }
                    }
                    .padding(.horizontal)
                }

                if topSongs == nil { SkeletonTrackList(title: "Morceaux phares") }

                if let discography {
                    releases("Albums", discography.albums)
                    releases("EP", discography.eps)
                    releases("Singles", discography.singles)
                } else {
                    SkeletonShelf(title: "Albums")
                    SkeletonShelf(title: "Singles")
                }

                // En dessous de trois morceaux, ce n'est pas une playlist.
                if thisIs == nil, !owned.isEmpty {
                    SkeletonShelf(title: "Playlist", count: 1, side: 170)
                }
                if let thisIs, thisIs.count >= 3 {
                    Shelf("Playlist") {
                        NavigationLink(value: Route("this-is-\(artist.id)") {
                            ThisIsView(artist: artist, image: artistImage, tracks: thisIs)
                        }) {
                            VStack(alignment: .leading, spacing: 6) {
                                ThisIsCover(name: artist.name, image: artistImage, side: 170)
                                Text("\(thisIs.count) incontournables").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                concertsSection

                if similar == nil { SkeletonShelf(title: "Dans le même bac", side: 110, round: true) }
                if let similar, !similar.isEmpty {
                    Shelf("Dans le même bac") {
                        ForEach(similar) { other in
                            NavigationLink(value: ArtistRef(id: other.musicbrainzId, name: other.name)) {
                                ArtistBubble(name: other.name,
                                             image: other.imageUrl ?? DroppedNeedle.artistImage(other.musicbrainzId))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                about
                photos
                links
            }
            .padding(.bottom, 32)
        }
        .defaultScrollAnchor(DebugScreen.anchor)
        .ignoresSafeArea(edges: .top)
        .platineBackground()
        .navigationBarTitleDisplayMode(.inline)
        .heroBar(title: artist.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route("radio-artist-\(artist.id)") {
                    RadioView(seedType: "artist", seedID: artist.id, title: artist.name)
                }) {
                    Label("Radio", systemImage: "dot.radiowaves.left.and.right")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(followed ? "Suivi" : "Suivre", systemImage: followed ? "checkmark" : "plus") {
                    toggleFollow()
                }
            }
        }
        .task { await load() }
    }

    private var artistImage: String {
        info?.thumbUrl ?? info?.image ?? DroppedNeedle.artistImage(artist.id)
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            // Pas d'image avant la fiche : elle en choisit souvent une autre, qui remplacerait la première.
            Cover(path: infoLoaded ? info?.fanartUrl ?? artistImage : nil, size: nil, radius: 0, fills: true)
                .pulsing(!infoLoaded)
                .frame(maxWidth: .infinity)
                .frame(height: 380)
                .clipped()
            LinearGradient(colors: [.clear, .base100], startPoint: .center, endPoint: .bottom)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(artist.name).font(.display(34, relativeTo: .largeTitle)).lineLimit(2)
                    if let tags = info?.tags, !tags.isEmpty {
                        Text(tags.prefix(3).joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
                    } else if !infoLoaded {
                        SkeletonLine(width: 180, height: 12).padding(.vertical, 3)
                    }
                }
                Spacer()
                Button { shuffleLibrary() } label: {
                    Group {
                        if shuffling { ProgressView().tint(Color.base100) } else { Image(systemName: "play.fill") }
                    }
                    .font(.title2)
                    .frame(width: 56, height: 56)
                    .background(Color.sage, in: .circle)
                    .foregroundStyle(Color.base100)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Lecture aléatoire de sa discothèque")
                .disabled(owned.isEmpty)
            }
            .padding()
        }
        .frame(height: 380)
    }

    // MARK: Concerts

    /// Le serveur ne cherche les dates que des artistes suivis, autour de ses villes : sans date,
    /// l'encart dit quoi faire. Rien du tout si aucune source de concerts n'est branchée.
    @ViewBuilder
    private var concertsSection: some View {
        if let concerts, concerts.configured {
            let dates = concerts.items.filter { $0.artistMbid == artist.id }
            VStack(alignment: .leading, spacing: 12) {
                Text("Concerts à venir").font(.display(20, relativeTo: .title3))
                if !dates.isEmpty {
                    ForEach(dates) { ConcertRow(concert: $0, showsArtist: false) }
                } else if followed {
                    Text("Aucune date en vue autour de tes villes.").foregroundStyle(.secondary)
                    NavigationLink(value: Route("cities") { CitiesView() }) {
                        Label("Mes villes", systemImage: "mappin.and.ellipse")
                    }
                    .buttonStyle(.glass)
                } else {
                    Text("Suis \(artist.name) pour voir ses dates autour de tes villes.").foregroundStyle(.secondary)
                    Button("Suivre", systemImage: "plus") { toggleFollow() }
                        .buttonStyle(.glass)
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: Bas de page

    /// La biographie et la fiche : origine, années, sorties, chiffres.
    @ViewBuilder
    private var about: some View {
        let facts = self.facts
        if bio == nil || !(bio??.isEmpty ?? true) || !facts.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Notes de pochette").font(.display(20, relativeTo: .title3))
                if bio == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        SkeletonLine()
                        SkeletonLine()
                        SkeletonLine(width: 220)
                    }
                } else if let text = bio ?? nil, !text.isEmpty {
                    Text(text).font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(expandsBio ? nil : 4)
                    Button(expandsBio ? "Moins" : "Plus") { expandsBio.toggle() }.font(.subheadline)
                }
                if !facts.isEmpty { FactsTable(facts: facts) }
            }
            .padding(.horizontal)
        }
    }

    private var facts: [(label: String, value: String)] {
        var facts: [(label: String, value: String)] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { facts.append((label, value)) }
        }
        let group = info?.type != "Person"
        add("Type", info?.type.map { ["Group": "Groupe", "Person": "Artiste solo", "Orchestra": "Orchestre", "Choir": "Chœur"][$0] ?? $0 })
        add("Origine", info?.country.flatMap { Locale.current.localizedString(forRegionCode: $0) })
        let begin = info?.lifeSpan?.begin.map { String($0.prefix(4)) }
        let end = info?.lifeSpan?.end.map { String($0.prefix(4)) }
        if group {
            add("En activité", begin.map { "\($0) – \(end ?? "aujourd'hui")" })
        } else {
            add("Naissance", begin)
            add("Décès", end)
        }
        if let discography {
            let counts = [(discography.albums.count, "album"), (discography.eps.count, "EP"), (discography.singles.count, "single")]
                .filter { $0.0 > 0 }
                .map { count, name in "\(count) \(name)\(count > 1 && name != "EP" ? "s" : "")" }
            add("Discographie", counts.joined(separator: " · "))
            if !owned.isEmpty { add("Dans tes bacs", "\(owned.count) disque\(owned.count > 1 ? "s" : "")") }
        }
        add("Album le plus écouté", topAlbum.map { album in
            album.title + (album.listenCount.map { " · \($0.formatted(.number.notation(.compactName))) écoutes" } ?? "")
        })
        add("Titre le plus écouté", topSongs?.first.map { song in
            song.title + (song.listenCount.map { " · \($0.formatted(.number.notation(.compactName))) écoutes" } ?? "")
        })
        add("Styles", info?.tags?.prefix(6).joined(separator: ", "))
        let aliases = (info?.aliases ?? []).filter { $0 != artist.name }
        add("Aussi connu sous", aliases.prefix(4).joined(separator: ", "))
        return facts
    }

    /// Ses autres photos, quand il y en a.
    @ViewBuilder
    private var photos: some View {
        let images = [info?.fanartUrl2, info?.fanartUrl3, info?.fanartUrl4, info?.wideThumbUrl].compactMap(\.self)
        if !images.isEmpty {
            Shelf("Photos") {
                ForEach(images, id: \.self) { image in
                    Cover(path: image, size: 200, radius: 10)
                }
            }
        }
    }

    /// Ses liens officiels, ouverts dans le navigateur.
    @ViewBuilder
    private var links: some View {
        let all = (info?.externalLinks ?? []).compactMap { link -> (label: String, url: URL)? in
            // Seulement du web : ces adresses viennent de MusicBrainz, pas de l'app. Pas de boutique postale.
            guard let label = link.label, link.type?.contains("mail-order") != true,
                  let url = URL(string: link.url), url.scheme == "https" || url.scheme == "http"
            else { return nil }
            return (label, url)
        }
        // Le site officiel d'abord.
        let links = all.filter { $0.label == "Official Website" } + all.filter { $0.label != "Official Website" }
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Liens").font(.display(20, relativeTo: .title3)).padding(.horizontal)
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(links, id: \.url) { link in
                            Link(destination: link.url) {
                                Label(link.label == "Official Website" ? "Site officiel" : link.label,
                                      systemImage: link.label == "Official Website" ? "globe" : "arrow.up.right")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.glass)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    // MARK: Morceaux

    private func topSong(_ song: TopSong, index: Int) -> some View {
        HStack(spacing: 12) {
            Text(String(index + 1)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).lineLimit(1)
                if let release = song.releaseName {
                    Text(release).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let listens = song.listenCount, listens > 0 {
                let count = listens.formatted(.number.notation(.compactName))
                Label(count, systemImage: "headphones")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(count) écoutes")
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    @ViewBuilder
    private func releases(_ title: String, _ items: [Release]) -> some View {
        if !items.isEmpty {
            Shelf(title) {
                ForEach(items, id: \.id) { release in
                    let album = release.album(by: artist)
                    NavigationLink(value: album) {
                        VStack(alignment: .leading, spacing: 4) {
                            AlbumCard(album: album, width: 150, playable: release.inLibrary == true)
                            HStack(spacing: 6) {
                                if let year = release.year { Text(String(year)) }
                                if release.inLibrary == true { Pill(text: "Dans les bacs") }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Chaque partie s'affiche dès qu'elle arrive : une réponse lente ne retient pas les autres.
    private func load() async {
        #if DEBUG
        if DebugScreen.slow { try? await Task.sleep(for: .seconds(30)) }
        #endif
        async let info: Void = loadInfo()
        async let similar: Void = loadSimilar()
        async let concerts: Void = loadConcerts()
        async let bio: Void = loadBio()
        async let topAlbum: Void = loadTopAlbum()
        async let songs: Void = loadSongs()
        async let releases: Void = loadReleases()
        _ = await (info, similar, concerts, bio, topAlbum, songs, releases)
        thisIs = await incontournables()
    }

    private func loadInfo() async {
        info = try? await client.artist(artist.id)
        followed = info?.followed ?? false
        infoLoaded = true
    }

    private func loadSimilar() async {
        similar = (try? await client.similarArtists(to: artist.id))?.similarArtists ?? []
    }

    private func loadConcerts() async {
        concerts = try? await client.concerts()
    }

    private func loadBio() async {
        bio = .some((try? await client.extended(artist.id))?.description)
    }

    private func loadTopAlbum() async {
        topAlbum = (try? await client.topAlbums(of: artist.id))?.albums.first
    }

    private func loadSongs() async {
        topSongs = (try? await client.topSongs(of: artist.id))?.songs ?? []
    }

    private func loadReleases() async {
        discography = (try? await client.releases(of: artist.id)).map(Discography.init) ?? Discography()
    }

    /// Les disques de l'artiste qu'on a en local.
    private var owned: [Release] {
        guard let discography else { return [] }
        return (discography.albums + discography.eps + discography.singles).filter { $0.inLibrary == true }
    }

    /// « This Is » : ses morceaux les plus écoutés qu'on a, dans l'ordre de popularité, une seule
    /// fois chacun même s'ils sont sur plusieurs disques.
    private func incontournables() async -> [Track] {
        guard let topSongs, !topSongs.isEmpty, !owned.isEmpty else { return [] }
        var local: [Track] = []
        for release in owned.prefix(12) {
            let album = release.album(by: artist)
            if let tracks = try? await client.tracks(of: album.musicbrainzId) {
                local += tracks.map { $0.track(in: album) }
            }
        }
        var seen = Set<String>()
        return topSongs.compactMap { song in
            let key = Discography.titleKey(song.title)
            guard !seen.contains(key), let track = local.first(where: { Discography.titleKey($0.title) == key })
            else { return nil }
            seen.insert(key)
            return track
        }
    }

    private func toggleFollow() {
        let wanted = !followed
        followed = wanted
        Task {
            if let status = try? await client.follow(artist.id, wanted) { followed = status.followed } else { followed = !wanted }
            await loadConcerts()
        }
    }

    /// Ce qu'on a de l'artiste en local, mélangé : quelques albums suffisent.
    private func shuffleLibrary() {
        let owned = owned.prefix(6)
        shuffling = true
        Task {
            var tracks: [Track] = []
            for release in owned {
                let album = release.album(by: artist)
                if let local = try? await client.tracks(of: album.musicbrainzId) {
                    tracks += local.map { $0.track(in: album) }
                }
            }
            shuffling = false
            if !tracks.isEmpty { player.play(tracks.shuffled(), using: client) }
        }
    }
}

/// La couverture de « This Is » : la photo de l'artiste passée au vert DroppedNeedle, et le titre.
struct ThisIsCover: View {
    let name: String
    let image: String
    let side: CGFloat

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Cover(path: image, size: side, radius: 0)
                .saturation(0)
                .colorMultiply(.sage)
            LinearGradient(colors: [.clear, .base100.opacity(0.9)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: side * 0.01) {
                Text("THIS IS")
                    .font(.system(size: side * 0.075, weight: .bold))
                    .tracking(side * 0.012)
                    .foregroundStyle(Color.sage)
                Text(name)
                    .font(.display(side * 0.15, relativeTo: .title))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
            }
            .padding(side * 0.07)
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: side * 0.06))
    }
}

/// La page de « This Is » : on y entre d'abord, on lance la lecture ensuite.
struct ThisIsView: View {
    let artist: ArtistRef
    let image: String
    let tracks: [Track]

    @Environment(\.client) private var client
    @Environment(Player.self) private var player

    var body: some View {
        List {
            VStack(spacing: 16) {
                ThisIsCover(name: artist.name, image: image, side: 260)
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
                Text("\(tracks.count) incontournables").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Button { player.play(tracks.shuffled(), using: client) } label: {
                        Image(systemName: "shuffle").frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Aléatoire")

                    Button { player.play(tracks, using: client) } label: {
                        Label("Lecture", systemImage: "play.fill")
                            .font(.headline)
                            .frame(width: 140, height: 30)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.sage)
                    .foregroundStyle(Color.base100)
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(track: track) { player.play(tracks, from: index, using: client) }
            }
        }
        .listStyle(.plain)
        .platineBackground()
        .navigationTitle("This Is \(artist.name)")
        .navigationBarTitleDisplayMode(.inline)
    }
}
