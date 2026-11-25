import SwiftUI

/// Le lecteur plein écran, disposé comme celui de Musique : la platine (ou
/// la pochette) en haut, les commandes en bas, et la pile juste dessous —
/// on fait défiler le lecteur pour la voir, au doigt comme au trackpad.
struct PlayerView: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    @AppStorage("turntable") private var turntable = true
    /// Vrai quand on a fait défiler jusqu'à la pile.
    @State private var showsQueue = false
    @State private var showsLyrics = false
    @State private var position = ScrollPosition(edge: .top)
    /// La position sous le doigt pendant qu'on fait glisser la barre.
    @State private var scrubbing: Double?

    var body: some View {
        GeometryReader { screen in
            // Le contenu défile jusque sous la barre d'accueil : la page en couvre
            // aussi la hauteur, sinon le haut de la pile dépasse en bas de l'écran.
            let bottom = screen.safeAreaInsets.bottom
            ScrollView {
                VStack(spacing: 0) {
                    if screen.size.width > screen.size.height {
                        // iPad à l'horizontale, comme sur Mac : la grande platine déborde à gauche,
                        // son bras reste dans sa moitié, les commandes tiennent à droite.
                        let left = screen.size.width * 0.55
                        HStack(spacing: 0) {
                            artwork { size in
                                let side = min(size.height * 0.95, left * 1.2)
                                return (side, CGPoint(x: left - side / 2 - 20, y: size.height / 2))
                            }
                            .frame(width: left)
                            controls
                                .frame(maxWidth: 380)
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 20)
                        }
                        .frame(height: screen.size.height + bottom)
                    } else if UIDevice.current.userInterfaceIdiom == .pad {
                        // iPad debout : un disque plus petit, et les commandes à mi-chemin entre
                        // lui et le bas de l'écran.
                        VStack(spacing: 0) {
                            artwork { size in
                                let side = size.width * 1.15
                                return (side, CGPoint(x: size.width / 2, y: size.height - side / 2))
                            }
                            .frame(height: screen.size.height * 0.52)
                            // Les commandes au milieu de l'espace entre le disque et le bas de l'écran.
                            Spacer(minLength: 24)
                            controls
                                .frame(maxWidth: 560)
                                .padding(.horizontal, 28)
                            Spacer(minLength: 24)
                        }
                        .frame(height: screen.size.height + bottom)
                    } else {
                        VStack(spacing: 0) {
                            artwork { size in
                                // Le disque déborde à gauche, à droite et en haut ; on garde son bord
                                // bas. Le pivot du bras tombe hors de l'écran : seule la cellule entre.
                                let side = size.width * 1.5
                                return (side, CGPoint(x: size.width / 2, y: size.height - side / 2))
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.bottom, 28)
                            controls
                                .frame(maxWidth: 560)
                                .padding(.horizontal, 28)
                                .padding(.bottom, 16 + bottom)
                        }
                        .frame(height: screen.size.height + bottom)
                    }

                    QueueSection()
                        .frame(maxWidth: 720)
                        .padding(.horizontal, 20)
                        .padding(.top, 24)
                        .padding(.bottom, 24 + bottom)
                        .id("queue")
                }
            }
            .scrollPosition($position)
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y > geometry.containerSize.height / 3
            } action: { _, past in
                showsQueue = past
            }
        }
        .overlay(alignment: .top) {
            Capsule()
                .fill(.white.opacity(0.4))
                .frame(width: 40, height: 5)
                .padding(.top, 8)
                .frame(width: 120, height: 30, alignment: .top)
                .contentShape(.rect)
                .onTapGesture { dismiss() }
                .accessibilityLabel("Fermer")
                .accessibilityAddTraits(.isButton)
        }
        .foregroundStyle(.white)
        .background { Backdrop(cover: player.current?.cover) }
    }

    /// Referme le lecteur et ouvre la page derrière lui.
    private func open(_ route: Route?) {
        guard let route else { return }
        dismiss()
        PlayerNavigation.shared.target = route
    }

    private func scroll(toQueue: Bool) {
        withAnimation(.spring(duration: 0.5)) {
            if toQueue { position.scrollTo(id: "queue", anchor: .top) } else { position.scrollTo(edge: .top) }
        }
    }

    // MARK: Haut

    /// Platine, pochette et paroles se fondent l'une dans l'autre, au même endroit.
    /// `place` donne la taille du disque et son centre dans la zone de l'illustration.
    private func artwork(place: @escaping (CGSize) -> (side: CGFloat, center: CGPoint)) -> some View {
        ZStack {
            if showsLyrics {
                LyricsView(track: player.current)
                    .transition(.opacity)
            } else if turntable {
                GeometryReader { geometry in
                    let (side, center) = place(geometry.size)
                    Turntable(cover: player.current?.cover, isPlaying: player.isPlaying)
                        .frame(width: side, height: side)
                        .position(center)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            } else {
                Cover(path: player.current?.cover, size: nil, radius: 12)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 14)
                    .scaleEffect(player.isPlaying ? 1 : 0.82)
                    .animation(.spring(duration: 0.5, bounce: 0.3), value: player.isPlaying)
                    .padding(.horizontal, 28)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: turntable)
        .animation(.easeInOut(duration: 0.35), value: showsLyrics)
    }

    // MARK: Bas

    private var controls: some View {
        let track = player.current
        let position = scrubbing ?? player.elapsed
        return VStack(spacing: 20) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track?.title ?? "Platine à l'arrêt")
                        .font(.display(22, relativeTo: .title2))
                        .lineLimit(1)
                    Button { open(track?.artistRoute) } label: {
                        Text(track?.artist ?? " ")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    .disabled(track?.artistRoute == nil)
                }
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
                        .frame(width: 34, height: 34)
                        .glassEffect(.regular, in: .circle)
                }
                .accessibilityLabel("Plus")
            }

            if let error = player.error {
                Label("Le disque saute : \(error) Touchez lecture pour reposer l'aiguille.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.yellow)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 6) {
                Scrubber(elapsed: player.elapsed, duration: player.duration, scrubbing: $scrubbing) {
                    player.seek(to: $0)
                }
                HStack {
                    Text(clock(position)).frame(width: 60, alignment: .leading)
                    Spacer()
                    if let format = track?.format, !format.isEmpty {
                        Label(format.uppercased(), systemImage: "waveform").font(.caption2.weight(.semibold))
                    }
                    Spacer()
                    Text("-" + clock(max(player.duration - position, 0))).frame(width: 60, alignment: .trailing)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
            }

            HStack {
                Spacer()
                Button { player.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 34)) }
                    .accessibilityLabel("Précédent")
                    .disabled(track == nil)
                Spacer()
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 52))
                        .frame(width: 70, height: 70)
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Lecture")
                Spacer()
                Button { player.next() } label: { Image(systemName: "forward.fill").font(.system(size: 34)) }
                    .accessibilityLabel("Suivant")
                    .disabled(track == nil)
                Spacer()
            }

            VolumeBar()
                .font(.caption)
            .foregroundStyle(.white.opacity(0.6))

            HStack {
                Button {
                    showsLyrics.toggle()
                    scroll(toQueue: false)
                } label: {
                    toggle(on: showsLyrics && !showsQueue) { Image(systemName: "quote.bubble").font(.title3) }
                }
                .accessibilityLabel("Paroles")
                Spacer()
                Button {
                    if showsLyrics { showsLyrics = false } else { turntable.toggle() }
                    scroll(toQueue: false)
                } label: {
                    toggle(on: turntable && !showsLyrics && !showsQueue) { VinylGlyph() }
                }
                    .accessibilityLabel("Platine")
                    .accessibilityValue(turntable ? "Activée" : "Désactivée")
                Spacer()
                RoutePicker().frame(width: 40, height: 40)
                    .accessibilityLabel("AirPlay")
                Spacer()
                Button { scroll(toQueue: !showsQueue) } label: {
                    toggle(on: showsQueue) { Image(systemName: "list.bullet").font(.title3) }
                }
                    .accessibilityLabel("À suivre")
            }
            .padding(.horizontal, 20)
        }
        .buttonStyle(.plain)
    }

    /// Un bouton à bascule comme les paroles de Musique : plein quand il est actif.
    private func toggle(on: Bool, @ViewBuilder icon: () -> some View) -> some View {
        icon()
            .frame(width: 40, height: 40)
            .foregroundStyle(on ? Color.base100 : .white.opacity(0.7))
            .background(on ? Color.white.opacity(0.85) : .clear, in: .circle)
    }
}

/// Le fond vert-noir du web, teinté par la pochette floutée.
private struct Backdrop: View {
    let cover: String?

    var body: some View {
        ZStack {
            Color.base100
            Cover(path: cover, size: nil, radius: 0)
                .scaleEffect(2.5)
                .blur(radius: 60)
                .opacity(0.45)
            LinearGradient(colors: [.clear, .base100.opacity(0.8)], startPoint: .center, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}
