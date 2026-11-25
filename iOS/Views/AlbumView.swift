import SwiftUI

/// Un album, à la manière de Musique sous iOS 26.4 : la page prend la teinte
/// de la pochette, avec aléatoire, lecture et « lire ensuite » sous le titre.
struct AlbumView: View {
    let album: LocalAlbum

    @Environment(\.client) private var client
    @Environment(Player.self) private var player
    @State private var tracks: [Track] = []
    @State private var tint = Color.base300
    @State private var error: String?
    @State private var loaded = false
    /// Les plages du catalogue, quand l'album n'est pas dans les bacs.
    @State private var catalog: CatalogTracks?
    @State private var catalogLoaded = false
    /// L'album sur MusicBrainz, quand la page s'ouvre avec l'identifiant de la discothèque.
    @State private var catalogMatch: String?
    /// La fiche du catalogue : date, label, pays, verso…
    @State private var info: AlbumInfo?
    /// La demande de l'album en cours sur le serveur.
    @State private var albumRequest: ActiveRequest?
    /// Un état de la demande visible seulement dans l'historique : import, pause…
    @State private var albumHeld: String?
    /// Demandé à l'instant, avant que le serveur ne l'affiche dans ses demandes en cours.
    @State private var albumSent: Date?
    /// Vrai une fois les demandes lues : sans elles, ne rien proposer plutôt qu'un doublon.
    @State private var requestsKnown = false
    /// La dernière demande de l'album a échoué.
    @State private var albumFailed = false
    @State private var showsRequests = false
    /// Les plages déjà demandées seules, avec l'état de leur demande.
    @State private var requestedTracks: [String: String] = [:]

    /// L'album est demandé : ses plages arriveront avec lui, on ne les demande plus une à une.
    private var albumRequested: Bool { albumRequest != nil || albumHeld != nil || albumSent != nil }
    private var status: String? { albumRequest?.status ?? albumHeld }
    /// L'identifiant que connaissent le catalogue et les demandes.
    private var catalogID: String { catalogMatch ?? album.releaseGroupMbid ?? album.musicbrainzId }
    private var source: PlaySource { album.source }

    /// Une ligne de l'album : une plage qu'on a, ou une plage du catalogue qui manque.
    private enum Entry: Identifiable {
        case owned(Track, number: Int)
        case missing(CatalogTrack)

        var id: String {
            switch self {
            case let .owned(track, _): "owned-\(track.id)"
            case let .missing(track): "missing-\(track.id)"
            }
        }
    }

    /// Les plages dans l'ordre du catalogue quand il en connaît plus qu'on n'en a ; celles qui
    /// manquent restent visibles, à demander. Rapprochées par titre : le serveur ne relie pas les deux.
    private var entries: [Entry] {
        guard let catalog, catalog.tracks.count > tracks.count else {
            return tracks.enumerated().map { .owned($1, number: $0 + 1) }
        }
        var left = tracks.map { (track: $0, key: Discography.titleKey($0.title)) }
        var rows = catalog.tracks.sorted { ($0.discNumber ?? 1, $0.position) < ($1.discNumber ?? 1, $1.position) }
            .map { item -> Entry in
                let key = Discography.titleKey(item.title)
                guard let index = left.firstIndex(where: { $0.key == key }) else { return .missing(item) }
                return .owned(left.remove(at: index).track, number: item.position)
            }
        rows += left.map { .owned($0.track, number: tracks.firstIndex(of: $0.track).map { $0 + 1 } ?? 0) }
        return rows
    }

    private var missingCount: Int { tracks.isEmpty ? 0 : max((catalog?.tracks.count ?? 0) - tracks.count, 0) }

    var body: some View {
        List {
            VStack(spacing: 6) {
                Cover(path: album.cover, size: 260, radius: 10)
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
                    .padding(.bottom, 12)
                Text(album.name).font(.display(24, relativeTo: .title2)).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 2, trailing: 16))

            artistRow

            VStack(spacing: 6) {
                Text([album.year.map(String.init), album.primaryFormat?.uppercased(),
                      tracks.isEmpty ? nil : missingCount > 0 ? "\(tracks.count) sur \(tracks.count + missingCount) plages"
                        : "\(tracks.count) plages"]
                    .compactMap(\.self).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))

                HStack(spacing: 16) {
                    Button { player.play(tracks.shuffled(), source: source, using: client) } label: {
                        Image(systemName: "shuffle").frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Aléatoire")

                    Button { player.play(tracks, source: source, using: client) } label: {
                        Label("Lecture", systemImage: "play.fill")
                            .font(.headline)
                            .frame(width: 140, height: 30)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.white)
                    .foregroundStyle(.black)

                    Button { player.playNext(tracks, using: client) } label: {
                        Image(systemName: "text.line.first.and.arrowtriangle.forward").frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Lire ensuite")
                }
                .disabled(tracks.isEmpty)
                .padding(.top, 14)

            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)


            if loaded, requestsKnown, tracks.isEmpty { requestRow }

            if !loaded || (tracks.isEmpty && !catalogLoaded) {
                SkeletonRows(count: min(album.trackCount ?? 10, 20), side: nil, color: .white.opacity(0.12))
            }

            ForEach(entries) { entry in
                switch entry {
                case let .owned(track, number):
                    TrackRow(track: track, leading: String(number)) {
                        player.play(tracks, from: tracks.firstIndex(of: track) ?? 0, source: source, using: client)
                    } accessory: {
                        if let duration = track.duration {
                            Text(clock(duration)).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .listRowSeparatorTint(.white.opacity(0.15))
                case let .missing(track):
                    missingRow(track)
                }
            }

            if catalogLoaded { notes }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background {
            LinearGradient(colors: [tint, tint.mix(with: .black, by: 0.6)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .animation(.easeOut(duration: 0.4), value: tint)
        }
        .navigationBarTitleDisplayMode(.inline)
        .heroBar(title: album.name)
        .navigationDestination(isPresented: $showsRequests) { RequestsView() }
        .toolbar {
            NavigationLink(value: Route("radio-album-\(album.musicbrainzId)") {
                RadioView(seedType: "album", seedID: catalogID, title: album.name)
            }) {
                Label("Radio", systemImage: "dot.radiowaves.left.and.right")
            }
        }
        .task {
            if let path = album.cover, let image = await Cover.load(path, client: client),
               let color = Cover.tint(of: image) {
                // Assez sombre pour garder le texte blanc lisible.
                tint = color.mix(with: .black, by: 0.35)
            }
        }
        .task {
            do {
                try await loadTracks()
            } catch {
                // Un album hors de la discothèque n'a pas de pistes locales : ce n'est pas une erreur.
                self.error = error.localizedDescription
            }
            loaded = true
            if tracks.isEmpty {
                async let requests: Void = refreshRequests(firstTime: true)
                async let catalog: Void = loadCatalog()
                _ = await (requests, catalog)
            } else {
                // Un disque complet n'a besoin ni des demandes ni de leur suivi.
                await loadCatalog()
                if missingCount > 0 { await refreshRequests(firstTime: true) }
            }
            catalogLoaded = true
            // Suit les demandes tant que la page est ouverte, et affiche les plages dès leur arrivée.
            while !Task.isCancelled, tracks.isEmpty || missingCount > 0 {
                try? await Task.sleep(for: .seconds(albumRequested ? 3 : 20))
                guard !Task.isCancelled else { break }
                await refreshRequests(firstTime: false)
                if !tracks.isEmpty { try? await loadTracks() }
            }
        }
    }

    // MARK: Bas de page

    /// Le bas de page de Musique, puis la fiche comme pour un artiste, et le verso et la galette.
    @ViewBuilder
    private var notes: some View {
        let seconds = info?.totalLength.map { Double($0) / 1000 } ?? tracks.compactMap(\.duration).reduce(0, +)
        let count = max(tracks.count + missingCount, catalog?.tracks.count ?? 0)
        PageFooter(lines: [Dates.day(info?.releaseDate), count > 0 ? Dates.summary(tracks: count, seconds: seconds) : nil,
                           info?.label.map { "℗ \($0)" }].compactMap(\.self))
        let facts = self.facts
        if !facts.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Notes de pochette").font(.display(20, relativeTo: .title3))
                FactsTable(facts: facts, background: .white.opacity(0.08))
            }
            .padding(.vertical, 20)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        let photos = [info?.albumBackUrl, info?.albumCdartUrl].compactMap(\.self)
        if !photos.isEmpty {
            Shelf("Verso et galette") {
                ForEach(photos, id: \.self) { Cover(path: $0, size: 180, radius: 10) }
            }
            .padding(.top, 20)
            .padding(.bottom, 32)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private var facts: [(label: String, value: String)] {
        let size = album.totalSizeBytes.map { Int64($0).formatted(.byteCount(style: .file)) }
        let owned = tracks.isEmpty ? nil : [missingCount > 0 ? "\(tracks.count) sur \(tracks.count + missingCount) plages"
                                                             : tracks.count == 1 ? "1 plage" : "\(tracks.count) plages",
                                            album.primaryFormat?.uppercased(), size].compactMap(\.self).joined(separator: " · ")
        let added = album.dateAdded.flatMap(Double.init).map { Date(timeIntervalSince1970: $0).formatted(date: .long, time: .omitted) }
        let listens = ListenCounts.saved?.count(album: album.name, artist: album.artistName)
        return FactsTable.known([
            ("Type", info?.type.map { ["Album": "Album", "EP": "EP", "Single": "Single", "Compilation": "Compilation"][$0] ?? $0 }),
            ("Sortie", Dates.day(info?.releaseDate)),
            ("Label", info?.label),
            ("Pays", info?.country.flatMap { Locale.current.localizedString(forRegionCode: $0) }),
            ("Durée", info?.totalLength.map { Dates.length(seconds: Double($0) / 1000) }),
            ("Dans tes bacs", owned),
            ("Ajouté le", added),
            ("Tes écoutes", listens.map { $0.formatted() }),
        ])
    }

    private func missingRow(_ track: CatalogTrack) -> some View {
        HStack(spacing: 12) {
            Text(String(track.position)).font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary).frame(minWidth: 24)
            // Une plage qu'on a sur un disque incomplet se lit ; celle qui manque est en retrait.
            Text(track.title).lineLimit(2).foregroundStyle(tracks.isEmpty ? .primary : .secondary)
            Spacer(minLength: 0)
            if let length = track.length {
                Text(clock(Double(length) / 1000)).font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
            if requestsKnown, !albumRequested, let recording = track.recordingId, let catalog {
                TrackRequestButton(recording: recording, request: request(for: track, in: catalog),
                                   status: requestedTracks[recording]) { showsRequests = true }
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(.white.opacity(0.15))
        .macRowSpacing()
    }

    /// Le catalogue de l'album. Ouvert depuis la discothèque, l'album n'a que son identifiant local,
    /// que le catalogue refuse : on le retrouve par la recherche, même titre et même artiste.
    private func loadCatalog() async {
        // Un album de la discothèque connaît en général son album MusicBrainz ; sinon on le lui demande.
        var known = album.releaseGroupMbid
        if known == nil { known = await client.releaseGroup(ofLibraryAlbum: album.musicbrainzId) }
        let id = known ?? album.musicbrainzId
        if let found = try? await client.albumInfo(id) {
            catalogMatch = id
            info = found
            catalog = found.catalog
            return
        }
        let (title, artist) = (Discography.titleKey(album.name), Discography.titleKey(album.artistName))
        let results = (try? await client.search("\(album.artistName) \(album.name)").albums) ?? []
        let same = results.filter { Discography.titleKey($0.title) == title && Discography.titleKey($0.artist ?? "") == artist }
        guard let match = same.first(where: \.inLibrary) ?? same.first else { return }
        catalogMatch = match.musicbrainzId
        info = try? await client.albumInfo(match.musicbrainzId)
        catalog = info?.catalog
    }

    private func loadTracks() async throws {
        #if DEBUG
        if DebugScreen.slow { try? await Task.sleep(for: .seconds(30)) }
        #endif
        tracks = try await client.tracks(of: album.musicbrainzId)
            .sorted { ($0.discNumber ?? 1, $0.trackNumber) < ($1.discNumber ?? 1, $1.trackNumber) }
            .map { $0.track(in: album) }
    }

    /// Le serveur ne relie pas une plage à son album : ne pas proposer ce qui est déjà en cours.
    /// L'historique est indispensable : pour un admin, le serveur ne liste en cours que `pending` et
    /// `downloading`. Un album en file d'attente en sort, et paraîtrait non demandé.
    private func refreshRequests(firstTime: Bool) async {
        async let activeList = try? client.activeRequests().items
        async let pastList = try? client.requestHistory(pageSize: 100).items
        let (active, past) = await (activeList, pastList)
        // Sans réponse, on garde ce qu'on sait : `requestsKnown` reste faux et rien n'est proposé.
        guard let active, let past else { return }
        let wasRunning = albumRequest != nil || albumHeld != nil
        albumRequest = active.first { $0.requestKind != "track" && $0.musicbrainzId == catalogID }
        let record = past.first { $0.requestKind != "track" && $0.musicbrainzId == catalogID }?.status
        albumHeld = albumRequest == nil && record.map { !RequestStatus.allowsNewRequest($0) } == true ? record : nil
        requestedTracks = RequestStatus.tracks(active: active, past: past)
        requestsKnown = true
        if albumRequest != nil || albumHeld != nil {
            albumSent = nil
            albumFailed = false
        } else if albumSent.map({ Date.now.timeIntervalSince($0) > 10 }) ?? true {
            // Juste après un envoi, l'historique peut encore montrer l'ancien échec.
            albumFailed = record != nil && record != "cancelled" && record != "imported"
            if albumFailed { albumSent = nil }
        }
        if wasRunning, albumRequest == nil, albumHeld == nil {
            try? await loadTracks()
            albumSent = nil
        }
    }

    // MARK: Demande

    /// L'état de la demande de l'album, sur sa propre ligne pour que tout soit cliquable.
    @ViewBuilder
    private var requestRow: some View {
        Group {
            if albumRequested {
                Button { showsRequests = true } label: { requestStatus }
                    .buttonStyle(.plain)
                    .accessibilityHint("Ouvre les demandes")
            } else {
                VStack(spacing: 8) {
                    Text(albumFailed ? "La demande a échoué" : "Pas encore dans les bacs")
                        .font(.subheadline)
                        .foregroundStyle(albumFailed ? .yellow : .white.opacity(0.7))
                    RequestButton(album: AlbumRequest(musicbrainzId: catalogID, artist: album.artistName,
                                                      album: album.name, year: album.year)) {
                        albumSent = .now
                        albumFailed = false
                    }
                    if albumFailed {
                        Button("Voir mes demandes") { showsRequests = true }
                            .font(.caption)
                            .buttonStyle(.borderless)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var requestStatus: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.badge.checkmark").font(.title3).foregroundStyle(Color.sage)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(RequestStatus.label(status)).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    if let eta = albumRequest?.eta.map(Date.init(timeIntervalSince1970:)) {
                        Text(eta, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let progress = albumRequest?.progress {
                        Text("\(Int(progress)) %").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if RequestStatus.isTransferring(status) {
                    if let progress = albumRequest?.progress {
                        ProgressView(value: min(progress, 100), total: 100).tint(.sage)
                    } else {
                        ProgressView().progressViewStyle(.linear).tint(.sage)
                    }
                }
                Text("Ses plages arriveront avec l'album").font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.white.opacity(0.08), in: .rect(cornerRadius: 12))
        .contentShape(.rect)
    }

    /// Le nom de l'artiste, sur sa propre ligne : dans la ligne de l'en-tête, avec les boutons de
    /// lecture, ni un lien ni un bouton ne reçoivent le toucher.
    private var artistRow: some View {
        Group {
            let name = Text(album.artistName).font(.title3).foregroundStyle(.white.opacity(0.75))
                .frame(maxWidth: .infinity)
            if let artist = ArtistDirectory.shared.ref(id: album.artistMbid, named: album.artistName) {
                NavigationLink(value: artist) { name }
                    .navigationLinkIndicatorVisibility(.hidden)
            } else {
                name
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }

    private func request(for track: CatalogTrack, in catalog: CatalogTracks) -> TrackRequest {
        TrackRequest(artistName: album.artistName, trackTitle: track.title, albumTitle: album.name,
                     durationSeconds: track.length.map { $0 / 1000 }, releaseGroupMbid: catalogID,
                     artistMbid: album.artistMbid, releaseId: catalog.selectedReleaseMbid)
    }
}

/// Demande une seule plage, et montre la réponse du disquaire.
struct TrackRequestButton: View {
    let recording: String
    let request: TrackRequest
    /// L'état de sa demande sur le serveur, tenu à jour par la page.
    let status: String?
    var onSent: (String) -> Void = { _ in }
    let openRequests: () -> Void

    @Environment(\.client) private var client
    @State private var state: State

    private enum State: Equatable { case idle, sending, waiting, queued, owned, failed }

    init(recording: String, request: TrackRequest, status: String?,
         onSent: @escaping (String) -> Void = { _ in }, openRequests: @escaping () -> Void) {
        self.recording = recording
        self.request = request
        self.status = status
        self.onSent = onSent
        self.openRequests = openRequests
        _state = SwiftUI.State(initialValue: Self.state(for: status))
    }

    private static func state(for status: String?) -> State {
        switch status {
        case nil: .idle
        case "awaiting_approval": .waiting
        case "already_in_library": .owned
        default: .queued
        }
    }

    var body: some View {
        Group {
            switch state {
            case .idle:
                Button { send() } label: { Image(systemName: "plus.circle") }
                    .accessibilityLabel("Demander cette plage")
            case .sending:
                ProgressView()
            case .waiting:
                Button(action: openRequests) { Image(systemName: "hourglass").foregroundStyle(.yellow) }
                    .accessibilityLabel("En attente de validation, ouvrir les demandes")
            case .queued:
                Button(action: openRequests) { Image(systemName: "clock.badge.checkmark").foregroundStyle(Color.sage) }
                    .accessibilityLabel("Demandée, ouvrir les demandes")
            case .owned:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.sage)
                    .accessibilityLabel("Déjà dans les bacs")
            case .failed:
                Button { send() } label: { Image(systemName: "exclamationmark.triangle") }
                    .foregroundStyle(.red)
                    .accessibilityLabel("Échec, réessayer")
            }
        }
        .font(.title3)
        .buttonStyle(.borderless)
        .frame(width: 30)
        .onChange(of: status) { _, status in state = Self.state(for: status) }
    }

    private func send() {
        state = .sending
        Task {
            guard let status = try? await client.requestTrack(recording, request).status else {
                state = .failed
                return
            }
            state = Self.state(for: status)
            onSent(status)
        }
    }
}
