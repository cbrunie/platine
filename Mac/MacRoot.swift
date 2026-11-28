#if targetEnvironment(macCatalyst)
import SwiftUI

/// Platine sur Mac, rangé comme Musique : la recherche, l'accueil et la
/// discothèque dans la barre latérale, les suivis et le compte en bas, et la
/// barre de lecture qui flotte au pied de la page.
struct MacRoot: View {
    @Binding var showsPlayer: Bool

    @Environment(\.client) private var client
    @Environment(Session.self) private var session
    @Environment(Player.self) private var player
    @State private var page: Page? = .home
    @State private var playlists: [PlaylistSummary] = []
    @State private var profile: Profile?
    @State private var unseen = 0
    @State private var inspector: Inspector?
    @State private var columns = NavigationSplitViewVisibility.all

    enum Page: Hashable {
        case search, home, discover, recent, artists, albums, tracks, playlists, controls
        case playlist(PlaylistSummary)
        case following, requests, downloads, account
    }

    enum Inspector { case lyrics, queue }

    var body: some View {
        library
            // Le lecteur prend toute la fenêtre : la barre latérale se replie, et ses boutons
            // se rangent dans la barre d'outils juste après les feux, comme dans Musique.
            .onChange(of: PlayerNavigation.shared.target) { _, target in
                if target != nil { page = .home }
            }
            .onChange(of: showsPlayer, initial: true) { _, shows in
                withAnimation(.easeInOut(duration: 0.25)) { columns = shows ? .detailOnly : .all }
                MacTitlebar.setTitleHidden(shows)
            }
    }

    private var library: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $page) {
                row("Rechercher", "magnifyingglass", .search)
                row("Accueil", "house", .home)
                row("Découvrir", "sparkles", .discover)
                Section("Discothèque") {
                    row("Récemment ajoutés", "clock", .recent)
                    row("Artistes", "music.microphone", .artists)
                    row("Albums", "square.stack", .albums)
                    row("Morceaux", "music.note", .tracks)
                    row("Playlists", "music.note.list", .playlists)
                    if session.isAdmin { row("Contrôles", "slider.horizontal.3", .controls) }
                }
                if !playlists.isEmpty {
                    Section("Playlists") {
                        ForEach(playlists) { playlist in
                            Label {
                                Text(playlist.name).oneLine().foregroundStyle(Color.primary)
                            } icon: {
                                Cover(path: playlist.covers.first ?? nil, size: 18, radius: 3)
                            }
                            .tag(Page.playlist(playlist))
                        }
                    }
                }
            }
            // La sélection discrète de Musique : un gris, pas un aplat de couleur.
            .tint(.white.opacity(0.14))
            .environment(\.defaultMinListRowHeight, 30)
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            if showsPlayer {
                MacPlayerView { showsPlayer = false }
            } else {
                browser
            }
        }
        .tint(.sage)
        .task {
            async let lists = try? client.playlists().playlists
            async let me = try? client.profile()
            async let fresh = try? client.unseenReleases().count
            playlists = await lists ?? []
            profile = await me
            unseen = await fresh ?? 0
        }
    }

    /// La page choisie, la barre de lecture au pied et les paroles ou la pile à droite.
    private var browser: some View {
        detail
            .id(page)
            // Même pendant un chargement, la barre de lecture reste au pied de la fenêtre.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom) {
                MacPlayerBar(showsPlayer: $showsPlayer, inspector: $inspector)
                    .padding(.bottom, 12)
            }
            .inspector(isPresented: Binding(get: { inspector != nil }, set: { if !$0 { inspector = nil } })) {
                Group {
                    if inspector == .lyrics {
                        LyricsView(track: player.current)
                    } else {
                        ScrollView { QueueSection().padding() }
                    }
                }
                .inspectorColumnWidth(min: 280, ideal: 340)
                .background(Color.base100)
            }
    }

    private func row(_ title: String, _ symbol: String, _ page: Page) -> some View {
        Label {
            // Sans couleur explicite, la ligne choisie s'efface quand la fenêtre n'a plus le focus.
            Text(title).foregroundStyle(Color.primary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.sage)
        }
        .tag(page)
    }

    /// Suivis, demandes et téléchargements, puis le compte, comme le profil de Musique.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            footerButton(unseen > 0 ? "Suivis · \(unseen)" : "Suivis", "heart", .following)
            footerButton("Demandes", "tray.and.arrow.down", .requests)
            footerButton("Téléchargements", "arrow.down.circle", .downloads)
            Divider().padding(.vertical, 6)
            // Le compte s'ouvre en grand dans la page, pas dans une feuille.
            Button { page = .account } label: {
                HStack(spacing: 10) {
                    if let avatar = profile?.avatarUrl, !avatar.isEmpty {
                        Cover(path: avatar, size: 26, radius: 13)
                    } else {
                        Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(Color.sage)
                    }
                    Text(profile?.displayName ?? session.user?.displayName ?? "Compte").oneLine()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(page == .account ? Color.white.opacity(0.1) : .clear, in: .rect(cornerRadius: 8))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private func footerButton(_ title: String, _ symbol: String, _ target: Page) -> some View {
        Button { page = target } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol).foregroundStyle(Color.sage)
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(page == target ? Color.white.opacity(0.1) : .clear, in: .rect(cornerRadius: 8))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detail: some View {
        switch page ?? .home {
        // L'accueil et la recherche ont déjà leur pile de navigation.
        #if DEBUG
        // `-platineScreen <nom>` : l'écran voulu à la place de l'accueil, pour les captures.
        case .home where DebugScreen.name != nil && !(DebugScreen.name ?? "").hasPrefix("player"):
            DebugScreen.view(DebugScreen.name ?? "")
        #endif
        case .home: HomeView()
        case .discover: HomeView(page: .discover)
        case .search: SearchView()
        case .recent: stacked { RecentAlbumsView() }
        case .artists: stacked { ArtistsView() }
        case .albums: stacked { AlbumsView() }
        case .tracks: stacked { TracksView() }
        case .playlists: stacked { PlaylistsView() }
        case .controls: stacked { LibraryControlsView() }
        case .playlist(let summary): stacked { PlaylistView(summary: summary) }
        case .following: stacked { FollowingView() }
        case .requests: stacked { RequestsView() }
        case .downloads: stacked { DownloadsView() }
        // Les réglages ont déjà leur pile de navigation.
        case .account: SettingsView()
        }
    }

    private func stacked(@ViewBuilder _ content: () -> some View) -> some View {
        NavigationStack { content().platineDestinations() }
    }
}

/// La barre de lecture de Musique sur Mac : une capsule de verre au pied de la
/// page, les commandes à gauche, le morceau au centre, le reste à droite.
private struct MacPlayerBar: View {
    @Binding var showsPlayer: Bool
    @Binding var inspector: MacRoot.Inspector?

    @Environment(Player.self) private var player
    @State private var showsVolume = false

    var body: some View {
        let track = player.current
        HStack(spacing: 18) {
            HStack(spacing: 16) {
                Button { player.shuffleUpcoming() } label: { Image(systemName: "shuffle") }
                    .help("Mélanger la pile")
                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 24)
                        .contentTransition(.symbolEffect(.replace))
                }
                Button { player.next() } label: { Image(systemName: "forward.fill") }
                Button { cycleRepeat() } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .foregroundStyle(player.repeatMode == .off ? Color.primary : Color.sage)
                }
                .help("Répéter")
            }

            Button { showsPlayer = true } label: {
                HStack(spacing: 10) {
                    Cover(path: track?.cover, size: 38, radius: 5)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track?.title ?? "Platine à l'arrêt").font(.callout.weight(.semibold)).oneLine()
                        Text(track.map { "\($0.artist) — \($0.album)" } ?? " ")
                            .font(.caption).foregroundStyle(.secondary).oneLine()
                        // La progression, fine comme celle de Musique.
                        GeometryReader { geometry in
                            Capsule().fill(.white.opacity(0.15))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.6))
                                        .frame(width: geometry.size.width * progress)
                                }
                        }
                        .frame(height: 3)
                    }
                    .frame(width: 260, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .help("Ouvrir le lecteur")

            HStack(spacing: 16) {
                toggle(.lyrics, "quote.bubble", help: "Paroles")
                toggle(.queue, "list.bullet", help: "À suivre")
                RoutePicker().frame(width: 24, height: 24)
                Button { showsVolume.toggle() } label: { Image(systemName: "speaker.wave.2.fill") }
                    .popover(isPresented: $showsVolume) {
                        VolumeBar().frame(width: 220).padding().foregroundStyle(.secondary)
                    }
            }
        }
        .buttonStyle(.plain)
        .font(.body)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }

    private var progress: CGFloat {
        player.duration > 0 ? CGFloat(min(player.elapsed / player.duration, 1)) : 0
    }

    private func cycleRepeat() {
        player.repeatMode = switch player.repeatMode { case .off: .all; case .all: .one; case .one: .off }
    }

    private func toggle(_ kind: MacRoot.Inspector, _ symbol: String, help: String) -> some View {
        Button { inspector = inspector == kind ? nil : kind } label: {
            Image(systemName: symbol).foregroundStyle(inspector == kind ? Color.sage : Color.primary)
        }
        .help(help)
    }
}
#endif
