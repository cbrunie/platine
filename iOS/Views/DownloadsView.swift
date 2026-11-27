import SwiftUI

/// Les téléchargements, comme la page du web : ce qui arrive, ce qui est
/// arrivé, ce qui a échoué, et les fichiers mis de côté pour vérification.
/// La liste se rafraîchit seule tant qu'elle est à l'écran.
struct DownloadsView: View {
    enum Filter: String, CaseIterable {
        case active = "En cours"
        case done = "Arrivés"
        case failed = "Échecs"
        case held = "À vérifier"
    }

    @Environment(\.client) private var client
    @State private var filter = Filter.active
    @State private var tasks: [JSON] = []
    @State private var held: [JSON] = []
    @State private var alert: ServerAlert?

    private static let active: Set<String> = ["queued", "downloading", "processing"]
    private static let done: Set<String> = ["completed", "partial"]

    var body: some View {
        List {
            FilterChips(options: Filter.allCases.map { ($0.rawValue, $0.rawValue) },
                        selection: Binding(get: { filter.rawValue }, set: { filter = Filter(rawValue: $0) ?? .active }))
                .bareRow()

            if filter == .held {
                ForEach(held.indices, id: \.self) { heldRow(held[$0]) }
            } else {
                ForEach(shown.indices, id: \.self) { taskRow(shown[$0]) }
            }
        }
        .listStyle(.plain)
        .overlay {
            if filter == .held ? held.isEmpty : shown.isEmpty {
                ContentUnavailableView(Self.empty(filter), systemImage: "arrow.down.circle")
            }
        }
        .pageBackground()
        .navigationTitle("Téléchargements")
        .toolbar {
            Menu {
                Button("Réessayer tous les échecs", systemImage: "arrow.clockwise") { run("/downloads/retry-all-failed") }
                Button("Arrêter les nouveaux essais", systemImage: "stop.circle") { run("/downloads/stop-all-retries") }
                Button("Revérifier les fichiers mis de côté", systemImage: "checkmark.seal") { run("/downloads/held/reverify") }
                Button("Nettoyer la liste", systemImage: "trash", role: .destructive) { run("/downloads/clear") }
            } label: { Image(systemName: "ellipsis.circle") }
        }
        .serverAlert($alert)
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var shown: [JSON] {
        tasks.filter { task in
            let status = task["status"]?.string ?? ""
            return switch filter {
            case .active: Self.active.contains(status)
            case .done: Self.done.contains(status)
            case .failed: !Self.active.contains(status) && !Self.done.contains(status)
            case .held: false
            }
        }
    }

    private func taskRow(_ task: JSON) -> some View {
        let id = task["id"]?.string ?? ""
        let status = task["status"]?.string ?? ""
        let title = task["track_title"]?.string ?? task["album_title"]?.string ?? ""
        return HStack(spacing: 12) {
            Cover(path: DroppedNeedle.cover(nil, album: task["release_group_mbid"]?.string), size: 52, radius: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).oneLine()
                Text(task["artist_name"]?.string ?? "").font(.subheadline).foregroundStyle(.secondary).oneLine()
                HStack(spacing: 6) {
                    Pill(text: Self.statusName(status), color: Self.statusColor(status))
                    Text(task["source"]?.string?.capitalized ?? "").font(.caption).foregroundStyle(.secondary)
                }
                if status == "downloading", let progress = task["progress_percent"]?.number {
                    ProgressView(value: progress, total: 100).tint(Color.sage)
                }
                if let message = task["error_message"]?.string, !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(.yellow).lineLimit(2)
                }
            }
        }
        .listRowBackground(Color.clear)
        .swipeActions {
            if Self.active.contains(status) {
                Button("Annuler", role: .destructive) { run("/downloads/tasks/\(id)/cancel") }
                if task["has_next_source"]?.bool == true {
                    Button("Autre source") { run("/downloads/tasks/\(id)/next-source") }.tint(.indigo)
                }
            } else if !Self.done.contains(status) {
                Button("Réessayer") { run("/downloads/tasks/\(id)/retry") }.tint(.sage)
            }
        }
    }

    /// Un envoi mis de côté : un album ou une plage, avec ses fichiers et la raison de l'attente.
    private func heldRow(_ item: JSON) -> some View {
        let id = item["id"]?.int ?? 0
        let files = item["files"]?.array ?? []
        let first = files.first
        let title = item["album_title"]?.string ?? first?["track_title"]?.string ?? first?["original_name"]?.string ?? "Fichier"
        return VStack(alignment: .leading, spacing: 3) {
            Text(title).oneLine()
            Text([item["artist_name"]?.string, files.count > 1 ? "\(files.count) fichiers" : nil].compactMap(\.self)
                .joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.secondary).oneLine()
            Text(first?["reason_text"]?.string ?? first?["reason_detail"]?.string ?? "")
                .font(.caption).foregroundStyle(.yellow).lineLimit(2)
        }
        .listRowBackground(Color.clear)
        .swipeActions {
            // Sans liste de fichiers, l'action vaut pour tous ceux de l'envoi.
            Button("Écarter", role: .destructive) { run("/held/\(id)/discard", body: .object([:])) }
            Button("Importer") { run("/held/\(id)/import", body: .object([:])) }.tint(.sage)
            Button("Revérifier") { run("/held/\(id)/recheck", body: .object([:])) }.tint(.indigo)
        }
    }

    private func load() async {
        async let tasks = try? client.json("GET", "/downloads/tasks?page_size=100")
        async let held = try? client.json("GET", "/held")
        self.tasks = await tasks?["items"]?.array ?? self.tasks
        self.held = await held?["entries"]?.array ?? self.held
    }

    private func run(_ path: String, body: JSON? = nil) {
        Task {
            do {
                _ = try await client.json("POST", path, body: body)
                await load()
            } catch {
                alert = ServerAlert(title: "Téléchargements", message: error.localizedDescription)
            }
        }
    }

    private static func empty(_ filter: Filter) -> String {
        switch filter {
        case .active: "Rien en route"
        case .done: "Rien d'arrivé récemment"
        case .failed: "Aucun échec"
        case .held: "Rien à vérifier"
        }
    }

    static func statusName(_ status: String) -> String {
        [
            "queued": "En file", "pending": "En attente", "searching": "Recherche", "downloading": "Téléchargement",
            "processing": "Traitement", "importing": "Rangement", "retrying": "Nouvel essai", "completed": "Arrivé",
            "imported": "Dans les bacs", "partial": "Incomplet", "failed": "Échec", "cancelled": "Annulé",
        ][status] ?? status.capitalized
    }

    static func statusColor(_ status: String) -> Color {
        switch status {
        case "failed", "cancelled": .red
        case "partial", "retrying": .yellow
        case "completed", "imported": .sage
        default: .sky
        }
    }
}

/// Une plage de la radio qu'on n'a pas encore : on peut la demander, pas la lire.
struct PlannedTrack: Identifiable {
    let recording: String
    let title: String
    let artist: String
    let artistID: String?
    var album: String? = nil
    var albumID: String? = nil
    var releaseID: String? = nil

    var id: String { recording }

    var request: TrackRequest {
        TrackRequest(artistName: artist, trackTitle: title, albumTitle: album, durationSeconds: nil,
                     releaseGroupMbid: albumID, artistMbid: artistID, releaseId: releaseID)
    }

    /// Le plan de radio ne dit pas l'album : on le prend dans les morceaux phares de l'artiste,
    /// par enregistrement, sinon par titre.
    func onAlbum(from songs: [TopSong]) -> PlannedTrack {
        let key = Discography.titleKey(title)
        guard let song = songs.first(where: { $0.recordingMbid == recording })
            ?? songs.first(where: { Discography.titleKey($0.title) == key }) else { return self }
        var track = self
        track.album = song.releaseName
        track.albumID = song.releaseGroupMbid
        track.releaseID = song.originalReleaseMbid
        return track
    }
}

/// Les plages demandées depuis une radio rejoignent la pile dès qu'elles arrivent.
final class RadioArrivals {
    static let shared = RadioArrivals()

    private var waiting: [PlannedTrack] = []
    /// Tant que ce morceau est dans la pile, c'est encore cette radio qu'on écoute.
    private var anchor: Track?
    private var watcher: Task<Void, Never>?

    func watch(_ tracks: [PlannedTrack], anchor: Track, using client: DroppedNeedle) {
        if anchor != self.anchor { waiting = [] }
        self.anchor = anchor
        waiting += tracks
        guard watcher == nil else { return }
        watcher = Task {
            // Au-delà, le téléchargement est coincé : on arrête de demander au serveur.
            let deadline = Date.now.addingTimeInterval(2 * 3600)
            while !waiting.isEmpty, Date.now < deadline, let anchor = self.anchor, Player.shared.queue.contains(anchor) {
                try? await Task.sleep(for: .seconds(30))
                await check(using: client)
            }
            waiting = []
            watcher = nil
        }
    }

    private func check(using client: DroppedNeedle) async {
        guard let past = try? await client.requestHistory(pageSize: 100).items else { return }
        for track in waiting {
            let key = (Discography.titleKey(track.title), Discography.titleKey(track.artist))
            let status = past.first { $0.requestKind == "track" && $0.trackTitle.map(Discography.titleKey) == key.0
                && Discography.titleKey($0.artistName) == key.1 }?.status
            guard let status, RequestStatus.allowsNewRequest(status) else { continue }
            // Tout autre fin que l'import : elle ne viendra pas.
            guard status == "imported" else { waiting.removeAll { $0.id == track.id }; continue }
            // L'index de la discothèque peut avoir un peu de retard : on retentera au prochain tour.
            guard let found = try? await client.searchLibrary(track.title).tracks.first(where: {
                Discography.titleKey($0.title) == key.0 && Discography.titleKey($0.artistName) == key.1
            }) else { continue }
            var arrived = found.track
            arrived.artistID = track.artistID
            Player.shared.playNext([arrived], using: client)
            waiting.removeAll { $0.id == track.id }
        }
    }
}

/// Une radio partie d'un artiste ou d'un album : ses plages et celles d'artistes proches.
/// Ce qu'on a se lit tout de suite ; le reste se demande, et rejoint la pile en arrivant.
struct RadioView: View {
    let seedType: String
    var seedID: String? = nil
    /// Avec `seedType` « items » : la radio d'un mix, à partir de ses disques.
    var items: [HomeItem] = []
    let title: String

    @Environment(\.client) private var client
    @Environment(Player.self) private var player
    @State private var tracks: [Track]?
    @State private var missing: [PlannedTrack] = []
    /// Les plages déjà demandées et leur état, par enregistrement.
    @State private var requested: [String: String] = [:]
    @State private var failedRequests = 0
    /// Les artistes dont on connaît les albums : une demande part avec le sien.
    @State private var albumsKnown: Set<String> = []
    @State private var albums: Task<Void, Never>?
    @State private var error: String?
    @State private var confirmsRequests = false
    @State private var showsRequests = false

    private var seed: RadioSeed { RadioSeed(seedType: seedType, seedID: seedID, items: items, title: title) }
    /// Une radio de mix (« items ») ne se reconstruit pas depuis « Dernières écoutes » : ses plages y restent seules.
    private var source: PlaySource? {
        guard let seedID, items.isEmpty else { return nil }
        return PlaySource(kind: .radio, id: seedID, title: title, subtitle: "Station de radio",
                          covers: Array((tracks ?? []).compactMap(\.cover).prefix(4)), seedType: seedType)
    }

    private var toRequest: [PlannedTrack] { missing.filter { requested[$0.recording] == nil } }

    var body: some View {
        List {
            if let tracks, !tracks.isEmpty {
                Button { player.play(tracks, source: source, using: client) } label: {
                    Label("Lancer la radio", systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(Color.base100)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            if !toRequest.isEmpty {
                let count = toRequest.count
                let plages = count == 1 ? "1 plage" : "\(count) plages"
                Button { confirmsRequests = true } label: {
                    Label(tracks?.isEmpty == false ? "Lire et demander \(plages)" : "Demander \(plages)", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .confirmationDialog("Demander \(plages) ?", isPresented: $confirmsRequests, titleVisibility: .visible) {
                    Button(tracks?.isEmpty == false ? "Lire et demander" : "Demander") { playAndRequest() }
                    Button("Annuler", role: .cancel) {}
                } message: {
                    Text("Elles rejoindront la radio une fois téléchargées.")
                }
            }
            if let tracks {
                ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                    TrackRow(track: track) { player.play(tracks, from: index, using: client) }
                }
            }
            if !missing.isEmpty {
                ListHeading(title: "Pas encore dans tes bacs")
                Group {
                    if failedRequests > 0 {
                        Text(failedRequests == 1 ? "Une plage n'a pas pu être demandée." : "\(failedRequests) plages n'ont pas pu être demandées.")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(missing) { track in
                        HStack(spacing: 12) {
                            Cover(path: DroppedNeedle.cover(nil, album: track.albumID), size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title).oneLine().foregroundStyle(.secondary)
                                Text([track.artist, track.album].compactMap(\.self).joined(separator: " · "))
                                    .font(.subheadline).foregroundStyle(.secondary).oneLine()
                            }
                            Spacer(minLength: 0)
                            if track.artistID.map(albumsKnown.contains) ?? true {
                                TrackRequestButton(recording: track.recording, request: track.request,
                                                   status: requested[track.recording],
                                                   onSent: { sent(track, status: $0) }) { showsRequests = true }
                            } else {
                                ProgressView().frame(width: 30)
                            }
                        }
                        .listRowBackground(Color.clear)
                        .macRowSpacing()
                    }
                }
            }
            if let tracks, !tracks.isEmpty || !missing.isEmpty { notes(tracks) }
        }
        .listStyle(.plain)
        .overlay {
            if let error {
                ContentUnavailableView("Radio indisponible", systemImage: "dot.radiowaves.left.and.right", description: Text(error))
            } else if tracks == nil {
                SkeletonList()
            } else if tracks?.isEmpty == true, missing.isEmpty {
                ContentUnavailableView("Rien de semblable dans les bacs", systemImage: "dot.radiowaves.left.and.right")
            }
        }
        .pageBackground()
        .navigationTitle("Radio \(title)")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showsRequests) { RequestsView() }
        .task {
            do {
                let planned = try await seed.plan(using: client)
                tracks = planned.compactMap(RadioSeed.playable)
                async let active = try? client.activeRequests().items
                async let past = try? client.requestHistory(pageSize: 100).items
                requested = await RequestStatus.tracks(active: active ?? [], past: past ?? [])
                missing = planned.compactMap(requestable)
                loadAlbums()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func notes(_ tracks: [Track]) -> some View {
        PageFooter(lines: [Dates.summary(tracks: tracks.count, seconds: tracks.compactMap(\.duration).reduce(0, +))])
        let start = ["artist": "Artiste", "album": "Album", "genre": "Style", "items": "Mix"][seedType]
        let facts = FactsTable.known([
            ("Point de départ", start.map { "\($0) · \(title)" } ?? title),
            ("Dans tes bacs", tracks.isEmpty ? nil : tracks.count == 1 ? "1 plage" : "\(tracks.count) plages"),
            ("Pas encore dans tes bacs", missing.isEmpty ? nil : missing.count == 1 ? "1 plage" : "\(missing.count) plages"),
            ("Artistes", Credits.artists(tracks.map(\.artist) + missing.map(\.artist))),
        ])
        VStack(alignment: .leading, spacing: 12) {
            Text("Notes de pochette").font(.display(20, relativeTo: .title3))
            FactsTable(facts: facts)
        }
        .padding(.vertical, 20)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /// Sans enregistrement, le serveur ne sait pas la télécharger : on ne la montre pas.
    private func requestable(_ item: JSON) -> PlannedTrack? {
        guard item["local_file_id"]?.string == nil, let recording = item["recording_mbid"]?.string else { return nil }
        return PlannedTrack(recording: recording, title: item["track_name"]?.string ?? "",
                            artist: item["artist_name"]?.string ?? "",
                            artistID: item["artist_mbid"]?.string.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// À froid, le serveur met jusqu'à 30 s par artiste : les plages s'affichent d'abord, et leur album
    /// arrive artiste par artiste. Hors de `.task` pour qu'une demande en cours survive à la page.
    private func loadAlbums() {
        let client = client
        let artists = Set(missing.compactMap(\.artistID))
        albums = Task {
            await withTaskGroup(of: (String, [TopSong]).self) { group in
                for artist in artists {
                    group.addTask { (artist, (try? await client.topSongs(of: artist).songs) ?? []) }
                }
                for await (artist, songs) in group {
                    missing = missing.map { $0.artistID == artist ? $0.onAlbum(from: songs) : $0 }
                    albumsKnown.insert(artist)
                }
            }
        }
    }

    private func sent(_ track: PlannedTrack, status: String) {
        requested[track.recording] = status
        guard status != "already_in_library", let anchor = tracks?.first else { return }
        RadioArrivals.shared.watch([track], anchor: anchor, using: client)
    }

    private func playAndRequest() {
        if let tracks, !tracks.isEmpty { player.play(tracks, source: source, using: client) }
        failedRequests = 0
        // Une par une : le serveur reste libre de répondre à autre chose entre deux.
        Task {
            await albums?.value
            for track in toRequest {
                if let status = try? await client.requestTrack(track.recording, track.request).status {
                    sent(track, status: status)
                } else {
                    failedRequests += 1
                }
            }
        }
    }
}

/// De quoi monter une station : la page de la radio s'en sert, et les cartes de l'accueil pour la
/// lancer d'un clic.
struct RadioSeed {
    let seedType: String
    var seedID: String?
    var items: [HomeItem] = []
    let title: String

    /// Les plages qu'on a, prêtes à lire.
    func tracks(using client: DroppedNeedle) async -> [Track] {
        ((try? await plan(using: client)) ?? []).compactMap(Self.playable)
    }

    /// Le serveur, quand on lui donne un artiste, ne trouve pas toujours ses voisins et s'arrête
    /// à deux plages (jamais trois de suite du même) : on lui donne nous-mêmes les artistes.
    func plan(using client: DroppedNeedle) async throws -> [JSON] {
        // La radio d'un mix : d'abord ses disques, s'ils suffisent.
        var planned: [JSON] = []
        if !items.isEmpty {
            planned = Self.spread(try await radioPlan(using: client, ["seed_type": .string("items"), "mode": .string("library"), "items": .array(items.compactMap { item in
                guard let album = item.mbid, let artist = item.artistMbid else { return nil }
                return .object(["artist_mbid": .string(artist), "artist_name": .string(item.artistName ?? ""),
                                "album_mbid": .string(album), "album_name": .string(item.name)])
            })]))
            if planned.count >= 20 { return planned }
        }

        let artists = await seedArtists(using: client)
        guard !artists.isEmpty else {
            // Un genre, ou l'artiste introuvable : le serveur fait ce qu'il peut.
            var seed: [String: JSON] = ["seed_type": .string(seedType), "mode": .string("hybrid")]
            if let seedID { seed["seed_id"] = .string(seedID) }
            return Self.spread(try await radioPlan(using: client, seed))
        }
        let more = try await radioPlan(using: client, ["seed_type": .string("items"), "mode": .string("hybrid"), "items": .array(artists.map {
            .object(["artist_mbid": .string($0.id), "artist_name": .string($0.name)])
        })])
        var seen = Set(planned.map(Self.key))
        return Self.spread(planned + more.filter { seen.insert(Self.key($0)).inserted })
    }

    /// Le serveur enchaîne les plages d'un même album : deux par album au plus, et les albums alternés.
    private static func spread(_ plan: [JSON]) -> [JSON] {
        plan.interleaved(cap: 2) { $0["album_mbid"]?.string ?? $0["album_name"]?.string ?? key($0) }
    }

    private func radioPlan(using client: DroppedNeedle, _ seed: [String: JSON]) async throws -> [JSON] {
        let body = seed.merging(["count": .number(50)]) { first, _ in first }
        return try await client.json("POST", "/discover/radio/plan", body: .object(body))["tracks"]?.array ?? []
    }

    /// Les artistes de départ : ceux du mix, ou celui de la radio et ses voisins (le serveur en garde 8).
    private func seedArtists(using client: DroppedNeedle) async -> [(id: String, name: String)] {
        if !items.isEmpty {
            var seen = Set<String>()
            return items.compactMap { item in
                guard let artist = item.artistMbid, seen.insert(artist).inserted else { return nil }
                return (artist, item.artistName ?? "")
            }
        }
        var artist = seedType == "artist" ? seedID : nil
        if seedType == "album", let seedID {
            artist = try? await client.json("GET", "/albums/\(seedID)/basic")["artist_id"]?.string
        }
        guard let artist else { return [] }
        let similar = (try? await client.similarArtists(to: artist).similarArtists) ?? []
        return [(artist, seedType == "artist" ? title : "")] + similar.prefix(7).map { ($0.musicbrainzId, $0.name) }
    }

    private static func key(_ item: JSON) -> String {
        "\(item["artist_name"]?.string ?? "")|\(item["track_name"]?.string ?? "")".lowercased()
    }

    static func playable(_ item: JSON) -> Track? {
        guard let file = item["local_file_id"]?.string else { return nil }
        let album = item["album_mbid"]?.string
        return Track(id: file, title: item["track_name"]?.string ?? "", artist: item["artist_name"]?.string ?? "",
                     album: item["album_name"]?.string ?? "", cover: DroppedNeedle.cover(nil, album: album),
                     duration: item["duration_s"]?.number, albumID: album,
                     artistID: item["artist_mbid"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                     format: item["file_format"]?.string)
    }

}
