import AVFoundation
import SwiftUI

@main
struct PlatineApp: App {
    @State private var player = Player.shared
    @State private var showsPlayer = false

    init() {
        // Les titres de navigation en Space Grotesk, comme les titres du web.
        let bar = UINavigationBar.appearance()
        bar.largeTitleTextAttributes = [.font: UIFont.display(34)]
        bar.titleTextAttributes = [.font: UIFont.display(17)]
        #if targetEnvironment(macCatalyst)
        // Le réglage de macOS, pour cette app seule : avec une souris, il laisse les barres de défilement
        // à l'écran, par-dessus les rayons. SwiftUI et UIKit ne suffisent pas à les retirer.
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
        #endif
        // Siri et CarPlay peuvent lancer l'app sans fenêtre : le lecteur doit déjà connaître le serveur.
        if let client = Session.shared.client { Player.shared.connect(client) }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "platineSelfTest") {
            DiscographyCheck.run()
            SearchHistory.check()
            for status in ["pending", "queued", "downloading", "importing", "paused", "awaiting_approval"] {
                assert(!RequestStatus.allowsNewRequest(status), status)
            }
            for status in ["failed", "cancelled", "rejected", "incomplete", "imported"] {
                assert(RequestStatus.allowsNewRequest(status), status)
            }
            assert(GenreEmblem.emoji(for: "pop punk") == "🛹")
            assert(GenreEmblem.emoji(for: "Synth-Pop") == "🎹")
            assert(GenreEmblem.emoji(for: "rock") == "🎸")
            assert(GenreEmblem.emoji(for: "gagaku") == "💿")
            let song = TopSong(title: "Everlong", artistName: "Foo Fighters", recordingMbid: "r1", releaseGroupMbid: "g1",
                               originalReleaseMbid: "o1", releaseName: "The Colour and the Shape", listenCount: 1)
            let planned = PlannedTrack(recording: "r2", title: "Everlong (Remastered)", artist: "Foo Fighters", artistID: nil)
            assert(planned.onAlbum(from: [song]).request.releaseGroupMbid == "g1")
            assert(planned.onAlbum(from: []).request.albumTitle == nil)
            assert(Alphabet.letter(of: "Élodie") == "E")
            assert(Alphabet.letter(of: "80 ans") == "#")
            let lettered = Alphabet.sections(["80 ans", "abba", "Air", "Zaz"], name: { $0 })
            assert(lettered.map(\.letter) == ["A", "Z", "#"] && lettered[0].items == ["abba", "Air"])
            let top = HomeItem(name: "Black Holes", mbid: nil, artistName: "The Blue Stones", artistMbid: nil, imageUrl: nil,
                               inLibrary: true, requested: false, listenCount: 574)
            let counts = ListenCounts([top])
            assert(counts.count(album: "black holes", artist: "The Blue Stones") == 574 && counts.count(artist: "Muse") == nil)
            assert(ListenCounts.ranked(["a", "b", "c"], name: { $0 }, count: { $0 == "c" ? 3 : nil }) == ["c", "a", "b"])
            assert(try! JSONDecoder().decode(ListenCounts.self, from: JSONEncoder().encode(counts)) == counts)
            Cover.check()
            assert(Player.isTransient(URLError(.timedOut)))
            assert(Player.isTransient(NSError(domain: AVFoundationErrorDomain, code: -11800,
                                              userInfo: [NSUnderlyingErrorKey: URLError(.networkConnectionLost)])))
            assert(!Player.isTransient(URLError(.fileDoesNotExist)) && !Player.isTransient(nil))
            V3DecodingCheck.run()
            print("platine self-test: ok")
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(showsPlayer: $showsPlayer)
        }
        // Le menu Lecture et ses raccourcis, pour le Mac et les claviers d'iPad.
        .commands {
            CommandMenu("Lecture") {
                Button(player.isPlaying ? "Pause" : "Lecture") { player.toggle() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Suivant") { player.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Précédent") { player.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Divider()
                Button("Ouvrir le lecteur") { showsPlayer = true }
                    .keyboardShortcut("l", modifiers: .command)
            }
        }
        #if targetEnvironment(macCatalyst)
        WindowGroup("Mini-lecteur", id: MiniPlayerWindow.id) {
            MiniPlayerRoot()
        }
        #endif
    }
}

/// Le contenu de la fenêtre. Il doit rester une vue à part : la closure de `WindowGroup` n'est pas
/// isolée, SwiftUI peut la réévaluer sur son fil de rendu dès qu'une animation en boucle tourne, et
/// Swift 6 tue l'app si elle lit alors un état (`session.client`). Elle ne fait donc que créer cette vue.
private struct RootView: View {
    @Binding var showsPlayer: Bool

    @State private var session = Session.shared
    @State private var player = Player.shared
    @State private var showsAccount = false
    @State private var launched = false
    @Namespace private var transition

    var body: some View {
        Group {
            if let client = session.client, !DebugScreen.login {
                Group {
                    #if targetEnvironment(macCatalyst)
                    // Sur Mac, comme Musique : une barre latérale et la barre de lecture flottante.
                    MacRoot(showsPlayer: $showsPlayer)
                    #else
                    // Sur iPhone trois onglets ; sur iPad, la barre latérale du Mac.
                    RootTabs()
                    .tabBarMinimizeBehavior(.onScrollDown)
                    .tabViewBottomAccessory {
                        MiniPlayer()
                            .onTapGesture { showsPlayer = true }
                            .matchedTransitionSource(id: "player", in: transition)
                    }
                    .fullScreenCover(isPresented: $showsPlayer) {
                        PlayerView()
                            .navigationTransition(.zoom(sourceID: "player", in: transition))
                            .environment(\.client, client)
                            .environment(player)
                    }
                    #endif
                }
                .environment(\.client, client)
                .task(id: client.token) {
                    player.connect(client)
                    await session.refreshUser()
                    await ArtistDirectory.shared.load(client)
                    #if DEBUG
                    if DebugScreen.name == "player" {
                        try? await Task.sleep(for: .seconds(2))
                        if let crate = try? await client.crate() { player.play(crate.items.map(\.track), using: client) }
                        showsPlayer = true
                    }
                    if DebugScreen.name == "player-seeded" {
                        if let crate = try? await client.crate() { player.debugSeed(crate.items.map(\.track)) }
                        showsPlayer = true
                    }
                    if DebugScreen.name == "player-retry", let crate = try? await client.crate() {
                        player.debugRetryTest(crate.items.map(\.track), using: client)
                    }
                    if DebugScreen.name == "account" { showsAccount = true }
                    // Le lecteur sans rien lancer : pour photographier sans jouer de musique.
                    if DebugScreen.name == "player-idle" {
                        // Comme à la main : la bibliothèque d'abord, puis le lecteur.
                        try? await Task.sleep(for: .seconds(2))
                        showsPlayer = true
                    }
                    #endif
                }
                #if DEBUG
                .sheet(isPresented: $showsAccount) { SettingsView() }
                #endif
            } else {
                LoginView()
            }
        }
        .overlay {
            if !launched { Splash().transition(.opacity.combined(with: .scale(scale: 1.4))) }
        }
        .task {
            #if DEBUG
            Task { await DebugScreen.runScrollScript() }
            if UserDefaults.standard.bool(forKey: "platineSeedHistory"), let client = session.client,
               let playlist = try? await client.playlists().playlists.first,
               let album = try? await client.albums().items.first,
               let track = try? await client.tracks(of: album.musicbrainzId).first {
                player.debugSeedHistory(album: track.track(in: album), playlist: PlaySource(
                    kind: .playlist, id: playlist.id, title: playlist.name, subtitle: "Playlist", covers: playlist.covers.compactMap(\.self)))
            }
            #if targetEnvironment(macCatalyst)
            // `-platineWindowFrame "x,y,l,h"` : la fenêtre de test à l'écart de celle de l'utilisateur.
            if let frame = UserDefaults.standard.string(forKey: "platineWindowFrame")?
                .split(separator: ",").compactMap({ Double($0) }), frame.count == 4 {
                try? await Task.sleep(for: .seconds(1))
                let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
                scene?.sizeRestrictions?.minimumSize = CGSize(width: 300, height: 300)
                scene?.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3])))
            }
            #endif
            // `-platineLandscape YES` : pour photographier l'iPad à l'horizontale.
            if UserDefaults.standard.bool(forKey: "platineLandscape") { try? await Task.sleep(for: .seconds(1.2)) }
            if UserDefaults.standard.bool(forKey: "platineLandscape"),
               let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
            }
            #endif
            try? await Task.sleep(for: .seconds(0.9))
            withAnimation(.smooth(duration: 0.5)) { launched = true }
        }
        .environment(session)
        .environment(player)
        .tint(.sage)
        .preferredColorScheme(.dark)
        #if targetEnvironment(macCatalyst)
        .onAppear { MacTitlebar.setTitleHidden(false) }
        #endif
    }
}

#if targetEnvironment(macCatalyst)
/// Le contenu de la fenêtre du mini-lecteur, à part pour la même raison.
private struct MiniPlayerRoot: View {
    @State private var session = Session.shared
    @State private var player = Player.shared

    var body: some View {
        MiniPlayerWindow()
            .environment(\.client, session.client ?? DroppedNeedle(server: URL(string: Session.defaultServer)!))
            .environment(player)
            .preferredColorScheme(.dark)
    }
}
#endif

/// La suite de l'écran de lancement : le même disque, qui se met à tourner
/// puis s'efface sur l'app.
private struct Splash: View {
    @State private var turning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image("Record")
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: 4.2).repeatForever(autoreverses: false), value: turning)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.base100)
            .ignoresSafeArea()
            .onAppear { turning = !reduceMotion }
    }
}
