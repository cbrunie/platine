import SwiftUI

/// La barre au-dessus des onglets, comme dans Musique : un tap ouvre le lecteur.
struct MiniPlayer: View {
    @Environment(Player.self) private var player

    var body: some View {
        let track = player.current
        HStack(spacing: 10) {
            Cover(path: track?.cover, size: 30, radius: 15)
            VStack(alignment: .leading, spacing: 0) {
                Text(track?.title ?? "Platine à l'arrêt")
                    .font(.subheadline.weight(.medium)).lineLimit(1)
                if let error = player.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.yellow).lineLimit(1)
                } else if let track {
                    Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Lecture")
            Button { player.next() } label: { Image(systemName: "forward.fill") }
                .accessibilityLabel("Suivant")
                .disabled(track == nil)
        }
        .font(.title3)
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .contentShape(.rect)
    }
}
