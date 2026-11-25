#if canImport(CarPlay)
import CarPlay

/// Platine dans la voiture : trois onglets — le bac, les albums récents, les
/// playlists — et l'écran « À l'écoute » de CarPlay, nourri par le lecteur.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interface: CPInterfaceController?

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        interface = interfaceController
        guard let client = Session.shared.client else {
            let template = CPListTemplate(title: "Platine", sections: [])
            template.emptyViewTitleVariants = ["Connecte-toi sur l'iPhone"]
            template.emptyViewSubtitleVariants = ["Ouvre Platine et pose l'aiguille."]
            interfaceController.setRootTemplate(template, animated: false, completion: nil)
            return
        }
        Player.shared.connect(client)

        let crate = tab("Dans le bac", symbol: "opticaldisc.fill")
        let albums = tab("Récents", symbol: "square.stack.fill")
        let playlists = tab("Playlists", symbol: "music.note.list")
        interfaceController.setRootTemplate(CPTabBarTemplate(templates: [crate, albums, playlists]),
                                            animated: false, completion: nil)

        Task {
            if let items = try? await client.crate().items {
                let tracks = items.map(\.track)
                fill(crate, client: client, rows: tracks.enumerated().map { index, track in
                    (track.title, track.artist, track.cover, { Player.shared.play(tracks, from: index, using: client) })
                })
            }
        }
        Task {
            if let recent = try? await client.recentAlbums() {
                fill(albums, client: client, rows: recent.map { album in
                    (album.name, album.artistName, album.cover, {
                        let tracks = ((try? await client.tracks(of: album.musicbrainzId)) ?? []).map { $0.track(in: album) }
                        Player.shared.play(tracks, using: client)
                    })
                })
            }
        }
        Task {
            if let list = try? await client.playlists().playlists {
                fill(playlists, client: client, rows: list.map { playlist in
                    (playlist.name, playlist.trackCount.map { "\($0) plages" }, playlist.covers.first ?? nil, {
                        let tracks = ((try? await client.playlist(playlist.id).tracks) ?? []).compactMap(\.track)
                        Player.shared.play(tracks, using: client)
                    })
                })
            }
        }
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        interface = nil
    }

    private func tab(_ title: String, symbol: String) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        template.tabTitle = title
        template.tabImage = UIImage(systemName: symbol)
        template.emptyViewTitleVariants = ["Chargement…"]
        return template
    }

    /// Une ligne par disque ; la toucher le pose sur la platine et ouvre « À l'écoute ».
    private func fill(_ template: CPListTemplate, client: DroppedNeedle,
                      rows: [(title: String, detail: String?, cover: String?, play: @MainActor () async -> Void)]) {
        let items = rows.map { row in
            let item = CPListItem(text: row.title, detailText: row.detail)
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    await row.play()
                    completion()
                    self?.interface?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                }
            }
            if let cover = row.cover {
                Task { if let image = await Cover.load(cover, client: client) { item.setImage(image) } }
            }
            return item
        }
        template.emptyViewTitleVariants = ["Rien ici pour l'instant"]
        template.updateSections([CPListSection(items: items)])
    }
}
#endif
