#if targetEnvironment(macCatalyst)
import SwiftUI

/// « À l'écoute » sur Mac : la platine en grand à gauche, les commandes à
/// droite avec, au choix, les paroles ou la pile dessous ; des capsules de verre aux coins.
struct MacPlayerView: View {
    @Environment(Player.self) private var player
    let close: () -> Void

    @Environment(\.openWindow) private var openWindow
    /// Paroles ou pile sous les commandes ; rien par défaut, comme la platine seule.
    @State private var panel: Panel?
    @State private var scrubbing: Double?
    /// Partagé avec l'iPhone : la platine ou la pochette.
    @AppStorage("turntable") private var turntable = true

    enum Panel { case lyrics, queue }

    var body: some View {
        NavigationStack { content }

    }

    private var content: some View {
        GeometryReader { geometry in
            let left = geometry.size.width * 0.55
            // La platine en grand : elle déborde à gauche, le bras reste dans sa colonne.
            let side = min(geometry.size.height * 0.95, left * 1.2)
            ZStack(alignment: .topLeading) {
                Group {
                    if turntable {
                        Turntable(cover: player.current?.cover, isPlaying: player.isPlaying)
                            .frame(width: side, height: side)
                            .position(x: left - side / 2 - 20, y: geometry.size.height / 2)
                    } else {
                        // La pochette seule, centrée dans sa colonne, comme sur l'iPhone.
                        let cover = min(left - 120, geometry.size.height - 200)
                        Cover(path: player.current?.cover, size: cover, radius: 12)
                            .shadow(color: .black.opacity(0.5), radius: 24, y: 14)
                            .position(x: left / 2 + 20, y: geometry.size.height / 2)
                    }
                }
                .transition(.opacity)
                .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 28) {
                    details
                    if let panel {
                        Group {
                            switch panel {
                            case .lyrics: LyricsView(track: player.current)
                            case .queue: ScrollView { QueueSection() }
                            }
                        }
                        .frame(maxHeight: .infinity)
                        .transition(.opacity)
                    }
                }
                // Les commandes gardent la largeur de celles de Musique, pas toute la colonne.
                .frame(maxWidth: 360, maxHeight: panel == nil ? nil : .infinity)
                .padding(.vertical, panel == nil ? 0 : 80)
                .frame(width: geometry.size.width - left - 40, height: geometry.size.height)
                .offset(x: left + 20)
            }
            .animation(.easeInOut(duration: 0.3), value: panel)
            .animation(.easeInOut(duration: 0.35), value: turntable)
        }
        .foregroundStyle(.white)
        // De vrais éléments de la barre d'outils : la bande de titre n'envoie ses clics qu'à eux.
        // Un élément par capsule, comme les groupes de Musique.
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 0) {
                    Button(action: close) { titlebarIcon("xmark") }
                        .keyboardShortcut(.cancelAction)
                        .help("Fermer")
                    Button {
                        openWindow(id: MiniPlayerWindow.id)
                        close()
                    } label: { titlebarIcon("pip.enter") }
                        .help("Mini-lecteur")
                }
                .padding(.horizontal, 4)
                // Pas `.plain` : dans la barre d'outils du Mac, ce style rend les boutons inertes.
                .buttonStyle(.borderless)
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    RoutePicker().frame(width: 26, height: 26)
                    Divider().frame(height: 18)
                    VolumeBar().frame(width: 200).foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 6)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 2) {
                toggle(.lyrics, "quote.bubble", help: "Paroles")
                toggle(.queue, "list.bullet", help: "À suivre")
                Button { turntable.toggle() } label: {
                    VinylGlyph()
                        .frame(width: 18, height: 18)
                        .frame(width: 28, height: 28)
                        .foregroundStyle(turntable ? Color.base100 : .white)
                        .background(turntable ? Color.white.opacity(0.85) : .clear, in: .circle)
                        .contentShape(.circle)
                }
                .help(turntable ? "Afficher la pochette" : "Afficher la platine")
            }
            .padding(4)
            .glassEffect(.regular, in: .capsule)
            .padding(16)
        }
        // En dernier : les boutons des capsules aussi restent nus, sans le cadre gris du Mac.
        .buttonStyle(.plain)
        .background {
            ZStack {
                Color.base100
                Cover(path: player.current?.cover, size: nil, radius: 0)
                    .scaleEffect(2)
                    .blur(radius: 80)
                    .opacity(0.4)
            }
            .ignoresSafeArea()
        }
    }

    /// Le titre, la progression et les cinq commandes sous la platine.
    private var details: some View {
        let track = player.current
        let position = scrubbing ?? player.elapsed
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(track?.title ?? "Platine à l'arrêt").font(.display(22, relativeTo: .title2)).lineLimit(1)
                    Spacer(minLength: 0)
                    Menu {
                        if let route = track?.albumRoute {
                            Button("Aller à l'album", systemImage: "square.stack") { open(route) }
                        }
                        if let route = track?.artistRoute {
                            Button("Aller à l'artiste", systemImage: "music.microphone") { open(route) }
                        }
                        Button("Mélanger la pile", systemImage: "shuffle") { player.shuffleUpcoming() }
                        Button("Vider la pile", systemImage: "text.badge.minus", role: .destructive) {
                            player.removeUpcoming(at: IndexSet(player.upcoming.indices.map { $0 - player.index - 1 }))
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .frame(width: 30, height: 30)
                            .glassEffect(.regular, in: .circle)
                    }
                    .menuIndicator(.hidden)
                    .accessibilityLabel("Plus")
                }
                HStack(spacing: 4) {
                    Button { open(track?.artistRoute) } label: { Text(track?.artist ?? " ") }
                        .disabled(track?.artistRoute == nil)
                    if let track {
                        Text("— \(track.album)")
                    }
                }
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
            }
            if let error = player.error {
                Label("Le disque saute : \(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.yellow).lineLimit(2)
            }
            VStack(spacing: 4) {
                Scrubber(elapsed: player.elapsed, duration: player.duration, scrubbing: $scrubbing) { player.seek(to: $0) }
                HStack {
                    Text(clock(position))
                    Spacer()
                    Text("-" + clock(max(player.duration - position, 0)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
            }
            HStack {
                Button { player.shuffleUpcoming() } label: { Image(systemName: "shuffle") }.help("Mélanger la pile")
                Spacer()
                Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title) }
                Spacer()
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 40))
                        .frame(width: 50)
                        .contentTransition(.symbolEffect(.replace))
                }
                Spacer()
                Button { player.next() } label: { Image(systemName: "forward.fill").font(.title) }
                Spacer()
                Button {
                    player.repeatMode = switch player.repeatMode { case .off: .all; case .all: .one; case .one: .off }
                } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .foregroundStyle(player.repeatMode == .off ? .white : Color.sage)
                }
                .help("Répéter")
            }
            .font(.title3)
        }
    }

    /// Referme le lecteur et ouvre la page derrière lui.
    private func open(_ route: Route?) {
        guard let route else { return }
        PlayerNavigation.shared.target = route
        close()
    }

    private func titlebarIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.title3).foregroundStyle(.white).frame(width: 40, height: MacTitlebar.capsuleHeight).contentShape(.rect)
    }

    private func toggle(_ kind: Panel, _ symbol: String, help: String) -> some View {
        Button { panel = panel == kind ? nil : kind } label: {
            Image(systemName: symbol)
                .font(.body)
                .frame(width: 28, height: 28)
                .foregroundStyle(panel == kind ? Color.base100 : .white)
                .background(panel == kind ? Color.white.opacity(0.85) : .clear, in: .circle)
                .contentShape(.circle)
        }
        .help(help)
    }
}
#endif
