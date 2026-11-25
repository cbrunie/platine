import SwiftUI

/// La platine de la Listening Room : un vinyle à sillons sous du Liquid Glass,
/// la pochette en étiquette, et un bras qui se pose quand la musique joue.
struct Turntable: View {
    let cover: String?
    let isPlaying: Bool
    /// Sans bras, pour un disque seul en décor.
    var showsArm = true

    /// Un tour en 4,2 s, comme `.vinyl-spin` sur le web.
    private static let secondsPerTurn = 4.2

    /// Le temps déjà tourné avant la dernière mise en route : le disque
    /// s'arrête là où il est, et repart de là.
    @State private var spun: TimeInterval = 0
    @State private var since: Date?

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                TimelineView(.animation(paused: !isPlaying)) { context in
                    let turned = spun + (since.map { context.date.timeIntervalSince($0) } ?? 0)
                    record(side)
                        .rotationEffect(.degrees(turned / Self.secondsPerTurn * 360))
                }
                // Le verre reste fixe : seuls les sillons et l'étiquette tournent dessous.
                .glassEffect(.clear, in: .circle)

                // Le reflet ne tourne pas avec le disque.
                Circle()
                    .fill(EllipticalGradient(colors: [.white.opacity(0.08), .clear],
                                             center: UnitPoint(x: 0.33, y: 0.27), endRadiusFraction: 0.58))
                    .allowsHitTesting(false)

                if showsArm { tonearm(side) }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .onChange(of: isPlaying, initial: true) { _, playing in
            if playing {
                since = .now
            } else {
                spun += since.map { Date.now.timeIntervalSince($0) } ?? 0
                since = nil
            }
        }
    }

    private func record(_ side: CGFloat) -> some View {
        ZStack {
            // Un vinyle fumé : assez transparent pour que le verre laisse passer le fond.
            Circle()
                .fill(EllipticalGradient(colors: [Color(hex: 0x1A2216).opacity(0.78), Color.base100.opacity(0.9)],
                                         endRadiusFraction: 0.48))

            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                for radius in stride(from: size.width * 0.17, to: size.width * 0.49, by: 2) {
                    let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                      width: radius * 2, height: radius * 2))
                    context.stroke(ring, with: .color(.white.opacity(0.05)), lineWidth: 0.5)
                }
            }

            ForEach([0.09, 0.18, 0.27], id: \.self) { inset in
                Circle()
                    .strokeBorder(.white.opacity(0.07), lineWidth: 1)
                    .padding(side * inset)
            }

            Group {
                if let cover {
                    Cover(path: cover, size: side * 0.33, radius: 0)
                } else {
                    // Sans disque en cours, l'étiquette sauge de l'icône.
                    Circle()
                        .fill(RadialGradient(colors: [Color(hex: 0xD2EAB8), Color(hex: 0x9FC27F)],
                                             center: UnitPoint(x: 0.35, y: 0.35), startRadius: 0, endRadius: side * 0.2))
                        .overlay(Circle().strokeBorder(Color.base100.opacity(0.25), lineWidth: 1.5).padding(side * 0.045))
                        .frame(width: side * 0.33, height: side * 0.33)
                }
            }
                .clipShape(.circle)
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 4, y: 2)

            Circle()
                .fill(Color.base100)
                .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                .frame(width: side * 0.03)
        }
        .frame(width: side, height: side)
    }

    /// Le bras de lecture pivote dans le coin haut droit, hors du disque — et,
    /// le disque étant agrandi, hors de l'écran. Au repos il en sort tout
    /// entier ; en lecture il entre en biais et pose sa cellule sur les sillons.
    private func tonearm(_ side: CGFloat) -> some View {
        let length = side * 0.58
        let pivot = UnitPoint(x: 0.93, y: 0.07)
        let width = side * 0.04
        let metal = LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.4)],
                                   startPoint: .leading, endPoint: .trailing)
        // Le bras vit dans un cadre de la taille du disque qui tourne autour du
        // pivot : un cadre propre au bras, posé hors de l'écran, ne serait pas dessiné.
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                Capsule()
                    .fill(metal)
                    .frame(width: side * 0.016)
                    .shadow(color: .black.opacity(0.5), radius: 3, x: 2, y: 3)
                // La cellule, puis le diamant qui touche le disque.
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.base300)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.5), lineWidth: 1))
                    .frame(width: width, height: side * 0.055)
                    .shadow(color: .black.opacity(0.5), radius: 3, x: 2, y: 3)
                Capsule()
                    .fill(Color.sage)
                    .frame(width: 2, height: side * 0.012)
            }
            .frame(width: width, height: length, alignment: .top)
            .offset(x: side * pivot.x - width / 2, y: side * pivot.y)

            // Le contrepoids derrière l'axe, puis l'axe lui-même.
            Capsule()
                .fill(Color.base300)
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .frame(width: side * 0.035, height: side * 0.05)
                .offset(x: side * (pivot.x - 0.0175), y: side * (pivot.y - 0.06))
            Circle()
                .fill(Color.base200)
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 2))
                .frame(width: side * 0.06, height: side * 0.06)
                .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
                .offset(x: side * (pivot.x - 0.03), y: side * (pivot.y - 0.03))
        }
        .frame(width: side, height: side, alignment: .topLeading)
        .rotationEffect(.degrees(isPlaying ? 20 : -5), anchor: pivot)
        .animation(.spring(duration: 0.9, bounce: 0.3), value: isPlaying)
        .allowsHitTesting(false)
    }
}
