import SwiftUI

/// La file de suggestions de DroppedNeedle, avec la raison de chacune.
struct DiscoverView: View {
    @Environment(\.client) private var client

    var body: some View {
        Loaded(load: client.discoverQueue) { queue in
            if queue.items.isEmpty {
                ContentUnavailableView("Pas de suggestion pour l'instant", systemImage: "sparkles")
            } else {
                List(queue.items) { item in
                    AlbumRow(
                        cover: item.coverUrl,
                        title: item.albumName,
                        subtitle: item.artistName,
                        detail: item.recommendationReason
                    ) {
                        RequestButton(
                            album: AlbumRequest(
                                musicbrainzId: item.releaseGroupMbid,
                                artist: item.artistName,
                                album: item.albumName,
                                year: nil
                            ),
                            alreadyThere: item.inLibrary
                        )
                    }
                }
                .listStyle(.plain)
            }
        }
        .platineBackground()
        .navigationTitle("Découvrir")
    }
}
