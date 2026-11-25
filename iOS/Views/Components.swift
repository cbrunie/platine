import SwiftUI

/// Une piste à lire : un tap la lance avec celles qui l'entourent.
struct TrackRow<Accessory: View>: View {
    let track: Track
    var leading: String?
    /// Le menu d'appui long ; la pile du lecteur a le sien.
    var menu = true
    let action: () -> Void
    @ViewBuilder var accessory: Accessory

    @Environment(Player.self) private var player
    @Environment(\.client) private var client
    @State private var addsToPlaylist = false

    var body: some View {
        let isCurrent = player.current == track
        Button(action: action) {
            HStack(spacing: 12) {
                if let leading {
                    Text(leading).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(minWidth: 24)
                } else {
                    Cover(path: track.cover, size: 44)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).lineLimit(1).foregroundStyle(isCurrent ? Color.sage : .primary)
                    if leading == nil {
                        Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Image(systemName: "waveform")
                        .foregroundStyle(Color.sage)
                        .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                }
                accessory
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .macRowSpacing()
        .contextMenu {
            if menu {
                Button("Lire ensuite", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    player.playNext([track], using: client)
                }
                Button("À la fin de la pile", systemImage: "text.line.last.and.arrowtriangle.forward") {
                    player.enqueue([track], using: client)
                }
                Button("Ajouter à une playlist…", systemImage: "music.note.list") { addsToPlaylist = true }
                if let album = track.albumID {
                    NavigationLink(value: LocalAlbum(musicbrainzId: album, name: track.album, artistName: track.artist,
                                                     artistMbid: ArtistDirectory.shared.ref(id: track.artistID, named: track.artist)?.id,
                                                     year: nil, trackCount: nil, primaryFormat: nil, coverUrl: track.cover)) {
                        Label("Aller à l'album", systemImage: "square.stack")
                    }
                }
                if let artist = ArtistDirectory.shared.ref(id: track.artistID, named: track.artist) {
                    NavigationLink(value: artist) {
                        Label("Aller à l'artiste", systemImage: "music.microphone")
                    }
                }
            }
        }
        .sheet(isPresented: $addsToPlaylist) { PlaylistPicker(tracks: [track]) }
    }
}

extension TrackRow where Accessory == EmptyView {
    init(track: Track, leading: String? = nil, menu: Bool = true, action: @escaping () -> Void) {
        self.init(track: track, leading: leading, menu: menu, action: action) { EmptyView() }
    }
}

/// Une piste en pochette, pour les rayons comme « Dernières écoutes ».
struct TrackCard: View {
    let track: Track
    var width: CGFloat = 150
    /// Le bouton lecture au survol, comme sur les albums.
    var play: (() -> Void)?

    @Environment(Player.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Cover(path: track.cover, size: width, radius: 8)
                .hoverPlay("Lire \(track.title)", enabled: play != nil, active: player.current == track) { play?() }
                .overlay(alignment: .bottomTrailing) {
                    if player.current == track {
                        Image(systemName: "waveform")
                            .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                            .padding(6)
                            .background(.ultraThinMaterial, in: .circle)
                            .padding(6)
                    }
                }
            Text(track.title).font(.subheadline.weight(.medium)).lineLimit(1)
            Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: width)
        .foregroundStyle(.primary)
    }
}

extension LocalAlbum {
    /// D'où vient la pile, pour « Dernières écoutes ».
    var source: PlaySource {
        PlaySource(kind: .album, id: musicbrainzId, title: name, subtitle: artistName, covers: cover.map { [$0] } ?? [])
    }

    /// Ses plages dans les bacs, dans l'ordre du disque ; aucune s'il n'y est pas.
    func tracks(using client: DroppedNeedle) async -> [Track] {
        ((try? await client.tracks(of: musicbrainzId)) ?? [])
            .sorted { ($0.discNumber ?? 1, $0.trackNumber) < ($1.discNumber ?? 1, $1.trackNumber) }
            .map { $0.track(in: self) }
    }
}

/// Une carte d'album pour les grilles et les rayons, comme sur le web.
struct AlbumCard: View {
    let album: LocalAlbum
    var width: CGFloat?
    /// L'album est dans les bacs : au survol du pointeur, un bouton le lance sans ouvrir sa page.
    var playable = true

    @Environment(Player.self) private var player
    @Environment(\.client) private var client

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Cover(path: album.cover, size: width, radius: 8)
                .hoverPlay("Lire \(album.name)", enabled: playable, active: album.source.same(as: player.currentSource)) {
                    let tracks = await album.tracks(using: client)
                    if !tracks.isEmpty { player.play(tracks, source: album.source, using: client) }
                }
            Text(album.name).font(.subheadline.weight(.medium)).lineLimit(1)
            Text(album.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: width)
        .foregroundStyle(.primary)
    }
}

extension View {
    /// Au survol du pointeur (Mac, iPad), un bouton lecture sur la pochette : on lance sans ouvrir la page.
    /// `alignment` : en haut quand le titre est écrit en bas de la pochette.
    /// `active` : c'est ce qui joue ; le bouton reste affiché, et met en pause.
    func hoverPlay(_ label: String, enabled: Bool = true, active: Bool = false, alignment: Alignment = .bottomLeading,
                   play: @escaping () async -> Void) -> some View {
        modifier(HoverPlay(label: label, enabled: enabled, active: active, alignment: alignment, play: play))
    }
}

private struct HoverPlay: ViewModifier {
    let label: String
    let enabled: Bool
    let active: Bool
    let alignment: Alignment
    let play: () async -> Void

    @Environment(Player.self) private var player

    // `-platineHover YES` : le bouton affiché partout, pour les captures sans pointeur.
    #if DEBUG
    @State private var hovering = UserDefaults.standard.bool(forKey: "platineHover")
    #else
    @State private var hovering = false
    #endif
    @State private var starting = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: alignment) {
                if enabled, hovering || starting || active {
                    // Pendant le chargement, déjà l'icône de pause : le clic a été entendu.
                    let playing = starting || (active && player.isPlaying)
                    Button {
                        if active { return player.toggle() }
                        starting = true
                        Task {
                            await play()
                            starting = false
                        }
                    } label: {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .background(Color.sage, in: .circle)
                        .foregroundStyle(Color.base100)
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    .accessibilityLabel(playing ? "Pause" : label)
                }
            }
            .animation(.easeOut(duration: 0.15), value: hovering || active)
            .onHover { hovering = $0 }
    }
}

/// Une ligne d'album : pochette, titre, artiste, et ce qu'on veut à droite.
struct AlbumRow<Accessory: View>: View {
    let cover: String?
    let title: String
    let subtitle: String
    var detail: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            Cover(path: cover)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            accessory
        }
        .listRowBackground(Color.clear)
        .macRowSpacing()
    }
}

/// Demande un album, et montre où en est la demande.
struct RequestButton: View {
    let album: AlbumRequest
    var alreadyThere = false
    /// Une fois la demande acceptée par le serveur.
    var onSent: () -> Void = {}

    @Environment(\.client) private var client
    @State private var state = State.idle

    private enum State { case idle, sending, done, failed(String) }

    var body: some View {
        switch state {
        case _ where alreadyThere:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .idle:
            Button("Demander") { send() }.buttonStyle(.bordered).controlSize(.small)
        case .sending:
            ProgressView()
        case .done:
            Image(systemName: "clock.badge.checkmark").foregroundStyle(.tint)
        case let .failed(message):
            Button { send() } label: { Image(systemName: "exclamationmark.triangle") }
                .foregroundStyle(.red)
                .help(message)
        }
    }

    private func send() {
        state = .sending
        Task {
            do {
                _ = try await client.request(album)
                state = .done
                onSent()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

/// Une liste chargée depuis l'API, avec ses états vide, en cours et en erreur.
struct Loaded<Value, Content: View>: View {
    let load: () async throws -> Value
    /// Le changer recharge, sans repasser par le chargement à vide.
    var reloadKey = 0
    /// Une page en rayons plutôt qu'en lignes : le squelette prend sa forme.
    var shelves = false
    @ViewBuilder var content: (Value) -> Content

    @SwiftUI.State private var result: Result<Value, Error>?

    var body: some View {
        Group {
            switch result {
            case nil:
                if shelves {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            ForEach(["À écouter", "Fraîchement pressés", "Tes albums"], id: \.self) { SkeletonShelf(title: $0) }
                        }
                        .padding(.vertical)
                    }
                    .scrollDisabled(true)
                } else {
                    SkeletonList()
                }
            case let .success(value):
                content(value)
            case let .failure(error):
                ContentUnavailableView(
                    "Impossible de charger",
                    systemImage: "wifi.exclamationmark",
                    description: Text(error.localizedDescription)
                )
            }
        }
        .task(id: reloadKey) { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        do { result = .success(try await load()) } catch { result = .failure(error) }
    }
}
