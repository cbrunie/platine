import AVKit
import Combine
import MediaPlayer
import SwiftUI

/// La barre de lecture fine de Musique : sans curseur, elle s'épaissit sous le doigt.
struct Scrubber: View {
    let elapsed: Double
    let duration: Double
    /// La position sous le doigt, partagée avec les compteurs de temps.
    @Binding var scrubbing: Double?
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let total = max(duration, 1)
            let progress = min(max((scrubbing ?? elapsed) / total, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(.white.opacity(scrubbing == nil ? 0.6 : 0.9))
                    .frame(width: geometry.size.width * progress)
            }
            .frame(height: scrubbing == nil ? 7 : 12)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        scrubbing = min(max(drag.location.x / geometry.size.width, 0), 1) * total
                    }
                    .onEnded { _ in
                        if let scrubbing { seek(scrubbing) }
                        scrubbing = nil
                    }
            )
            .animation(.spring(duration: 0.3), value: scrubbing == nil)
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue(clock(elapsed))
        .accessibilityAdjustableAction { direction in
            seek(elapsed + (direction == .increment ? 15 : -15))
        }
    }
}

/// La barre de volume de Musique. Elle règle le volume du système par un
/// MPVolumeView caché (seul moyen public), et suit les boutons de l'iPhone.
/// Le simulateur et le Mac n'ont pas de volume système réglable : on y règle celui de l'app.
struct VolumeBar: View {
    @Environment(Player.self) private var player
    @State private var level = AVAudioSession.sharedInstance().outputVolume
    @State private var slider: UISlider?
    @State private var dragging = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                    Capsule().fill(.white.opacity(dragging ? 0.9 : 0.6))
                        .frame(width: geometry.size.width * CGFloat(level))
                }
                .frame(height: dragging ? 12 : 7)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            dragging = true
                            set(Float(min(max(drag.location.x / geometry.size.width, 0), 1)))
                        }
                        .onEnded { _ in dragging = false }
                )
                .animation(.spring(duration: 0.3), value: dragging)
            }
            .frame(height: 24)
            Image(systemName: "speaker.wave.3.fill")
        }
        .background { HiddenVolumeView(slider: $slider).frame(width: 1, height: 1).opacity(0.01) }
        .onReceive(AVAudioSession.sharedInstance().publisher(for: \.outputVolume).receive(on: RunLoop.main)) {
            if !dragging, !Self.simulator { level = $0 }
        }
        .onAppear { if Self.simulator { level = player.volume } }
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue(Text(Double(level), format: .percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            set(min(max(level + (direction == .increment ? 0.1 : -0.1), 0), 1))
        }
    }

    private func set(_ value: Float) {
        level = value
        if Self.simulator { player.volume = value } else { slider?.value = value }
    }

    #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
    private static let simulator = true
    #else
    private static let simulator = false
    #endif
}

private struct HiddenVolumeView: UIViewRepresentable {
    @Binding var slider: UISlider?

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        Task { slider = view.subviews.lazy.compactMap { $0 as? UISlider }.first }
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}
}

/// Un vinyle dessiné : le bord, un sillon, l'étiquette et son trou.
struct VinylGlyph: View {
    var body: some View {
        ZStack {
            Circle().strokeBorder(lineWidth: 2)
            Circle().strokeBorder(lineWidth: 1).padding(5).opacity(0.6)
            Circle().frame(width: 7, height: 7)
            Circle().fill(.black).frame(width: 2, height: 2).blendMode(.destinationOut)
        }
        .compositingGroup()
        .frame(width: 22, height: 22)
    }
}

/// Le bouton AirPlay du système.
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor.white.withAlphaComponent(0.7)
        view.activeTintColor = UIColor(Color.sage)
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

/// Sous les commandes, comme dans Musique : « À suivre » quand un disque
/// tourne (on y saute, on remonte, on retire, on mélange ; quand la pile
/// s'épuise, le lecteur la complète depuis le bac), et le bac lui-même
/// quand la platine est à l'arrêt.
struct QueueSection: View {
    @Environment(Player.self) private var player
    @Environment(\.client) private var client
    @State private var crate: [CrateTrack]?

    var body: some View {
        if player.current == nil { idle } else { upNext }
    }

    private var upNext: some View {
        let upcoming = Array(player.upcoming)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    ShelfTitle("À suivre")
                    Text("Puis des disques tirés du bac").font(.caption).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Button { player.shuffleUpcoming() } label: { Image(systemName: "shuffle") }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Mélanger la pile")
                    .disabled(upcoming.count < 2)
                // Comme dans Musique : rien, toute la pile, puis le morceau seul.
                Button {
                    player.repeatMode = switch player.repeatMode {
                    case .off: .all
                    case .all: .one
                    case .one: .off
                    }
                } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .foregroundStyle(player.repeatMode == .off ? Color.white : Color.base100)
                }
                .buttonStyle(.glass)
                .tint(player.repeatMode == .off ? nil : Color.sage)
                .background(player.repeatMode == .off ? Color.clear : Color.sage, in: .capsule)
                .accessibilityLabel("Répéter")
                .accessibilityValue(["off": "Non", "all": "La pile", "one": "Ce morceau"][player.repeatMode.rawValue] ?? "")
            }

            LazyVStack(spacing: 14) {
                ForEach(Array(upcoming.enumerated()), id: \.element.id) { offset, track in
                    TrackRow(track: track, menu: false) { player.jump(to: player.index + 1 + offset) }
                        .contextMenu {
                            Button("Lire maintenant", systemImage: "play.fill") {
                                player.jump(to: player.index + 1 + offset)
                            }
                            Button("Mettre en haut de la pile", systemImage: "arrow.up.to.line") {
                                player.moveUpcoming(from: IndexSet(integer: offset), to: 0)
                            }
                            Button("Retirer de la pile", systemImage: "minus.circle", role: .destructive) {
                                player.removeUpcoming(at: IndexSet(integer: offset))
                            }
                        }
                        .onAppear { if offset >= upcoming.count - 3 { player.refillIfNeeded() } }
                }
                if upcoming.isEmpty {
                    if player.refilling {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("La pile est vide.").font(.subheadline).foregroundStyle(.white.opacity(0.5))
                            .onAppear { player.refillIfNeeded() }
                    }
                }
            }
        }
    }

    /// Platine à l'arrêt : le bac de la Listening Room, prêt à poser.
    private var idle: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShelfTitle("Dans le bac")
            LazyVStack(spacing: 14) {
                switch crate {
                case nil:
                    ProgressView().frame(maxWidth: .infinity)
                case let items? where items.isEmpty:
                    Text("Le bac est vide.").font(.subheadline).foregroundStyle(.white.opacity(0.5))
                case let items?:
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        TrackRow(track: item.track) {
                            player.play(items.map(\.track), from: index, using: client)
                        }
                    }
                }
            }
        }
        .task {
            // Une erreur réseau laisse le bac vide plutôt qu'un chargement sans fin.
            crate = (try? await client.crate().items) ?? []
        }
    }
}
