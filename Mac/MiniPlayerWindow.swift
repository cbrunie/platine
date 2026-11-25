#if targetEnvironment(macCatalyst)
import SwiftUI

/// La barre de titre du Mac et la hauteur des capsules posées à côté des feux.
enum MacTitlebar {
    static let capsuleHeight: CGFloat = 36

    /// Le titre de la page dans la barre de la fenêtre ; masqué pendant le lecteur, comme Musique.
    static func setTitleHidden(_ hidden: Bool) {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.titlebar?.titleVisibility = hidden ? .hidden : .visible
            scene.titlebar?.separatorStyle = .none
        }
    }
}

/// Le mini-lecteur : une petite fenêtre à part, la platine et l'essentiel.
struct MiniPlayerWindow: View {
    static let id = "mini-player"

    @Environment(Player.self) private var player

    var body: some View {
        let track = player.current
        VStack(spacing: 14) {
            Turntable(cover: track?.cover, isPlaying: player.isPlaying)
                .frame(width: 240, height: 240)
            VStack(spacing: 2) {
                Text(track?.title ?? "Platine à l'arrêt").font(.headline).lineLimit(1)
                Text(track?.artist ?? " ").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 34) {
                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.largeTitle)
                        .frame(width: 40)
                        .contentTransition(.symbolEffect(.replace))
                }
                Button { player.next() } label: { Image(systemName: "forward.fill") }
            }
            .font(.title2)
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .background {
            ZStack {
                Color.base100
                Cover(path: track?.cover, size: nil, radius: 0).scaleEffect(2).blur(radius: 60).opacity(0.4)
            }
            .ignoresSafeArea()
        }
        .background(SceneConfigurator { scene in
            scene.titlebar?.titleVisibility = .hidden
            scene.sizeRestrictions?.minimumSize = CGSize(width: 300, height: 400)
            scene.sizeRestrictions?.maximumSize = CGSize(width: 300, height: 400)
        })
    }
}

/// Règle la scène de la fenêtre qui contient la vue, et seulement elle.
private struct SceneConfigurator: UIViewRepresentable {
    let configure: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> Probe { Probe(configure: configure) }
    func updateUIView(_ view: Probe, context: Context) {}

    final class Probe: UIView {
        let configure: (UIWindowScene) -> Void

        init(configure: @escaping (UIWindowScene) -> Void) {
            self.configure = configure
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { configure(scene) }
        }
    }
}
#endif
