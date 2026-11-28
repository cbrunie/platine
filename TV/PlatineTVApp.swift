import SwiftUI

/// Platine sur Apple TV : les mêmes disques, le même lecteur, une interface à
/// la télécommande — des rayons de pochettes et la platine en grand.
@main
struct PlatineTVApp: App {
    init() {
        URLProtocol.registerClass(DemoServer.self)
        if let client = Session.shared.client { Player.shared.connect(client) }
    }

    var body: some Scene {
        WindowGroup {
            TVRoot()
        }
    }
}

/// Le contenu de la fenêtre, à part : voir `RootView` dans l'app iPhone.
private struct TVRoot: View {
    @State private var session = Session.shared
    @State private var player = Player.shared
    @State private var tab = TVTab.debugStart ?? .home

    var body: some View {
        Group {
            if let client = session.client, !TVTab.debugLogin {
                // Rangé comme Projecteur et JellyTV : la barre latérale, le compte en tête.
                TabView(selection: $tab) {
                    Tab(session.user?.displayName ?? "Compte", systemImage: "person.crop.circle", value: .account) { TVAccount() }
                    Tab(value: TVTab.search, role: .search) { TVSearch() }
                    Tab("Accueil", systemImage: "house", value: .home) { TVHome() }
                    Tab("À l'écoute", systemImage: "opticaldisc", value: .nowPlaying) { TVNowPlaying() }
                    TabSection("Discothèque") {
                        Tab("Albums", systemImage: "square.stack", value: TVTab.library) { TVLibrary() }
                        Tab("Playlists", systemImage: "music.note.list", value: TVTab.playlists) { TVPlaylists() }
                    }
                }
                .tabViewStyle(.sidebarAdaptable)
                .environment(\.client, client)
                .environment(\.showNowPlaying, ShowNowPlaying(tab: $tab))
                .task(id: client.token) {
                    player.connect(client)
                    await session.refreshUser()
                }
            } else {
                TVLoginView()
            }
        }
        .environment(session)
        .environment(player)
        .onPlayPauseCommand { player.toggle() }
        .tint(.sage)
        .preferredColorScheme(.dark)
    }
}

enum TVTab: String, Hashable { case account, home, library, playlists, nowPlaying, search }

extension TVTab {
    /// `-platineTab library` : l'onglet de départ, pour les captures. Absent des builds Release.
    /// `-platineLogin YES` : l'écran de connexion même connecté, pour les captures.
    static var debugLogin: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "platineLogin")
        #else
        false
        #endif
    }

    static var debugStart: TVTab? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "platineTab").flatMap(TVTab.init(rawValue:))
        #else
        nil
        #endif
    }
}

extension EnvironmentValues {
    /// Passe sur « À l'écoute » après avoir posé un disque.
    @Entry var showNowPlaying = ShowNowPlaying()
}

/// Un lien vers l'onglet plutôt qu'une closure, que l'environnement ne sait pas comparer.
struct ShowNowPlaying {
    var tab: Binding<TVTab>?

    func callAsFunction() { tab?.wrappedValue = .nowPlaying }
}

/// Le compte : qui est connecté, à quel serveur, et la déconnexion.
private struct TVAccount: View {
    @Environment(Session.self) private var session

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "person.crop.circle.fill").font(.system(size: 96)).foregroundStyle(.tint)
            Text(session.user?.displayName ?? "").font(.title2.bold())
            Text(session.server).font(.callout).foregroundStyle(.secondary)
            Button("Se déconnecter", role: .destructive) { session.logout() }
                .padding(.top, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
