import SwiftUI

// MARK: Tout voir

/// Un classement complet sur la période choisie : populaire, tendances ou tes tops.
struct ChartView: View {
    let chart: Chart
    let title: String

    @Environment(\.client) private var client
    @State private var range = "this_month"
    @State private var items: [HomeItem] = []
    @State private var hasMore = true
    @State private var loading = false

    private static let ranges = [("this_week", "Semaine"), ("this_month", "Mois"), ("this_year", "Année"), ("all_time", "Toujours")]

    var body: some View {
        ScrollView {
            FilterChips(options: Self.ranges.map { ($0.0, $0.1) }, selection: $range)
                .padding(.horizontal)

            if chart == .trending {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 16)], spacing: 20) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        if let artist = item.artist {
                            NavigationLink(value: artist) {
                                ArtistBubble(name: item.name, image: item.imageUrl ?? DroppedNeedle.artistImage(artist.id), size: 100)
                            }
                            .buttonStyle(.plain)
                            .onAppear { if index == items.count - 1 { Task { await loadMore() } } }
                        }
                    }
                }
                .padding()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        NavigationLink(value: item.album) {
                            VStack(alignment: .leading, spacing: 6) {
                                AlbumCard(album: item.album, playable: item.inLibrary == true)
                                if item.inLibrary == true { Pill(text: "Dans les bacs") }
                                else if item.requested == true { Pill(text: "Demandé", color: .sky) }
                            }
                        }
                        .buttonStyle(.plain)
                        .onAppear { if index == items.count - 1 { Task { await loadMore() } } }
                    }
                }
                .padding()
            }
        }
        .overlay {
            if loading, items.isEmpty { SkeletonList() }
            else if !loading, items.isEmpty { ContentUnavailableView("Rien sur cette période", systemImage: "chart.bar") }
        }
        .platineBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: range) {
            items = []
            hasMore = true
            await loadMore()
        }
    }

    private func loadMore() async {
        guard hasMore, !loading else { return }
        loading = true
        defer { loading = false }
        guard let page = try? await client.chart(chart, range: range, offset: items.count) else {
            hasMore = false
            return
        }
        items += page.items.filter { $0.mbid != nil }
        hasMore = page.hasMore
    }
}

// MARK: Import Spotify

/// Ramener ses playlists Spotify dans DroppedNeedle ; les plages manquantes
/// pourront ensuite être demandées.
struct SpotifyImportView: View {
    @Environment(\.client) private var client
    @State private var playlists: [SpotifyPlaylist]?
    @State private var importing: String?
    @State private var error: String?

    var body: some View {
        List {
            ForEach(playlists ?? []) { playlist in
                HStack(spacing: 12) {
                    Cover(path: playlist.coverUrl, size: 56, radius: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlist.name).lineLimit(1)
                        Text("^[\(playlist.trackCount) plage](inflect: true) · \(playlist.owner)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if playlist.importedPlaylistId != nil {
                        Pill(text: "Importée")
                    } else if importing == playlist.id {
                        ProgressView()
                    } else {
                        Button("Importer") { run(playlist) }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .overlay {
            if let error {
                ContentUnavailableView("Spotify indisponible", systemImage: "music.note.list", description: Text(error))
            } else if playlists == nil {
                SkeletonList()
            } else if playlists?.isEmpty == true {
                ContentUnavailableView("Aucune playlist Spotify", systemImage: "music.note.list")
            }
        }
        .platineBackground()
        .navigationTitle("Depuis Spotify")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            playlists = try await client.spotifyPlaylists().playlists
            error = nil
        } catch {
            self.error = "Le serveur n'a pas pu lire tes playlists Spotify. Si le problème persiste, délie puis relie Spotify dans Compte › Services connectés.\n\n\(error.localizedDescription)"
        }
    }

    private func run(_ playlist: SpotifyPlaylist) {
        importing = playlist.id
        Task {
            defer { importing = nil }
            do {
                _ = try await client.importSpotifyPlaylist(playlist.id, name: playlist.name)
                await load()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: Suivis

/// Les artistes qu'on suit : leurs nouvelles sorties, leurs concerts, et eux.
struct FollowingView: View {
    @Environment(\.client) private var client
    @State private var releases: [NewRelease] = []
    @State private var total = 0
    @State private var artists: [FollowedArtist]?
    @State private var showsConcerts = false
    @State private var showsCities = false

    var body: some View {
        List {
            // Deux liens dans une même ligne de liste n'en font qu'un : de vrais boutons.
            HStack(spacing: 12) {
                Button { showsConcerts = true } label: {
                    Label("Concerts", systemImage: "ticket").frame(maxWidth: .infinity, minHeight: 44)
                }
                Button { showsCities = true } label: {
                    Label("Mes villes", systemImage: "mappin.and.ellipse").frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            .labelStyle(.titleAndIcon)
            .background {
                HStack(spacing: 12) {
                    Capsule().fill(.clear).glassEffect(.regular, in: .capsule)
                    Capsule().fill(.clear).glassEffect(.regular, in: .capsule)
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if let artists, !artists.isEmpty {
                Section {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(artists) { artist in
                                NavigationLink(value: ArtistRef(id: artist.mbid, name: artist.name)) {
                                    ArtistBubble(name: artist.name, image: artist.imageUrl ?? DroppedNeedle.artistImage(artist.mbid), size: 84)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
                } header: {
                    Text("^[\(artists.count) artiste suivi](inflect: true)").font(.display(20, relativeTo: .title3)).foregroundStyle(.primary)
                }
                .listRowBackground(Color.clear)
            }

            Section {
                ForEach(Array(releases.enumerated()), id: \.element.id) { index, release in
                    NavigationLink(value: release.album) {
                        HStack(spacing: 12) {
                            Cover(path: release.album.cover, size: 56, radius: 6)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(release.title).lineLimit(1)
                                Text(release.artistName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                Text([Self.type(release.primaryType), release.firstReleaseDate].compactMap(\.self).joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                            if release.inLibrary == true { Pill(text: "Dans les bacs") }
                        }
                    }
                    .onAppear { if index == releases.count - 1 { Task { await loadMore() } } }
                }
                if releases.isEmpty, artists != nil {
                    Text("Rien de neuf pour l'instant.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Nouvelles sorties").font(.display(20, relativeTo: .title3)).foregroundStyle(.primary)
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .platineBackground()
        .navigationTitle("Suivis")
        .navigationDestination(isPresented: $showsConcerts) { ConcertsView() }
        .navigationDestination(isPresented: $showsCities) { CitiesView() }
        .task {
            async let artists = try? client.followedArtists()
            await loadMore()
            self.artists = await artists ?? []
            // Ouvrir la page vaut lecture : la pastille « non vu » disparaît.
            _ = try? await client.markReleasesSeen()
        }
    }

    private func loadMore() async {
        // La v3 donne toutes les sorties récentes d'un coup.
        guard releases.isEmpty, let page = try? await client.newReleases() else { return }
        releases = page.items
        total = page.total
    }

    private static func type(_ type: String?) -> String? {
        switch type?.lowercased() {
        case "album": "Album"
        case "single": "Single"
        case "ep": "EP"
        case let other?: other.capitalized
        case nil: nil
        }
    }
}

/// Les villes autour desquelles chercher des concerts, dans l'ordre, avec leur rayon.
struct CitiesView: View {
    @Environment(\.client) private var client
    @State private var cities: [ConcertCity] = []
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                ForEach(Array(cities.enumerated()), id: \.offset) { index, city in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(city.cityName)
                            Spacer()
                            Text("\(Int(city.radiusKm)) km").monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(get: { city.radiusKm }, set: { cities[index].radiusKm = $0.rounded() }),
                               in: 5 ... 200) { editing in if !editing { save() } }
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { cities.remove(atOffsets: $0); save() }
                .onMove { cities.move(fromOffsets: $0, toOffset: $1); save() }
                if cities.isEmpty {
                    Text("Aucune ville pour l'instant.").foregroundStyle(.secondary)
                }
                Button("Ajouter une ville", systemImage: "plus") { adding = true }
            } footer: {
                Text("Le rayon fixe jusqu'où chercher les concerts autour de chaque ville.")
            }
            .settingsRow()
        }
        .settingsStyle()
        .navigationTitle("Villes de concerts")
        .toolbar { EditButton() }
        .sheet(isPresented: $adding) {
            CitySearchSheet { city in
                cities.append(city)
                save()
            }
        }
        .alert("Villes", isPresented: .constant(error != nil)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .task { cities = (try? await client.concertCities().items) ?? [] }
    }

    private func save() {
        let list = cities
        Task {
            do { cities = try await client.setConcertCities(list).items } catch {
                self.error = error.localizedDescription
                cities = (try? await client.concertCities().items) ?? cities
            }
        }
    }
}

/// Chercher une ville par son nom et la choisir.
private struct CitySearchSheet: View {
    let pick: (ConcertCity) -> Void

    @Environment(\.client) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [CityResult] = []
    @State private var searching = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List {
                TextField("Nom de la ville", text: $query)
                    .focused($focused)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .padding(12)
                    .background(Color.base200, in: .rect(cornerRadius: 12))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                ForEach(results, id: \.self) { city in
                    Button {
                        pick(ConcertCity(cityName: city.name, latitude: city.latitude, longitude: city.longitude,
                                         radiusKm: 30, countryCode: city.countryCode))
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(city.name).foregroundStyle(.primary)
                            Text([city.region, city.country].compactMap(\.self).joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .overlay {
                if let error {
                    ContentUnavailableView("Recherche impossible", systemImage: "mappin.slash", description: Text(error))
                } else if searching {
                    ProgressView()
                } else if query.count >= 2, results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .platineBackground()
            .navigationTitle("Ajouter une ville")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } } }
            .task(id: query) {
                error = nil
                guard query.trimmingCharacters(in: .whitespaces).count >= 2 else { results = []; return }
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                searching = true
                defer { searching = false }
                do { results = try await client.searchCities(query).items } catch is CancellationError {
                } catch {
                    self.error = error.localizedDescription
                }
            }
            .onAppear { focused = true }
        }
    }
}
