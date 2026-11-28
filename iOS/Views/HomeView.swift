import SwiftUI

/// L'accueil du web (« Good evening ») rangé comme celui de Musique : ce
/// qu'on vient d'écouter, le bac, les mixes faits pour soi, puis le reste.
struct HomeView: View {
    /// L'accueil : ce qu'on a. Découvrir : ce qui est à découvrir et à demander.
    enum Page { case home, discover }
    var page = Page.home

    @Environment(\.client) private var client
    @Environment(Session.self) private var session
    @Environment(Player.self) private var player
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.sidebarOpen) private var sidebarOpen
    /// Les disques refusés d'un « Pas pour moi », retirés sans attendre le serveur.
    @State private var ignored: Set<String> = []
    @State private var showsSettings = false
    @State private var mixing: String?
    /// Les nouvelles sorties des artistes suivis pas encore vues.
    @State private var unseen = 0
    /// Compte les fins de calcul des recommandations : chacune recharge l'accueil.
    @State private var reloads = 0
    /// Les dernières recommandations reçues : une réponse vide du serveur ne les efface pas.
    @State private var lastDiscover: Discover?

    var body: some View {
        NavigationStack {
            Loaded(load: load, reloadKey: reloads, shelves: true) { home in
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        #if targetEnvironment(macCatalyst)
                        // Tout en haut, comme le titre de Musique : on remonte sous la bande de la fenêtre.
                        Text(title).font(.display(30, relativeTo: .largeTitle)).padding(.horizontal).padding(.top, -34)
                        #else
                        // Le titre et ses boutons sur une ligne, juste sous l'heure.
                        PageTitle(title) { headerButtons }.padding(.horizontal).padding(.bottom, -12)
                        #endif
                        if page == .home {
                            if !player.history.isEmpty {
                                Shelf("Dernières écoutes") {
                                    ForEach(player.history) { listen in
                                        if let source = listen.source {
                                            NavigationLink(value: source.route) { SourceCard(source: source) }
                                                .buttonStyle(.plain)
                                        } else {
                                            // Les plages lancées seules se suivent, comme avant.
                                            let singles = player.history.filter { $0.source == nil }.map(\.track)
                                            let start = { player.play(singles, from: singles.firstIndex(of: listen.track) ?? 0, using: client) }
                                            Button(action: start) { TrackCard(track: listen.track, play: start) }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }

                            if !home.crate.isEmpty { crate(home.crate) }
                            mixes(home)
                            if let discover = home.discover { radios(discover) }

                            if !home.recent.isEmpty {
                                Shelf("Fraîchement pressés") {
                                    ForEach(home.recent) { album in
                                        NavigationLink(value: album) { AlbumCard(album: album, width: 150) }
                                            .buttonStyle(.plain)
                                    }
                                }
                            }
                            section("À redécouvrir", home.discover?.rediscover)
                            if let feed = home.feed {
                                section("Tes albums phares", feed.yourTopAlbums, chart: .yourTop)
                                section("Tes artistes favoris", feed.favoriteArtists)
                            }
                        } else {
                            recommendations(home)

                            if let feed = home.feed {
                                section("Populaire en ce moment", feed.popularAlbums, chart: .popular)
                                section("Artistes tendance", feed.trendingArtists, chart: .trending)
                                section("Nouveautés", feed.freshReleases)
                                section("Pour toi", feed.recommendedArtists)
                            }

                            moreToExplore(home)

                            if !home.concerts.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text("Concerts à venir").font(.display(20, relativeTo: .title3))
                                        Spacer()
                                        NavigationLink("Tout voir", value: Route("concerts") { ConcertsView() })
                                            .font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    ForEach(home.concerts.prefix(3)) { ConcertRow(concert: $0) }
                                }
                                .padding(.horizontal)
                            }

                            NavigationLink(value: Route("suggestions") { SuggestionQueueView() }) {
                                Label("Fouiller chez le disquaire", systemImage: "sparkles")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                            .controlSize(.large)
                            .padding(.horizontal)
                        }
                    }
                    .padding(.vertical)
                }
            }
                .defaultScrollAnchor(DebugScreen.anchor)
            .pageBackground()
            #if targetEnvironment(macCatalyst)
            // Sur Mac, le bonjour défile avec la page : la barre de l'accueil ne se voit plus. Sans elle,
            // macOS mettrait la sienne ; les pages poussées gardent leur titre.
            .navigationTitle(title)
            .toolbar(removing: .title)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .scrollEdgeEffectHidden(true, for: .top)
            #else
            .underEmptyBar()
            .titleAfterHeader(title, after: 60)
            #endif
            .platineDestinations(ownHeader: true)
            .navigationDestination(item: Binding(get: { PlayerNavigation.shared.target },
                                                 set: { PlayerNavigation.shared.target = $0 })) { $0.page }
            .navigationDestination(for: String.self) { GenreView(name: $0) }
            .sheet(isPresented: $showsSettings) { SettingsView() }
            .onAppear { Task { unseen = (try? await client.unseenReleases().count) ?? 0 } }
        }
    }

    // MARK: Sections

    /// Les mixes faits pour soi : la playlist de la semaine, ses styles, ses décennies.
    @ViewBuilder
    private func mixes(_ home: Content) -> some View {
        let genres = home.feed?.topGenres?.items ?? []
        let made = home.discover?.dailyMixes ?? []
        if home.feed?.weeklyExploration != nil || !genres.isEmpty || !home.decades.isEmpty || !made.isEmpty {
            Shelf("Faits pour toi") {
                ForEach(Array(made.filter { !$0.items.isEmpty }.enumerated()), id: \.offset) { _, mix in
                    NavigationLink(value: Route("mix-\(mix.title)") { DiscoverSectionView(section: mix) }) {
                        DailyMixCard(mix: mix)
                    }
                    .buttonStyle(.plain)
                }
                if let weekly = home.feed?.weeklyExploration, !weekly.tracks.isEmpty {
                    NavigationLink(value: Route("weekly-\(weekly.playlistDate)") { WeeklyView(weekly: weekly) }) {
                        MixCard(title: "Exploration de la semaine", subtitle: weekly.playlistDate,
                                covers: weekly.tracks.prefix(4).map {
                                    $0.coverUrl ?? DroppedNeedle.cover(nil, album: $0.releaseGroupMbid)
                                })
                    }
                    .buttonStyle(.plain)
                }
                ForEach(genres.prefix(6)) { genre in
                    NavigationLink(value: genre.name) {
                        MixCard(title: "Mix \(genre.name)", subtitle: "Tes disques de ce style", covers: [], genre: genre.name)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(home.decades.filter { !$0.albums.isEmpty }) { decade in
                    Button {
                        mixing = decade.label
                        Task {
                            await player.shuffle(albums: decade.albums.shuffled(), using: client)
                            mixing = nil
                        }
                    } label: {
                        DecadeCard(decade: decade,
                                   subtitle: mixing == decade.label ? "On sort les disques…" : "Mix de ta discothèque")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Les recommandations de la page Discover du web, rangées en rayons.
    @ViewBuilder
    private func recommendations(_ home: Content) -> some View {
        if let discover = home.discover {
            RecommendationsStatus(discover: discover) { ready in
                lastDiscover = ready
                reloads += 1
            }
            topPicks((discover.topPicks?.items ?? []).filter { !ignored.contains($0.id) })
            lounge(discover)
            NavigationLink(value: Route("playlist-discovery") { PlaylistDiscoveryView() }) {
                HStack(spacing: 14) {
                    Image(systemName: "wand.and.stars").font(.title2).foregroundStyle(Color.sage).frame(width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pioche pour une playlist").font(.headline)
                        Text("Des disques à découvrir à partir d'une de tes playlists.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .padding(14)
                .background(Color.base200, in: .rect(cornerRadius: 14))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            ForEach(discover.becauseYouListenTo ?? []) { because in
                section("Parce que tu écoutes \(because.seedArtist)", because.section)
            }
            section("Les essentiels qui te manquent", discover.missingEssentials)
            section("Artistes à découvrir", discover.artistsYouMightLike)
            section("Populaire dans tes styles", discover.popularInYourGenres)
            section("Du neuf chez tes artistes", discover.newFromFollowed)
            section("Anniversaires", discover.anniversaries)
        }
    }

    // MARK: Choisis pour toi

    /// Comme le web : le premier en vedette avec son score, deux autres à côté.
    @ViewBuilder
    private func topPicks(_ picks: [TopPick]) -> some View {
        if let featured = picks.first {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choisis pour toi").font(.display(20, relativeTo: .title3)).padding(.horizontal)
                featuredPick(featured).padding(.horizontal)
                let others = Array(picks.dropFirst().prefix(2))
                if !others.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(others) { pick in
                                NavigationLink(value: pick.album.album) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        AlbumCard(album: pick.album.album, width: 150, playable: pick.album.inLibrary == true)
                                        if let match = pick.matchPct { Pill(text: "\(match) % pour toi", color: .sky) }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
    }

    private func featuredPick(_ pick: TopPick) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            NavigationLink(value: pick.album.album) {
                HStack(spacing: 14) {
                    Cover(path: pick.album.artwork, size: 110, radius: 10)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pick.album.name).font(.headline).lineLimit(2)
                        Text(pick.album.artistName ?? "").font(.subheadline).foregroundStyle(.secondary).oneLine()
                        if let seed = pick.seedArtist {
                            Text("Parce que tu écoutes \(seed)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                    if let match = pick.matchPct {
                        ZStack {
                            Circle().stroke(.white.opacity(0.12), lineWidth: 4)
                            Circle().trim(from: 0, to: CGFloat(match) / 100)
                                .stroke(Color.sage, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text("\(match) %").font(.caption2.weight(.semibold).monospacedDigit())
                        }
                        .frame(width: 46, height: 46)
                        .accessibilityLabel("\(match) % pour toi")
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            HStack(spacing: 10) {
                if let mbid = pick.album.mbid {
                    NavigationLink(value: Route("album-radio-\(mbid)") {
                        RadioView(seedType: "album", seedID: mbid, title: pick.album.name)
                    }) {
                        Label("Radio", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .buttonStyle(.glass)
                }
                Button("Pas pour moi", systemImage: "hand.thumbsdown") { ignore(pick) }
                    .buttonStyle(.glass)
            }
            .font(.subheadline)
        }
        .padding(14)
        .background(Color.base200, in: .rect(cornerRadius: 14))
    }

    /// Le disque disparaît tout de suite, et revient si le serveur a refusé.
    private func ignore(_ pick: TopPick) {
        guard let mbid = pick.album.mbid, let artist = pick.album.artistMbid else { return }
        withAnimation { _ = ignored.insert(pick.id) }
        Task {
            do {
                try await client.ignore(IgnoredRelease(releaseGroupMbid: mbid, artistMbid: artist,
                                                       releaseName: pick.album.name, artistName: pick.album.artistName ?? ""))
            } catch {
                withAnimation { _ = ignored.remove(pick.id) }
            }
        }
    }

    /// Le Salon d'écoute du web : ce qu'écoutent les gens qui te ressemblent, et la suite des choix.
    @ViewBuilder
    private func lounge(_ discover: Discover) -> some View {
        let picks = (discover.topPicks?.items ?? []).dropFirst(3).filter { !ignored.contains($0.id) }.map(\.album)
        let albums = (discover.listenersLikeYou?.items ?? []) + picks
        if !albums.isEmpty {
            Shelf("Salon d'écoute") {
                ForEach(albums) { item in
                    NavigationLink(value: item.album) { AlbumCard(album: item.album, width: 150, playable: item.inLibrary == true) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    /// Les stations de radio : on entre dans la station, puis on la lance.
    @ViewBuilder
    private func radios(_ discover: Discover) -> some View {
        let stations = (discover.radioSections ?? []).filter { $0.radioSeedType != nil && $0.radioSeedId != nil }
        if !stations.isEmpty {
            Shelf("Stations de radio") {
                ForEach(stations, id: \.title) { station in
                    let name = station.title.replacingOccurrences(of: "Radio: ", with: "")
                    let source = PlaySource(kind: .radio, id: station.radioSeedId ?? name, title: name, subtitle: "Station de radio",
                                            covers: station.items.prefix(4).compactMap(\.artwork), seedType: station.radioSeedType)
                    NavigationLink(value: Route("radio-\(station.title)") {
                        RadioView(seedType: station.radioSeedType ?? "", seedID: station.radioSeedId, title: name)
                    }) {
                        MixCard(title: name, subtitle: "Station de radio", covers: station.items.prefix(4).map(\.artwork))
                            .hoverPlay("Lancer la radio \(name)", active: source.same(as: player.currentSource),
                                       alignment: .topLeading) {
                                let tracks = await source.tracks(using: client)
                                if !tracks.isEmpty { player.play(tracks, source: source, using: client) }
                            }
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .font(.caption.weight(.semibold))
                                    .padding(7)
                                    .glassEffect(.regular, in: .circle)
                                    .padding(8)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Genres et tendances

    @ViewBuilder
    private func moreToExplore(_ home: Content) -> some View {
        if let discover = home.discover {
            if let genres = discover.unexploredGenres?.items, !genres.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Genres à explorer").font(.display(20, relativeTo: .title3)).padding(.horizontal)
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(genres) { genre in
                                NavigationLink(genre.name, value: genre.name).buttonStyle(.glass)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            if let genres = discover.genreList?.items, !genres.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Parcourir par genre").font(.display(20, relativeTo: .title3)).padding(.horizontal)
                    ScrollView(.horizontal) {
                        LazyHGrid(rows: Array(repeating: GridItem(.fixed(180), spacing: 12), count: 2), spacing: 12) {
                            ForEach(genres) { genre in
                                NavigationLink(value: genre.name) {
                                    MixCard(title: genre.name.capitalized,
                                            subtitle: genre.listenCount.map { "\($0.formatted(.number.notation(.compactName))) écoutes" } ?? " ",
                                            covers: [],
                                            width: 150,
                                            genre: genre.name)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            section("Tendances mondiales", discover.globallyTrending)
        }
    }

    /// iPad et Mac : les rayons s'étalent en colonnes, comme Musique sur grand écran.
    private var wide: Bool { sizeClass == .regular }

    private func crate(_ items: [CrateTrack]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dans le bac").font(.display(20, relativeTo: .title3)).padding(.horizontal)
            if wide {
                // Comme « Best New Songs » de Musique sur grand écran : des colonnes de quatre plages.
                ScrollView(.horizontal) {
                    LazyHGrid(rows: Array(repeating: GridItem(.fixed(56), spacing: 0), count: 4), spacing: 24) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            crateRow(items, index)
                                .containerRelativeFrame(.horizontal, count: 3, spacing: 24)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .contentMargins(.horizontal, 16, for: .scrollContent)
            } else {
                ForEach(Array(items.prefix(6).enumerated()), id: \.element.id) { index, _ in
                    crateRow(items, index)
                }
                .padding(.horizontal)
            }
        }
    }

    private func crateRow(_ items: [CrateTrack], _ index: Int) -> some View {
        TrackRow(track: items[index].track) {
            player.play(items.map(\.track), from: index, using: client)
        } accessory: {
            if let reason = items[index].reason { ReasonPill(reason: reason) }
        }
    }

    /// Une section de `/home` : des albums en pochettes, des artistes en médaillons.
    @ViewBuilder
    private func section(_ title: String, _ section: HomeSection?, chart: Chart? = nil) -> some View {
        if let section, !section.items.isEmpty {
            switch section.type {
            case "artists":
                Shelf(title: title) {
                    ForEach(section.items) { item in
                        if let artist = item.artist {
                            NavigationLink(value: artist) {
                                ArtistBubble(name: item.name, image: item.imageUrl ?? DroppedNeedle.artistImage(artist.id))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } more: {
                    seeAll(chart, title)
                }
            case "albums":
                Shelf(title: title) {
                    ForEach(section.items.filter { $0.mbid != nil }) { item in
                        NavigationLink(value: item.album) {
                            VStack(alignment: .leading, spacing: 6) {
                                AlbumCard(album: item.album, width: 150, playable: item.inLibrary == true)
                                if item.inLibrary == true {
                                    Pill(text: "Dans les bacs")
                                } else if item.requested == true {
                                    Pill(text: "Demandé", color: .sky)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } more: {
                    seeAll(chart, title)
                }
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func seeAll(_ chart: Chart?, _ title: String) -> some View {
        if let chart {
            NavigationLink("Tout voir", value: Route("chart-\(chart.rawValue)") { ChartView(chart: chart, title: title) })
        }
    }

    // MARK: Chargement

    private var title: String { page == .discover ? "Découvrir" : greeting }

    /// Les demandes sur Découvrir ; le compte, les suivis et les téléchargements derrière l'avatar sur
    /// l'accueil. Quand la barre latérale est ouverte (iPad), ils y sont déjà.
    @ViewBuilder
    private var headerButtons: some View {
        if page == .discover {
            NavigationLink(value: Route("requests") { RequestsView() }) { HeaderIcon("tray.and.arrow.down") }
                .buttonStyle(.plain)
                .accessibilityLabel("Demandes")
        } else if !sidebarOpen {
            Menu {
                Button("Compte", systemImage: "person.crop.circle") { showsSettings = true }
                NavigationLink(value: Route("following") { FollowingView() }) {
                    Label(unseen > 0 ? "Suivis · \(unseen) nouveautés" : "Suivis", systemImage: "heart")
                }
                NavigationLink(value: Route("downloads") { DownloadsView() }) { Label("Téléchargements", systemImage: "arrow.down.circle") }
            } label: {
                HeaderIcon("person.crop.circle")
                    .overlay(alignment: .topTrailing) {
                        if unseen > 0 { Circle().fill(Color.sage).frame(width: 9, height: 9).offset(x: -4, y: 4) }
                    }
            }
            .accessibilityLabel(unseen > 0 ? "Compte et suivis, \(unseen) nouveautés" : "Compte, suivis et téléchargements")
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5 ..< 12: "Bonjour"
        case 12 ..< 18: "Bon après-midi"
        default: "Bonsoir"
        }
    }

    private struct Content {
        let recent: [LocalAlbum]
        let crate: [CrateTrack]
        let decades: [Decade]
        let feed: Home?
        let discover: Discover?
        let concerts: [Concert]
    }

    /// Seuls les disques locaux sont indispensables ; le reste dépend des
    /// services branchés (ListenBrainz, Last.fm, Ticketmaster) et peut manquer.
    private func load() async throws -> Content {
        async let recent = client.recentAlbums()
        async let crate = client.crate()
        async let decades = try? client.decades()
        async let feed = try? client.home()
        async let concerts = try? client.concerts()
        async let discover = try? client.discover()
        var latest = await discover
        if latest?.generatedAt != nil { lastDiscover = latest } else { latest = lastDiscover ?? latest }
        return try await Content(recent: recent, crate: crate.items, decades: decades?.items ?? [], feed: feed, discover: latest,
                                 concerts: concerts?.items ?? [])
    }
}

/// Où en est le calcul des recommandations : on le lance, on le voit tourner, et l'accueil
/// se recharge à la fin.
private struct RecommendationsStatus: View {
    let discover: Discover
    let finished: (Discover) -> Void

    @Environment(\.client) private var client
    @State private var sending = false
    @State private var sent = false
    @State private var gaveUp = false
    @State private var failure: String?

    /// Le bandeau ne paraît que pour un calcul demandé, ou s'il n'y a encore rien à montrer.
    private var computing: Bool { !gaveUp && (sent || (discover.isPending && discover.isEmpty)) }

    var body: some View {
        Group {
            if sending || computing {
                HStack(spacing: 10) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Calcul de tes recommandations…").font(.subheadline.weight(.medium))
                        Text("Ça peut prendre quelques minutes. L'accueil se mettra à jour tout seul.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
            } else if discover.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Tes recommandations").font(.display(20, relativeTo: .title3))
                    Text("Elles ne sont pas encore calculées. Écoute un peu de musique, ou lance le calcul.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("Calculer mes recommandations", systemImage: "sparkles", action: start)
                        .buttonStyle(.glass)
                    if gaveUp {
                        Text("Le serveur n'a toujours rien renvoyé après 10 minutes.").font(.footnote).foregroundStyle(.yellow)
                    }
                    if let failure {
                        Text("Le calcul n'a pas pu démarrer : \(failure)").font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(.horizontal)
            } else {
                // Les recommandations ne se recalculent que sur demande.
                Button("Recalculer mes recommandations", systemImage: "arrow.clockwise", action: start)
                    .font(.footnote).foregroundStyle(.secondary).buttonStyle(.borderless)
                    .padding(.horizontal)
            }
        }
        .task(id: computing) {
            guard computing else { return }
            for _ in 0..<120 {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                if let state = try? await client.discover(), !state.fromCache, !state.isPending {
                    sent = false
                    finished(state)
                    return
                }
            }
            guard !Task.isCancelled else { return }
            sent = false
            gaveUp = true
        }
    }

    private func start() {
        sending = true
        gaveUp = false
        failure = nil
        Task {
            do {
                try await client.refreshDiscover()
                sent = true
            } catch {
                failure = error.localizedDescription
            }
            sending = false
        }
    }
}

/// Pourquoi le bac propose cette piste, avec les couleurs du web.
private struct ReasonPill: View {
    let reason: String

    var body: some View {
        switch reason {
        case "recent": Pill(text: "Récent")
        case "rediscover": Pill(text: "À redécouvrir", color: .sky)
        case "same_era": Pill(text: "Même époque", color: .cyan)
        default: Pill(text: "Surprise", color: .yellow)
        }
    }
}
