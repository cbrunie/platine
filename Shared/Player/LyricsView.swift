import SwiftUI

/// Les paroles, comme dans Musique : la ligne chantée en blanc, les autres
/// estompées, le texte qui défile tout seul ; un tap sur une ligne y saute.
struct LyricsView: View {
    let track: Track?

    @Environment(\.client) private var client
    @Environment(Player.self) private var player
    @State private var lyrics: Lyrics?
    @State private var missing = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let lyrics, lyrics.isSynced {
                        ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.display(26, relativeTo: .title))
                                .foregroundStyle(.white.opacity(index == current ? 1 : 0.32))
                                .blur(radius: index == current ? 0 : 0.6)
                                .animation(.easeOut(duration: 0.3), value: current)
                                .onTapGesture { if let start = line.startSeconds { player.seek(to: start) } }
                                .id(index)
                        }
                    } else if let lyrics {
                        Text(lyrics.text).font(.title3.weight(.medium)).foregroundStyle(.white.opacity(0.9))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 60)
            }
            .scrollIndicators(.hidden)
            .onChange(of: current) { _, line in
                guard let line else { return }
                withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(line, anchor: .center) }
            }
        }
        .overlay {
            if missing {
                ContentUnavailableView("Pas de paroles sur cette plage", systemImage: "quote.bubble")
            } else if lyrics == nil, track != nil {
                ProgressView()
            }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                     .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .task(id: track?.id) {
            lyrics = nil
            missing = false
            guard let track else { return }
            do { lyrics = try await client.lyrics(track.id) } catch { missing = true }
        }
    }

    /// La dernière ligne commencée.
    private var current: Int? {
        guard let lines = lyrics?.lines, lyrics?.isSynced == true else { return nil }
        return lines.lastIndex { ($0.startSeconds ?? .infinity) <= player.elapsed + 0.2 }
    }
}
