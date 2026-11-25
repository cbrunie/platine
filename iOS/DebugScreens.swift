#if DEBUG
import SwiftUI

/// Pour les captures de vérification : `-platineScreen <nom>` au lancement ouvre
/// directement un écran, sans toucher au code. Absent des builds Release.
enum DebugScreen {
    static let name = UserDefaults.standard.string(forKey: "platineScreen")
    static let login = name == "login"
    /// `-platineAnchor 0.6` : la page artiste ouverte à cette hauteur (0 le haut, 1 le bas), pour les captures.
    static let anchor = UnitPoint(x: 0, y: UserDefaults.standard.double(forKey: "platineAnchor"))
    /// `-platineSlow YES` : la page artiste reste en chargement, pour photographier ses squelettes.
    static let slow = UserDefaults.standard.bool(forKey: "platineSlow")

    /// `-platineScrollScript "900,0,-1"` : fait défiler la page à ces hauteurs (« end » : tout en bas), une étape toutes les
    /// 5 s après 8 s, pour tester sans toucher à la souris ni au focus.
    static func runScrollScript() async {
        let steps = UserDefaults.standard.string(forKey: "platineScrollScript")?.split(separator: ",").compactMap { $0 == "end" ? -1 : Double($0) } ?? []
        guard !steps.isEmpty else { return }
        try? await Task.sleep(for: .seconds(3))
        for step in steps {
            try? await Task.sleep(for: .seconds(5))
            let root = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            // Les listes d'abord : la fenêtre a d'autres défileurs, plus grands, qui ne défilent pas.
            let all = root.flatMap(scrollViews).filter { $0.window != nil && !$0.isHidden }
            let lists = all.filter { $0 is UICollectionView && $0.contentSize.height > $0.bounds.height }
            let scroll = (lists.isEmpty ? all : lists).max { $0.bounds.height * $0.bounds.width < $1.bounds.height * $1.bounds.width }
            print("platine scroll:", scroll.map { "\(type(of: $0)) \($0.frame) \($0.contentSize)" } ?? "aucun", all.count)
            guard let scroll else { continue }
            // « end » : tout en bas. Une liste ne connaît sa hauteur qu'au fil du défilement : on vise sa dernière ligne.
            if step < 0, let list = scroll as? UICollectionView, list.numberOfSections > 0 {
                let section = list.numberOfSections - 1
                let row = list.numberOfItems(inSection: section) - 1
                if row >= 0 { list.scrollToItem(at: IndexPath(item: row, section: section), at: .bottom, animated: true) }
            } else {
                let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
                scroll.setContentOffset(CGPoint(x: 0, y: step < 0 ? bottom : step - scroll.adjustedContentInset.top), animated: true)
            }
        }
    }

    private static func scrollViews(in view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

    @ViewBuilder
    static func view(_ name: String) -> some View {
        NavigationStack {
            Group {
                switch name {
                case "library": LibraryView()
                case "albums": AlbumsView()
                case "artists": ArtistsView()
                case "tracks": TracksView()
                case "playlists": PlaylistsView()
                case "search": SearchView()
                case "requests": RequestsView()
                case "downloads": DownloadsView()
                case "following": FollowingView()
                case "cities": CitiesView()
                case "concerts": ConcertsView()
                case "controls": LibraryControlsView()
                case "analysis": ActivityPane().paneStyle("Analyse")
                case "organize": OrganizePane().paneStyle("Ranger")
                case "review": ReviewPane().paneStyle("Revue")
                case "automation": AutomationPane().paneStyle("Automatisation")
                case "history": HistoryPane().paneStyle("Historique")
                case "artist-desk": ArtistDeskView()
                case "recipe": QualityRecipeView()
                case "library-settings": LibrarySettingsView()
                case "indexers": IndexersView()
                case "users": UsersView()
                case "cache": CacheView()
                case "about": AboutView()
                case "settings": SettingsView()
                // Comme depuis la discothèque : sans identifiant d'artiste.
                // `-platineLocal "<id>|<titre>|<artiste>"` pour un autre album de la discothèque.
                case "album-local":
                    let pick = (UserDefaults.standard.string(forKey: "platineLocal")
                        ?? "3ed35bcb-96e2-5765-ad6f-3b13cf53114f|Origin of Symmetry|Muse").split(separator: "|").map(String.init)
                    AlbumView(album: LocalAlbum(musicbrainzId: pick[0], name: pick[1],
                                                artistName: pick[2], artistMbid: nil, year: nil, trackCount: 11,
                                                primaryFormat: "flac", coverUrl: DroppedNeedle.cover(nil, album: pick[0])))
                // `-platineAlbum "<mbid>|<titre>"` pour un autre album du catalogue.
                case "album-catalog":
                    let pick = (UserDefaults.standard.string(forKey: "platineAlbum") ?? "00054665-89fa-33d5-a8f0-1728ea8c32c3|Homework")
                        .split(separator: "|").map(String.init)
                    AlbumView(album: LocalAlbum(musicbrainzId: pick[0], name: pick[1],
                                                artistName: "Daft Punk", artistMbid: "056e4f3e-d505-4dad-8ec1-d04f521cbb56",
                                                year: 1997, trackCount: nil, primaryFormat: nil, coverUrl: nil))
                case "advanced": FormPanel(title: "Avancé", spec: .advanced)
                // `-platineArtist "<mbid>|<nom>"` pour un autre artiste que Daft Punk.
                case "artist":
                    let pick = (UserDefaults.standard.string(forKey: "platineArtist") ?? "056e4f3e-d505-4dad-8ec1-d04f521cbb56|Daft Punk")
                        .split(separator: "|").map(String.init)
                    ArtistView(artist: ArtistRef(id: pick[0], name: pick.count > 1 ? pick[1] : ""))
                case "radio": RadioView(seedType: "artist", seedID: "056e4f3e-d505-4dad-8ec1-d04f521cbb56", title: "Daft Punk")
                case "chart": ChartView(chart: .popular, title: "Populaire en ce moment")
                case "mixes": MixesPreview()
                case "playlist": FirstPlaylist()
                default: HomeView()
                }
            }
            .platineDestinations()
        }
    }
}
/// `-platineScreen mixes` : toutes les pochettes de Daily Mix et de décennies d'un coup, pour les captures.
private struct MixesPreview: View {
    @Environment(\.client) private var client
    @State private var mixes: [HomeSection] = []
    @State private var decades: [Decade] = []

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 16)], spacing: 20) {
                ForEach(Array(mixes.enumerated()), id: \.offset) { DailyMixCard(mix: $0.element) }
                ForEach(decades) { DecadeCard(decade: $0, subtitle: "Mix de ta discothèque") }
            }
            .padding()
        }
        .platineBackground()
        .task {
            async let found = try? client.discover().dailyMixes
            async let years = try? client.decades().items
            (mixes, decades) = await ((found ?? nil) ?? [], years ?? [])
        }
    }
}
/// `-platineScreen playlist` : la première playlist (`-platinePlaylist 2` pour la troisième).
private struct FirstPlaylist: View {
    @Environment(\.client) private var client
    @State private var summary: PlaylistSummary?

    var body: some View {
        Group { if let summary { PlaylistView(summary: summary) } else { Color.clear } }
            .task {
                let all = (try? await client.playlists().playlists) ?? []
                let pick = UserDefaults.standard.integer(forKey: "platinePlaylist")
                summary = all.indices.contains(pick) ? all[pick] : all.first
            }
    }
}
#else
import SwiftUI

enum DebugScreen {
    static let login = false
    static let anchor = UnitPoint.top
}
#endif
