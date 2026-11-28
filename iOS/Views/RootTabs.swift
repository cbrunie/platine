#if os(iOS)
import SwiftUI

/// Les onglets de l'app. Sur iPhone : Accueil, Discothèque, Rechercher. Sur iPad, la même
/// barre latérale que sur Mac : la discothèque rayon par rayon, les playlists, et en pied
/// les suivis, les demandes, les téléchargements et le compte.
struct RootTabs: View {
    @Environment(\.client) private var client
    @Environment(Session.self) private var session
    @State private var selection = {
        #if DEBUG
        // `-platineTab discover` : l'onglet de départ, pour les captures.
        UserDefaults.standard.string(forKey: "platineTab") ?? "home"
        #else
        "home"
        #endif
    }()
    @State private var sidebarOpen = false
    @State private var playlists: [PlaylistSummary] = []
    @State private var profile: Profile?
    @State private var unseen = 0
    /// L'iPad ne masque des onglets de sa barre du haut que si elle est personnalisable ; on
    /// coupe ensuite la personnalisation elle-même, ce qui retire le bouton « Modifier ».
    @AppStorage("tabs.v2") private var customization = TabViewCustomization()

    private var pad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        // iPad couché : la barre latérale du Mac ; debout : les onglets de l'iPhone.
        GeometryReader { window in
            let landscape = window.size.width > window.size.height
            tabs(sidebar: pad, landscape: landscape)
                .defaultAdaptableTabBarPlacement(landscape ? .sidebar : .tabBar)
                .id(landscape)
        }
        .ignoresSafeArea()
        .task {
            guard pad else { return }
            async let lists = try? client.playlists().playlists
            async let me = try? client.profile()
            async let fresh = try? client.unseenReleases().count
            playlists = await lists ?? []
            profile = await me
            unseen = await fresh ?? 0
        }
    }

    /// `sidebar` : les rayons et le pied de la barre latérale (iPad, dans les deux sens) ; sans elle,
    /// les trois onglets de l'iPhone. Debout, la barre latérale reste repliée derrière les onglets.
    private func tabs(sidebar: Bool, landscape: Bool) -> some View {
        TabView(selection: $selection) {
            Tab("Accueil", systemImage: "house.fill", value: "home") { home }
                .customizationID("home")
                .customizationBehavior(.disabled, for: .automatic, .sidebar, .tabBar)
            // L'onglet Discothèque de l'iPhone et de l'iPad debout ; couché, l'iPad montre ses rayons
            // dans la barre latérale (et un onglet masqué de la barre latérale l'est aussi en haut).
            Tab("Découvrir", systemImage: "sparkles", value: "discover") { HomeView(page: .discover) }
                .customizationID("discover")
                .customizationBehavior(.disabled, for: .automatic, .sidebar, .tabBar)
            Tab("Discothèque", systemImage: "square.stack.fill", value: "library") { LibraryView() }
                .customizationID("library")
                .customizationBehavior(.disabled, for: .automatic, .sidebar, .tabBar)
                .defaultVisibility(sidebar && landscape ? .hidden : .automatic, for: .sidebar)
            Tab("Rechercher", systemImage: "magnifyingglass", value: "search", role: .search) { SearchView() }
                .customizationID("search")
                .customizationBehavior(.disabled, for: .automatic, .sidebar, .tabBar)

            // Ces rayons n'existent que dans la barre latérale de l'iPad.
            if sidebar {
                TabSection("Discothèque") {
                    sidebarTab("Récemment ajoutés", "clock", "recent") { stacked { RecentAlbumsView() } }
                    sidebarTab("Artistes", "music.microphone", "artists") { stacked { ArtistsView() } }
                    sidebarTab("Albums", "square.stack", "albums") { stacked { AlbumsView() } }
                    sidebarTab("Morceaux", "music.note", "tracks") { stacked { TracksView() } }
                    sidebarTab("Playlists", "music.note.list", "playlists") { stacked { PlaylistsView() } }
                }
                .defaultVisibility(.hidden, for: .tabBar)
                .customizationBehavior(.disabled, for: .automatic, .sidebar, .tabBar)

                if !playlists.isEmpty {
                    TabSection("Playlists") {
                        ForEach(playlists) { playlist in
                            sidebarTab(playlist.name, "music.note.list", "playlist-\(playlist.id)") {
                                stacked { PlaylistView(summary: playlist) }
                            }
                        }
                    }
                    .defaultVisibility(.hidden, for: .tabBar)
                    .customizationBehavior(.disabled, for: .automatic, .sidebar, .tabBar)
                }

                // Les pages du pied de la barre latérale : ouvertes par ses boutons, invisibles ailleurs.
                footerTab("following") { stacked { FollowingView() } }
                footerTab("requests") { stacked { RequestsView() } }
                footerTab("downloads") { stacked { DownloadsView() } }
                if session.isAdmin { footerTab("controls") { stacked { LibraryControlsView() } } }
                // Les réglages ont déjà leur pile de navigation.
                footerTab("account") { SettingsView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .onChange(of: PlayerNavigation.shared.target) { _, target in
            if target != nil { selection = "home" }
        }
        .tabViewCustomization($customization)
        .tabViewSidebarBottomBar { if sidebar { footer } }
        .background(SidebarWatcher(isOpen: $sidebarOpen))
        .environment(\.sidebarOpen, sidebarOpen)
    }

    private func sidebarTab(_ title: String, _ symbol: String, _ id: String,
                            @ViewBuilder content: @escaping () -> some View) -> some TabContent<String> {
        Tab(title, systemImage: symbol, value: id) { content() }
            .customizationID(id)
            .customizationBehavior(.disabled, for: .automatic, .sidebar, .tabBar)
            .defaultVisibility(.hidden, for: .tabBar)
    }

    private func footerTab(_ id: String, @ViewBuilder content: @escaping () -> some View) -> some TabContent<String> {
        Tab(value: id) { content() }
            .customizationID(id)
            .customizationBehavior(.disabled, for: .automatic, .sidebar, .tabBar)
            .defaultVisibility(.hidden, for: .tabBar, .sidebar)
    }

    /// Suivis, demandes, téléchargements et admin, puis le compte : le pied de Coulisse, comme sur Mac.
    private var footer: some View {
        SidebarFooter([.init(unseen > 0 ? "Suivis · \(unseen)" : "Suivis", systemImage: "heart", id: "following"),
                       .init("Demandes", systemImage: "tray.and.arrow.down", id: "requests"),
                       .init("Téléchargements", systemImage: "arrow.down.circle", id: "downloads")]
                          // Le bouclier de JellyTV : l'administration de la discothèque, pour un admin.
                          + (session.isAdmin ? [.init("Admin", systemImage: "shield", id: "controls")] : []),
                      account: profile?.displayName ?? session.user?.displayName ?? "Compte", accountID: "account",
                      selected: selection, style: .tabView, select: { selection = $0 }) {
            if let avatar = profile?.avatarUrl, !avatar.isEmpty {
                Cover(path: avatar, size: 28, radius: 14)
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(Color.sage)
            }
        }
    }

    @ViewBuilder
    private var home: some View {
        #if DEBUG
        if let screen = DebugScreen.name, screen != "player", screen != "player-idle", screen != "player-seeded", screen != "player-retry", screen != "account" {
            DebugScreen.view(screen)
        } else {
            HomeView()
        }
        #else
        HomeView()
        #endif
    }

    private func stacked(@ViewBuilder _ content: () -> some View) -> some View {
        NavigationStack { content().platineDestinations() }
    }
}
/// Suit l'ouverture de la barre latérale de l'iPad : SwiftUI ne donne que son style (`tabBarPlacement`
/// vaut `.sidebar` même repliée), UIKit sait si elle est affichée.
private struct SidebarWatcher: UIViewRepresentable {
    @Binding var isOpen: Bool

    func makeUIView(context: Context) -> Probe { Probe { isOpen = $0 } }
    func updateUIView(_ view: Probe, context: Context) {}

    final class Probe: UIView {
        let changed: (Bool) -> Void
        private var timer: Timer?
        private var last: Bool?

        init(changed: @escaping (Bool) -> Void) {
            self.changed = changed
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            timer?.invalidate()
            guard window != nil else { return }
            // ponytail: un coup d'œil toutes les 0,3 s ; UIKit ne publie pas ce changement à SwiftUI.
            timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            check()
        }

        private func check() {
            func find(_ controller: UIViewController?) -> UITabBarController? {
                guard let controller else { return nil }
                if let tabs = controller as? UITabBarController { return tabs }
                return controller.children.lazy.compactMap(find).first ?? find(controller.presentedViewController)
            }
            guard let controller = find(window?.rootViewController) else { return }
            let open = controller.mode == .tabSidebar && !controller.sidebar.isHidden
            if open != last {
                last = open
                changed(open)
            }
        }
    }
}

extension EnvironmentValues {
    /// Vrai quand la barre latérale de l'iPad est ouverte : le compte et les suivis y sont déjà.
    @Entry var sidebarOpen = false
}
#endif
