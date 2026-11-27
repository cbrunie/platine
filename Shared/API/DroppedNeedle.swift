import CryptoKit
import Foundation

/// Client de l'API REST de DroppedNeedle.
///
/// Seule la v3 de DroppedNeedle est gérée : la v2 (`/api/v1`) n'existe plus côté serveur.
nonisolated struct DroppedNeedle: Sendable {
    static let prefix = "/api/v3"

    let server: URL
    var token: String?

    enum Failure: LocalizedError {
        case status(Int, String)

        var errorDescription: String? {
            switch self {
            case let .status(0, message): message
            case let .status(code, message): "Erreur \(code) : \(message)"
            }
        }
    }

    // MARK: Routes

    func login(username: String, password: String) async throws -> AuthResponse {
        // « bearer » : le jeton dans la réponse, sans cookie de navigateur.
        try await send("POST", "/auth/login", body: ["username": username, "password": password, "transport": "bearer"])
    }

    // MARK: App Connect

    /// Platine telle que l'admin l'autorise sur le serveur (Réglages › Applis connectées), et l'adresse
    /// où le navigateur la rappelle. Voir `docs/app-connect.md` de DroppedNeedle.
    static let appConnectClient = "fr.cbrunie.platine"
    static let appConnectScheme = "fr.cbrunie.platine"
    static let appConnectReturn = "fr.cbrunie.platine:/connect"

    /// La page du serveur où l'on se connecte puis autorise Platine (OAuth 2.0 avec PKCE).
    func appConnectURL(challenge: String, state: String, device: String) -> URL? {
        var components = URLComponents(url: server.appending(path: "connect"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Self.appConnectClient),
            URLQueryItem(name: "redirect_uri", value: Self.appConnectReturn),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "name", value: device),
        ]
        return components?.url
    }

    /// Échange le code reçu du navigateur contre une session d'appareil, valable deux minutes et une fois.
    @concurrent
    func appConnectToken(code: String, verifier: String) async throws -> AppConnectToken {
        var request = URLRequest(url: server.appending(path: Self.prefix + "/auth/app-connect/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: Self.appConnectReturn),
            URLQueryItem(name: "client_id", value: Self.appConnectClient),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        return try Self.decoder.decode(AppConnectToken.self, from: try await data(request))
    }

    func discoverQueue() async throws -> DiscoverQueue {
        try await send("GET", "/discover/queue")
    }

    /// Artistes, albums et plages, de la discothèque comme du catalogue.
    func search(_ text: String) async throws -> SearchResponse {
        try await send("GET", "/search", query: [URLQueryItem(name: "q", value: text),
                                                 URLQueryItem(name: "limit_artists", value: "10"),
                                                 URLQueryItem(name: "limit_albums", value: "25")])
    }

    func request(_ album: AlbumRequest) async throws -> RequestAccepted {
        try await send("POST", "/requests/albums", body: album)
    }

    func activeRequests() async throws -> ActiveRequests {
        try await send("GET", "/requests/active")
    }

    func requestHistory(pageSize: Int = 20) async throws -> RequestHistory {
        try await send("GET", "/requests/history", query: [URLQueryItem(name: "page_size", value: String(pageSize))])
    }

    func wanted() async throws -> WantedList {
        try await send("GET", "/requests/wanted")
    }

    // MARK: Bibliothèque locale

    func recentAlbums() async throws -> [LocalAlbum] {
        let page: LocalAlbumPage = try await send("GET", "/library/recently-added", query: [URLQueryItem(name: "limit", value: "24")])
        return page.items
    }

    /// Une page d'albums par ordre alphabétique ; `after` vient de la page précédente.
    func albums(after cursor: String? = nil) async throws -> LocalAlbumPage {
        var query = [URLQueryItem(name: "limit", value: "200"), URLQueryItem(name: "sort", value: "name")]
        if let cursor { query.append(URLQueryItem(name: "after", value: cursor)) }
        return try await send("GET", "/library/albums", query: query)
    }

    /// Les plages qu'on a d'un album, par son identifiant local ou MusicBrainz ; aucune s'il n'y est pas.
    func tracks(of album: String) async throws -> [LocalTrack] {
        var tracks: [LocalTrack] = []
        while true {
            let page: LocalTrackPage = try await send("GET", "/library/albums/match/\(album)", query: [
                URLQueryItem(name: "limit", value: "500"), URLQueryItem(name: "offset", value: String(tracks.count)),
            ])
            tracks += page.items
            if page.items.isEmpty || tracks.count >= page.total { return tracks }
        }
    }

    /// L'album MusicBrainz d'un album de la discothèque, pour son catalogue et ses demandes.
    func releaseGroup(ofLibraryAlbum id: String) async -> String? {
        (try? await send("GET", "/library/albums/\(id)") as LocalAlbum)?.releaseGroupMbid
    }

    /// « In the Crate » : des pistes de la bibliothèque, avec la raison de chacune.
    /// Le serveur remplit surtout le bac de disques fraîchement téléchargés : on lui en demande
    /// deux fois plus (40, son maximum) et on garde 20 plages en alternant les raisons (récent, à redécouvrir, même époque, surprise).
    func crate() async throws -> Crate {
        var crate: Crate = try await send("GET", "/library/suggestions", query: [URLQueryItem(name: "limit", value: "40")])
        // Deux plages par album au plus : les « Récent » viennent souvent toutes du même disque.
        let varied = crate.items.interleaved(cap: 2) { $0.albumId ?? $0.albumName }
        crate.items = Array(varied.interleaved { $0.reason ?? "" }.prefix(20))
        return crate
    }

    func searchLibrary(_ text: String) async throws -> LibrarySearch {
        try await send("GET", "/search", query: [URLQueryItem(name: "q", value: text), URLQueryItem(name: "scope", value: "library"),
                                                 URLQueryItem(name: "buckets", value: "albums,tracks"),
                                                 URLQueryItem(name: "limit_albums", value: "20"),
                                                 URLQueryItem(name: "limit_tracks", value: "50")])
    }

    /// Le flux d'une piste, qui accepte les requêtes Range pour avancer dans le morceau.
    func streamURL(_ trackFileID: String) -> URL {
        server.appending(path: Self.prefix + "/stream/local/\(trackFileID)")
    }

    // MARK: Compte

    func me() async throws -> User {
        try await send("GET", "/me")
    }

    // MARK: Accueil

    func home() async throws -> Home {
        try await send("GET", "/home")
    }

    /// Les recommandations de la page Discover du web. Pendant que le serveur les recalcule, il les
    /// renvoie vides : on garde alors les dernières reçues, rangées sur l'appareil.
    func discover() async throws -> Discover {
        let data = try JSONEncoder().encode(try await json("GET", "/discover"))
        let latest = try Self.decoder.decode(Discover.self, from: data)
        if latest.generatedAt != nil {
            try? data.write(to: Self.discoverCache)
            return latest
        }
        guard let saved = try? Data(contentsOf: Self.discoverCache),
              var cached = try? Self.decoder.decode(Discover.self, from: saved) else { return latest }
        cached.fromCache = true
        return cached
    }

    /// ponytail: un seul fichier, effacé à la déconnexion ; une clé par compte si l'app en gère plusieurs.
    static let discoverCache = URL.cachesDirectory.appending(path: "discover.json")

    func refreshDiscover() async throws {
        let _: Empty = try await send("POST", "/discover/refresh")
    }

    /// Les 100 albums les plus écoutés de tous les temps, selon ListenBrainz ou Last.fm.
    func yourTopAlbums() async throws -> TopAlbumRange {
        try await send("GET", "/home/your-top/albums", query: [URLQueryItem(name: "range", value: "all_time"),
                                                               URLQueryItem(name: "limit", value: "100")])
    }

    func libraryStats() async throws -> LibraryStats {
        try await send("GET", "/library/stats")
    }

    func localAlbums(matching text: String) async throws -> LocalAlbumPage {
        try await send("GET", "/library/albums", query: [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "limit", value: "50"),
        ])
    }

    /// Les décennies, chacune avec une douzaine de ses albums tirés au hasard.
    func decades() async throws -> Decades {
        let shelves: DecadeShelves = try await send("GET", "/library/decades")
        let client = self
        let albums = await withTaskGroup(of: (Int, [LocalAlbum]).self) { group in
            for shelf in shelves.items {
                group.addTask {
                    let page: LocalAlbumPage? = try? await client.send("GET", "/library/albums", query: [
                        URLQueryItem(name: "decade", value: String(shelf.decade)), URLQueryItem(name: "sort", value: "random"),
                        URLQueryItem(name: "limit", value: "12"),
                    ])
                    return (shelf.decade, page?.items ?? [])
                }
            }
            var found: [Int: [LocalAlbum]] = [:]
            for await (decade, items) in group { found[decade] = items }
            return found
        }
        // Les plus récentes d'abord, comme avant.
        return Decades(items: shelves.items.reversed().map { Decade(decade: $0.decade, label: $0.label, albums: albums[$0.decade] ?? []) })
    }

    /// « Pas pour moi » : le disque ne sera plus proposé. Le serveur recalcule ses recommandations.
    func ignore(_ release: IgnoredRelease) async throws {
        let _: Empty = try await send("POST", "/discover/queue/ignore", body: release)
    }

    /// Des disques à découvrir à partir d'une playlist.
    func suggestions(for playlist: String) async throws -> PlaylistSuggestions {
        try await send("POST", "/discover/playlist-suggestions", body: ["playlist_id": playlist])
    }

    func genre(_ name: String) async throws -> Genre {
        try await send("GET", "/home/genre/\(name)")
    }

    // MARK: Réglages du compte

    func profile() async throws -> Profile {
        try await send("GET", "/me")
    }

    func rename(to displayName: String) async throws -> User {
        try await send("PATCH", "/me", body: ["display_name": displayName])
    }

    func connections() async throws -> Connections {
        try await send("GET", "/me/connections")
    }

    func listeningPreferences() async throws -> ListeningPreferences {
        try await send("GET", "/me/scrobble-preferences")
    }

    func update(_ preferences: ListeningPreferences) async throws -> ListeningPreferences {
        try await send("PUT", "/me/scrobble-preferences", body: preferences)
    }

    func version() async throws -> Version {
        try await send("GET", "/version")
    }

    /// Un onglet des réglages du web, pour ceux qui ne sont pas encore natifs.
    func webSettings(_ tab: String) -> URL {
        var components = URLComponents(url: server.appending(path: "/settings"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "tab", value: tab)]
        return components?.url ?? server
    }

    // MARK: Discothèque complète

    func lyrics(_ trackFileID: String) async throws -> Lyrics {
        try await send("GET", "/library/tracks/\(trackFileID)/lyrics")
    }

    /// Une page de plages par titre ; `after` vient de la page précédente.
    func libraryTracks(after cursor: String? = nil, search: String? = nil) async throws -> LibraryTracks {
        var query = [URLQueryItem(name: "limit", value: "500"), URLQueryItem(name: "sort", value: "title")]
        if let cursor { query.append(URLQueryItem(name: "after", value: cursor)) }
        if let search, !search.isEmpty { query.append(URLQueryItem(name: "q", value: search)) }
        return try await send("GET", "/library/tracks", query: query)
    }

    /// `album_artists` : ceux qui ont un album. `contributors` : ceux qui sont seulement invités sur une plage.
    func libraryArtists(after cursor: String? = nil, scope: String = "album_artists") async throws -> LibraryArtists {
        var query = [URLQueryItem(name: "limit", value: "200"), URLQueryItem(name: "scope", value: scope),
                     URLQueryItem(name: "sort", value: "name")]
        if let cursor { query.append(URLQueryItem(name: "after", value: cursor)) }
        return try await send("GET", "/library/artists", query: query)
    }

    // MARK: Playlists

    func playlists() async throws -> Playlists {
        try await send("GET", "/playlists")
    }

    func playlist(_ id: String) async throws -> PlaylistDetail {
        try await send("GET", "/playlists/\(id)")
    }

    func createPlaylist(_ name: String) async throws -> PlaylistDetail {
        try await send("POST", "/playlists", body: ["name": name])
    }

    func renamePlaylist(_ id: String, to name: String) async throws -> PlaylistDetail {
        try await send("PUT", "/playlists/\(id)", body: ["name": name])
    }

    func deletePlaylist(_ id: String) async throws {
        let _: Empty = try await send("DELETE", "/playlists/\(id)")
    }

    func add(_ tracks: [Track], to playlist: String) async throws {
        let _: Empty = try await send("POST", "/playlists/\(playlist)/tracks",
                                      body: PlaylistAddition(tracks: tracks.map(PlaylistTrackInput.init)))
    }

    func removeTrack(_ trackID: String, from playlist: String) async throws {
        let _: Empty = try await send("DELETE", "/playlists/\(playlist)/tracks/\(trackID)")
    }

    func moveTrack(_ trackID: String, in playlist: String, to position: Int) async throws {
        let _: Empty = try await send("PATCH", "/playlists/\(playlist)/tracks/reorder",
                                      body: PlaylistMove(trackId: trackID, newPosition: position))
    }

    // MARK: Classements

    /// Populaire, tendances ou tes tops, sur une période : this_week, this_month, this_year, all_time.
    func chart(_ kind: Chart, range: String, offset: Int) async throws -> ChartPage {
        try await send("GET", "/home/\(kind.rawValue)", query: [
            URLQueryItem(name: "range", value: range),
            URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "offset", value: String(offset)),
        ])
    }

    // MARK: Spotify

    func spotifyPlaylists() async throws -> SpotifyPlaylists {
        try await send("GET", "/acquire/spotify/playlists")
    }

    func importSpotifyPlaylist(_ id: String, name: String) async throws -> SpotifyImport {
        try await send("POST", "/acquire/spotify/playlists/\(id)/import", body: ["name": name])
    }

    // MARK: Suivis

    func followedArtists() async throws -> [FollowedArtist] {
        let list: FollowedArtists = try await send("GET", "/following/artists")
        return list.artists
    }

    /// Les sorties récentes des artistes suivis : le serveur les donne d'un bloc, sans pages.
    func newReleases() async throws -> NewReleases {
        try await send("GET", "/following/new-releases/recent", query: [URLQueryItem(name: "limit", value: "200")])
    }

    func unseenReleases() async throws -> Unseen {
        try await send("GET", "/following/new-releases/unseen-count")
    }

    func markReleasesSeen() async throws -> Unseen {
        try await send("POST", "/following/new-releases/seen")
    }

    func concertCities() async throws -> ConcertCities {
        try await send("GET", "/following/concerts/cities")
    }

    func setConcertCities(_ cities: [ConcertCity]) async throws -> ConcertCities {
        try await send("PUT", "/following/concerts/cities", body: ConcertCities(items: cities))
    }

    func searchCities(_ text: String) async throws -> CitySearch {
        try await send("GET", "/following/concerts/city-search", query: [URLQueryItem(name: "q", value: text)])
    }

    // MARK: Artistes

    func artist(_ id: String) async throws -> Artist {
        try await send("GET", "/artists/\(id)")
    }

    /// Ses titres les plus écoutés : 50, le maximum du serveur, pour remplir « This Is ».
    func topSongs(of id: String) async throws -> TopSongs {
        try await send("GET", "/artists/\(id)/top-songs", query: [URLQueryItem(name: "count", value: "50")])
    }

    func extended(_ id: String) async throws -> ArtistExtended {
        try await send("GET", "/artists/\(id)/extended")
    }

    func topAlbums(of id: String) async throws -> TopAlbums {
        try await send("GET", "/artists/\(id)/top-albums")
    }

    /// Les sorties d'un artiste : la fiche de l'artiste les renvoie vides, celles-ci sont remplies.
    func releases(of id: String) async throws -> ArtistReleases {
        try await send("GET", "/artists/\(id)/releases", query: [URLQueryItem(name: "limit", value: "200")])
    }

    /// Un album du catalogue : son en-tête (date, type) et la plage de l'édition affichée (label, pays…).
    func albumInfo(_ album: String) async throws -> AlbumInfo {
        async let basic: AlbumBasic = send("GET", "/albums/\(album)/basic")
        async let tracks: CatalogTracks = send("GET", "/albums/\(album)/tracks")
        return try await AlbumInfo(basic: basic, tracks: tracks)
    }

    func catalogTracks(of album: String) async throws -> CatalogTracks {
        try await send("GET", "/albums/\(album)/tracks")
    }

    /// Demande une seule plage au disquaire.
    func requestTrack(_ recording: String, _ request: TrackRequest) async throws -> TrackRequestStatus {
        var request = request
        request.recordingMbid = recording
        return try await send("POST", "/requests/tracks", body: request)
    }

    func similarArtists(to id: String) async throws -> SimilarArtists {
        try await send("GET", "/artists/\(id)/similar")
    }

    func follow(_ id: String, _ followed: Bool) async throws -> FollowStatus {
        try await send("PUT", "/artists/\(id)/follow", body: ["followed": followed])
    }

    // MARK: Concerts

    func concerts() async throws -> Concerts {
        try await send("GET", "/following/concerts")
    }

    // MARK: Présence et scrobbling

    /// Ce qu'on écoute, pour que le web l'affiche parmi les sessions en cours.
    func reportNowPlaying(_ report: NowPlayingReport) async throws {
        let _: Empty = try await send("POST", "/now-playing", body: report)
    }

    func clearNowPlaying() async throws {
        let _: Empty = try await send("DELETE", "/now-playing")
    }

    func scrobbleNowPlaying(_ listen: Listen) async throws {
        let _: Empty = try await send("POST", "/scrobble/now-playing", body: listen)
    }

    func scrobble(_ listen: Listen) async throws {
        var listen = listen
        // La v3 exige l'heure de l'écoute.
        if listen.timestamp == nil { listen.timestamp = Int(Date.now.timeIntervalSince1970) }
        let _: Empty = try await send("POST", "/scrobble/submit", body: listen)
    }

    static func artistImage(_ mbid: String) -> String {
        prefix + "/covers/artist/\(mbid)?size=500"
    }

    /// Une pochette : l'adresse donnée par le serveur, sinon celle de l'album sur MusicBrainz.
    /// Les identifiants locaux sont aussi des UUID : ne passer en `album` qu'un identifiant MusicBrainz.
    static func cover(_ url: String?, album mbid: String?) -> String? {
        if let url, !url.isEmpty { return url }
        guard let mbid, UUID(uuidString: mbid) != nil else { return nil }
        return prefix + "/covers/release-group/\(mbid)?size=500"
    }

    /// La pochette d'un album de la discothèque : son image à lui (dossier ou fichier).
    static func artwork(album id: String, version: Int? = nil) -> String {
        prefix + "/library/albums/\(id)/artwork?size=500" + (version.map { "&v=\($0)" } ?? "")
    }

    var authHeaders: [String: String] {
        token.map { ["Authorization": "Bearer \($0)"] } ?? [:]
    }

    /// Une pochette : elles passent par l'API authentifiée, que `AsyncImage`
    /// ne sait pas interroger avec un jeton.
    @concurrent
    func image(_ path: String) async throws -> Data {
        let url = path.hasPrefix("http") ? URL(string: path) : URL(string: path, relativeTo: server)
        guard let url else { throw URLError(.badURL) }
        return try await data(URLRequest(url: url), keeps: false)
    }

    // MARK: Transport

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    @concurrent
    fileprivate func send<Response: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: (any Encodable)? = nil
    ) async throws -> Response {
        var components = URLComponents(
            url: server.appending(path: Self.prefix + path),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encoder.encode(body)
        }
        let data = try await data(request)
        // Les routes qui ne renvoient rien (204) se décodent en `Empty`.
        return try Self.decoder.decode(Response.self, from: data.isEmpty ? Data("{}".utf8) : data)
    }

    /// Une route lue et écrite telle quelle, pour les réglages : les clés restent
    /// en snake_case, comme le serveur les attend en retour.
    @concurrent
    func json(_ method: String, _ path: String, body: JSON? = nil) async throws -> JSON {
        guard let url = URL(string: Self.prefix + path, relativeTo: server) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let data = try await data(request)
        return data.isEmpty ? .null : try JSONDecoder().decode(JSON.self, from: data)
    }

    /// Un fichier envoyé en multipart, comme la photo de profil.
    func upload(_ path: String, field: String, file: Data, filename: String, mimeType: String) async throws -> JSON {
        guard let url = URL(string: Self.prefix + path, relativeTo: server) else { throw URLError(.badURL) }
        let boundary = "platine-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(file)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data = try await data(request)
        return data.isEmpty ? .null : try JSONDecoder().decode(JSON.self, from: data)
    }

    /// Le temps d'un `withValue(true)`, les GET répondent depuis le disque (la dernière réponse reçue),
    /// sans réseau ; une réponse jamais reçue lève une erreur. Les pages s'affichent ainsi tout de suite.
    @TaskLocal static var fromDisk = false
    nonisolated static let responses = URL.cachesDirectory.appending(path: "api")

    /// Un nom de fichier stable pour une adresse.
    nonisolated static func fileName(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @concurrent
    private func data(_ request: URLRequest, keeps: Bool = true) async throws -> Data {
        let file = keeps && request.httpMethod == "GET" ? request.url.map { Self.responses.appending(path: Self.fileName($0.absoluteString)) } : nil
        if Self.fromDisk {
            guard let file, let saved = try? Data(contentsOf: file) else { throw URLError(.resourceUnavailable) }
            return saved
        }
        var request = request
        // Le jeton ne part que vers notre serveur, jamais vers les images externes.
        if request.url?.host() == server.host() {
            for (field, value) in authHeaders { request.setValue(value, forHTTPHeaderField: field) }
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Jeton refusé (expiré, révoqué, ou d'avant la v3) : retour à l'écran de connexion.
        if status == 401, token != nil, request.url?.host() == server.host() {
            await Session.shared.logout()
        }
        guard (200 ..< 300).contains(status) else {
            throw Failure.status(status, Self.message(in: data))
        }
        if let file {
            try? FileManager.default.createDirectory(at: Self.responses, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return data
    }

    /// Le message d'une erreur de l'API : `{"error": {"message"}}` ou `{"detail"}`.
    private static func message(in data: Data) -> String {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let error = json?["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        // App Connect répond `{"error": "invalid_client"}`.
        if let code = json?["error"] as? String { return code }
        return json?["detail"] as? String ?? String(decoding: data.prefix(200), as: UTF8.self)
    }
}

// MARK: Modèles

/// Lit chaque élément d'une liste à part : un élément d'une forme inattendue est sauté
/// plutôt que de faire échouer toute la liste.
nonisolated struct Lossy<Element: Decodable>: Decodable {
    let value: Element?

    init(from decoder: Decoder) throws { value = try? Element(from: decoder) }
}

nonisolated extension KeyedDecodingContainer {
    func lossyList<T: Decodable>(_ key: Key) -> [T] {
        ((try? decodeIfPresent([Lossy<T>].self, forKey: key)) ?? nil)?.compactMap(\.value) ?? []
    }
}

/// Les clés de la v3 telles quelles, quand un modèle de l'app ne leur ressemble pas.
nonisolated struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    /// Écrite comme la v3 (`musicbrainz_id`) : le décodeur, réglé sur `convertFromSnakeCase`,
    /// compare des clés déjà passées en camelCase (`musicbrainzId`).
    init(_ snake: String) {
        let parts = snake.split(separator: "_")
        stringValue = String(parts.first ?? "") + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

nonisolated extension KeyedDecodingContainer where Key == AnyKey {
    func value<T: Decodable>(_ key: String) -> T? { (try? decodeIfPresent(T.self, forKey: AnyKey(key))) ?? nil }
}

nonisolated struct AuthResponse: Decodable, Sendable {
    /// Seulement en mode « bearer », celui que demande l'app.
    let token: String?
    let user: User
}

/// La réponse d'App Connect : une session d'appareil pour l'API de DroppedNeedle, ou un mot de passe
/// d'appli (Subsonic, Jellyfin) si l'admin a enregistré Platine pour ça, inutilisable ici.
nonisolated struct AppConnectToken: Decodable, Sendable {
    let accessToken: String
    let credentialKind: String?
}

nonisolated struct User: Decodable, Sendable {
    let id: String
    let displayName: String
    /// user, trusted ou admin.
    let role: String
}

nonisolated struct DiscoverQueue: Decodable, Sendable {
    let items: [DiscoverItem]

    init(from decoder: Decoder) throws {
        items = try decoder.container(keyedBy: AnyKey.self).lossyList(AnyKey("items"))
    }
}

nonisolated struct DiscoverItem: Decodable, Sendable, Identifiable {
    let releaseGroupMbid: String
    let albumName: String
    let artistName: String
    let artistMbid: String
    let recommendationReason: String
    let coverUrl: String?
    let inLibrary: Bool

    var id: String { releaseGroupMbid }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        releaseGroupMbid = try c.decode(String.self, forKey: AnyKey("musicbrainz_id"))
        albumName = c.value("title") ?? ""
        artistName = c.value("artist_name") ?? ""
        artistMbid = c.value("artist_id") ?? ""
        recommendationReason = c.value("recommendation_reason") ?? ""
        coverUrl = c.value("cover_url")
        inLibrary = c.value("in_library") ?? false
    }
}

nonisolated struct SearchResponse: Decodable, Sendable {
    let artists: [SearchResult]?
    let albums: [SearchResult]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        // Sans identifiant MusicBrainz, ni page d'artiste ni demande possible.
        artists = (c.lossyList(AnyKey("artists")) as [SearchResult]).filter { !$0.musicbrainzId.isEmpty }
        albums = (c.lossyList(AnyKey("albums")) as [SearchResult]).filter { !$0.musicbrainzId.isEmpty }
    }
}

nonisolated struct SearchResult: Decodable, Sendable, Identifiable {
    let title: String
    let musicbrainzId: String
    let artist: String?
    let year: Int?
    let inLibrary: Bool
    let requested: Bool
    let coverUrl: String?
    let thumbUrl: String?

    var id: String { musicbrainzId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        title = try c.decode(String.self, forKey: AnyKey("title"))
        musicbrainzId = c.value("musicbrainz_id") ?? ""
        artist = c.value("artist")
        year = c.value("year")
        inLibrary = c.value("in_library") ?? false
        requested = c.value("requested") ?? false
        coverUrl = nil
        thumbUrl = nil
    }
}

nonisolated struct AlbumRequest: Encodable, Sendable {
    let musicbrainzId: String
    let artist: String?
    let album: String?
    let year: Int?
}

nonisolated struct RequestAccepted: Decodable, Sendable {
    let success: Bool
    let message: String
}

nonisolated struct ActiveRequests: Decodable, Sendable {
    let items: [ActiveRequest]

    init(from decoder: Decoder) throws {
        items = try decoder.container(keyedBy: AnyKey.self).lossyList(AnyKey("items"))
    }
}

nonisolated struct ActiveRequest: Decodable, Sendable, Identifiable {
    /// L'album, ou l'enregistrement pour une plage demandée seule.
    let musicbrainzId: String
    /// album ou track.
    let requestKind: String?
    /// Le titre, pour une plage demandée seule.
    let trackTitle: String?
    let artistName: String
    let albumTitle: String
    let status: String
    let coverUrl: String?
    /// De 0 à 100, quand le client de téléchargement le dit.
    let progress: Double?
    /// Fin estimée, en secondes depuis 1970.
    let eta: Double?
    let errorMessage: String?

    var id: String { musicbrainzId }
}

nonisolated struct RequestHistory: Decodable, Sendable {
    let items: [PastRequest]

    init(from decoder: Decoder) throws {
        items = try decoder.container(keyedBy: AnyKey.self).lossyList(AnyKey("items"))
    }
}

nonisolated struct PastRequest: Decodable, Sendable, Identifiable {
    let musicbrainzId: String
    /// album ou track.
    let requestKind: String?
    /// Le titre, pour une plage demandée seule.
    let trackTitle: String?
    let artistName: String
    let albumTitle: String
    let status: String
    let coverUrl: String?
    let inLibrary: Bool?

    var id: String { musicbrainzId }

    /// L'historique n'en donne pas toujours : celle de l'album, si c'est un album.
    var cover: String? { coverUrl ?? (requestKind == "track" ? nil : DroppedNeedle.cover(nil, album: musicbrainzId)) }
}

nonisolated struct WantedList: Decodable, Sendable {
    let items: [WantedItem]

    init(from decoder: Decoder) throws {
        items = try decoder.container(keyedBy: AnyKey.self).lossyList(AnyKey("items"))
    }
}

nonisolated struct WantedItem: Decodable, Sendable, Identifiable {
    let releaseGroupMbid: String
    let artistName: String
    let albumTitle: String
    /// watching, stopped ou fulfilled.
    let state: String
    let checkCount: Int
    let coverUrl: String?
    let lastOutcome: String?

    var id: String { releaseGroupMbid }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        releaseGroupMbid = try c.decode(String.self, forKey: AnyKey("musicbrainz_id"))
        artistName = c.value("artist_name") ?? ""
        albumTitle = c.value("album_title") ?? ""
        state = c.value("state") ?? ""
        checkCount = c.value("check_count") ?? 0
        coverUrl = c.value("cover_url")
        lastOutcome = c.value("last_outcome")
    }
}

/// Un album à ouvrir ou à lire. `musicbrainzId` est l'identifiant qui sert aux routes : celui de la
/// discothèque pour un album qu'on a, celui de MusicBrainz pour un album du catalogue.
nonisolated struct LocalAlbum: Decodable, Sendable, Identifiable, Hashable {
    let musicbrainzId: String
    let name: String
    let artistName: String
    var artistMbid: String?
    let year: Int?
    let trackCount: Int?
    let primaryFormat: String?
    let coverUrl: String?
    /// Seulement depuis la discothèque.
    var totalSizeBytes: Int? = nil
    var dateAdded: String? = nil
    /// L'album sur MusicBrainz, quand on le sait : son catalogue, ses demandes, sa pochette.
    var releaseGroupMbid: String? = nil

    var id: String { musicbrainzId }
    var cover: String? { DroppedNeedle.cover(coverUrl, album: releaseGroupMbid ?? musicbrainzId) }

    init(musicbrainzId: String, name: String, artistName: String, artistMbid: String?, year: Int?, trackCount: Int?,
         primaryFormat: String?, coverUrl: String?, totalSizeBytes: Int? = nil, dateAdded: String? = nil,
         releaseGroupMbid: String? = nil) {
        self.musicbrainzId = musicbrainzId
        self.name = name
        self.artistName = artistName
        self.artistMbid = artistMbid
        self.year = year
        self.trackCount = trackCount
        self.primaryFormat = primaryFormat
        self.coverUrl = coverUrl
        self.totalSizeBytes = totalSizeBytes
        self.dateAdded = dateAdded
        self.releaseGroupMbid = releaseGroupMbid
    }

    /// Un album de la discothèque, tel que la v3 le décrit.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let id = try c.decode(String.self, forKey: AnyKey("id"))
        musicbrainzId = id
        name = c.value("title") ?? ""
        artistName = c.value("artist_name") ?? ""
        artistMbid = c.value("artist_mbid")
        year = c.value("year")
        trackCount = c.value("track_count")
        primaryFormat = c.value("format")
        releaseGroupMbid = c.value("release_group_mbid")
        let ownArt: Bool = c.value("cover_available") ?? false
        coverUrl = ownArt ? DroppedNeedle.artwork(album: id) : nil
        totalSizeBytes = c.value("total_size_bytes")
        dateAdded = (c.value("date_added") as Double?).map { String($0) }
    }
}

nonisolated struct LocalAlbumPage: Decodable, Sendable {
    let items: [LocalAlbum]
    let total: Int
    /// Le curseur de la page suivante, nil à la dernière.
    let next: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        items = c.lossyList(AnyKey("items"))
        total = c.value("total") ?? items.count
        next = c.value("next")
    }
}

nonisolated struct LocalTrackPage: Decodable, Sendable {
    let items: [LocalTrack]
    let total: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        items = c.lossyList(AnyKey("items"))
        total = c.value("total") ?? items.count
    }
}

nonisolated struct LocalTrack: Decodable, Sendable {
    let trackFileId: String
    let title: String
    let trackNumber: Int
    let discNumber: Int?
    let durationSeconds: Double?
    let format: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        trackFileId = try c.decode(String.self, forKey: AnyKey("id"))
        title = c.value("title") ?? ""
        trackNumber = c.value("track_number") ?? 0
        discNumber = c.value("disc_number")
        durationSeconds = c.value("duration_seconds")
        format = c.value("format")
    }

    func track(in album: LocalAlbum) -> Track {
        Track(id: trackFileId, title: title, artist: album.artistName, album: album.name,
              cover: album.cover, duration: durationSeconds, albumID: album.musicbrainzId,
              artistID: album.artistMbid, format: format)
    }
}

nonisolated struct Crate: Decodable, Sendable {
    var items: [CrateTrack]

    init(from decoder: Decoder) throws {
        items = try decoder.container(keyedBy: AnyKey.self).lossyList(AnyKey("items"))
    }
}

/// Une plage de la discothèque, avec la raison de la proposer quand il y en a une.
nonisolated struct CrateTrack: Decodable, Sendable, Identifiable {
    let trackFileId: String
    let title: String
    let albumName: String
    let artistName: String
    /// L'album dans la discothèque.
    let albumId: String?
    let coverUrl: String?
    let durationSeconds: Double?
    let format: String?
    /// recent, rediscover, surprise ou same_era.
    let reason: String?

    var id: String { trackFileId }

    var track: Track {
        Track(id: trackFileId, title: title, artist: artistName, album: albumName, cover: coverUrl,
              duration: durationSeconds, albumID: albumId, format: format)
    }

    /// Une suggestion du bac (`/library/suggestions`).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        trackFileId = try c.decode(String.self, forKey: AnyKey("track_id"))
        title = c.value("title") ?? ""
        albumName = c.value("album_title") ?? ""
        artistName = c.value("artist_name") ?? ""
        let album: String? = c.value("album_id")
        albumId = album
        coverUrl = (c.value("cover_available") ?? false) ? album.map { DroppedNeedle.artwork(album: $0) } : nil
        durationSeconds = c.value("duration_seconds")
        format = c.value("format")
        reason = c.value("reason")
    }

    init(trackFileId: String, title: String, albumName: String, artistName: String, albumId: String?, coverUrl: String?,
         durationSeconds: Double?, format: String?, reason: String? = nil) {
        self.trackFileId = trackFileId
        self.title = title
        self.albumName = albumName
        self.artistName = artistName
        self.albumId = albumId
        self.coverUrl = coverUrl
        self.durationSeconds = durationSeconds
        self.format = format
        self.reason = reason
    }
}

/// La recherche dans la discothèque : `/search` limité à la bibliothèque.
nonisolated struct LibrarySearch: Decodable, Sendable {
    let albums: [LocalAlbum]
    let tracks: [CrateTrack]

    init(albums: [LocalAlbum], tracks: [CrateTrack]) {
        self.albums = albums
        self.tracks = tracks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let albumHits: [LibraryHit] = c.lossyList(AnyKey("albums"))
        let trackHits: [LibraryHit] = c.lossyList(AnyKey("tracks"))
        albums = albumHits.compactMap { hit in
            guard let id = hit.id else { return nil }
            return LocalAlbum(musicbrainzId: id, name: hit.title, artistName: hit.artist ?? "", artistMbid: nil, year: hit.year,
                              trackCount: nil, primaryFormat: nil, coverUrl: hit.artMissing ? nil : DroppedNeedle.artwork(album: id),
                              releaseGroupMbid: hit.musicbrainzId)
        }
        tracks = trackHits.compactMap { hit in
            guard let id = hit.id, let detail = hit.track else { return nil }
            return CrateTrack(trackFileId: id, title: hit.title, albumName: detail.albumTitle, artistName: hit.artist ?? "",
                              albumId: detail.albumId,
                              coverUrl: detail.coverAvailable ? DroppedNeedle.artwork(album: detail.albumId)
                                  : DroppedNeedle.cover(nil, album: detail.releaseGroupMbid),
                              durationSeconds: detail.durationSeconds, format: detail.format)
        }
    }

    private struct LibraryHit: Decodable {
        let id: String?
        let title: String
        let artist: String?
        let year: Int?
        let musicbrainzId: String?
        let artMissing: Bool
        let track: Detail?

        struct Detail: Decodable {
            let albumId: String
            let albumTitle: String
            let coverAvailable: Bool
            let durationSeconds: Double?
            let format: String
            let releaseGroupMbid: String?
        }
    }
}

/// Une piste prête à lire, quelle que soit la route qui l'a fournie.
/// Codable pour garder les dernières écoutes d'un lancement à l'autre.
nonisolated struct Track: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let cover: String?
    let duration: Double?
    /// L'album à ouvrir : son identifiant dans la discothèque, ou sur MusicBrainz.
    let albumID: String?
    /// L'artiste sur MusicBrainz, pour « Aller à l'artiste ».
    var artistID: String?
    /// FLAC, MP3… affiché sous la barre de lecture.
    let format: String?
}

nonisolated struct Empty: Decodable, Sendable {}

// MARK: Accueil

/// Une section de l'accueil ou de Discover : la v3 les envoie en liste, chacune avec sa clé et sa forme.
nonisolated private struct PageSection: Decodable {
    let key: String
    let content: Content

    struct Content: Decodable {
        let shape: String
        let shelf: HomeSection?
        let shelves: [HomeSection]?
        let entries: [BecauseYouListen]?
        let picks: TopPicks?
        let weekly: WeeklyExploration?
    }
}

/// Les sections d'une page, rangées par clé.
nonisolated private struct Sections {
    private var byKey: [String: PageSection.Content] = [:]

    init(_ container: KeyedDecodingContainer<AnyKey>) {
        let list: [PageSection] = container.lossyList(AnyKey("sections"))
        for section in list { byKey[section.key] = section.content }
    }

    func shelf(_ key: String) -> HomeSection? { byKey[key]?.shelf }
    func shelves(_ key: String) -> [HomeSection]? { byKey[key]?.shelves }
    func entries(_ key: String) -> [BecauseYouListen]? { byKey[key]?.entries }
    func picks(_ key: String) -> TopPicks? { byKey[key]?.picks }
    func weekly(_ key: String) -> WeeklyExploration? { byKey[key]?.weekly }
}

nonisolated struct Home: Decodable, Sendable {
    let recentlyPlayed: HomeSection?
    let popularAlbums: HomeSection?
    let trendingArtists: HomeSection?
    let yourTopAlbums: HomeSection?
    let recommendedArtists: HomeSection?
    let freshReleases: HomeSection?
    let favoriteArtists: HomeSection?
    let topGenres: HomeSection?
    let weeklyExploration: WeeklyExploration?

    init(from decoder: Decoder) throws {
        let sections = Sections(try decoder.container(keyedBy: AnyKey.self))
        recentlyPlayed = sections.shelf("recently_played")
        popularAlbums = sections.shelf("popular_albums")
        trendingArtists = sections.shelf("trending_artists")
        yourTopAlbums = sections.shelf("your_top_albums")
        recommendedArtists = sections.shelf("artists_you_might_like")
        freshReleases = sections.shelf("fresh_releases")
        favoriteArtists = sections.shelf("favorite_artists")
        topGenres = sections.shelf("genre_list")
        weeklyExploration = sections.weekly("weekly_exploration")
    }
}

/// La playlist hebdomadaire de ListenBrainz, faite pour chacun.
nonisolated struct WeeklyExploration: Decodable, Sendable {
    let title: String
    let playlistDate: String
    let tracks: [WeeklyTrack]
}

nonisolated struct WeeklyTrack: Decodable, Sendable {
    let title: String
    let artistName: String
    let albumName: String
    let artistMbid: String?
    let releaseGroupMbid: String?
    let coverUrl: String?
}

nonisolated struct Decades: Decodable, Sendable {
    let items: [Decade]
}

/// Les décennies telles que le serveur les donne : sans leurs albums.
nonisolated struct DecadeShelves: Decodable, Sendable {
    let items: [Shelf]

    struct Shelf: Decodable, Sendable {
        let decade: Int
        let label: String
    }
}

nonisolated struct Decade: Decodable, Sendable, Identifiable {
    let decade: Int
    let label: String
    let albums: [LocalAlbum]

    var id: Int { decade }
}

nonisolated struct Genre: Decodable, Sendable {
    let genre: String
    let library: GenreShelf?
    let popular: GenreShelf?
}

nonisolated struct GenreShelf: Decodable, Sendable {
    let artists: [HomeItem]
    let albums: [HomeItem]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        artists = c.lossyList(AnyKey("artists"))
        albums = c.lossyList(AnyKey("albums"))
    }
}

nonisolated struct HomeSection: Decodable, Sendable {
    let title: String
    /// artists, albums, tracks ou genres.
    let type: String
    let items: [HomeItem]
    /// La graine d'une station de radio.
    var radioSeedType: String? = nil
    var radioSeedId: String? = nil

    init(title: String, type: String, items: [HomeItem]) {
        self.title = title
        self.type = type
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        title = c.value("title") ?? ""
        type = c.value("type") ?? ""
        items = c.lossyList(AnyKey("items"))
        radioSeedType = c.value("radio_seed_type")
        radioSeedId = c.value("radio_seed_id")
    }
}

/// Un artiste, un album, un morceau ou un style de l'accueil : la v3 les distingue par `kind`,
/// on les lit tous avec des champs facultatifs.
nonisolated struct HomeItem: Decodable, Sendable, Identifiable {
    let name: String
    let mbid: String?
    let artistName: String?
    let artistMbid: String?
    let imageUrl: String?
    let inLibrary: Bool?
    let requested: Bool?
    let listenCount: Int?
    /// L'identifiant dans la discothèque, quand on l'a.
    var localId: String? = nil

    var id: String { mbid ?? localId ?? name }

    var album: LocalAlbum {
        LocalAlbum(musicbrainzId: mbid ?? localId ?? "", name: name, artistName: artistName ?? "",
                   artistMbid: artistMbid, year: nil, trackCount: nil, primaryFormat: nil, coverUrl: imageUrl,
                   releaseGroupMbid: mbid)
    }

    var artist: ArtistRef? { mbid.map { ArtistRef(id: $0, name: name) } }

    /// Une image pour une mosaïque : la sienne, sinon la pochette de l'album.
    var artwork: String? { DroppedNeedle.cover(imageUrl, album: mbid) }

    init(name: String, mbid: String?, artistName: String?, artistMbid: String?, imageUrl: String?, inLibrary: Bool?,
         requested: Bool?, listenCount: Int?, localId: String? = nil) {
        self.name = name
        self.mbid = mbid
        self.artistName = artistName
        self.artistMbid = artistMbid
        self.imageUrl = imageUrl
        self.inLibrary = inLibrary
        self.requested = requested
        self.listenCount = listenCount
        self.localId = localId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let name: String = c.value("title") ?? c.value("name") else {
            throw DecodingError.keyNotFound(AnyKey("name"), .init(codingPath: c.codingPath, debugDescription: "Ni titre ni nom"))
        }
        self.name = name
        mbid = c.value("musicbrainz_id")
        artistName = c.value("artist_name")
        artistMbid = c.value("artist_id") ?? c.value("artist_mbid")
        imageUrl = c.value("image_url") ?? c.value("cover_url")
        inLibrary = c.value("in_library")
        requested = c.value("requested")
        listenCount = c.value("listen_count")
        localId = c.value("local_id")
    }
}

nonisolated struct LibraryStats: Decodable, Sendable {
    let totalTracks: Int
    let totalAlbums: Int
    let totalArtists: Int
    let totalSizeBytes: Int
    let formatBreakdown: [String: Int]?

    var totalSizeHuman: String { Int64(totalSizeBytes).formatted(.byteCount(style: .file)) }

    var formats: String {
        (formatBreakdown ?? [:]).sorted { $0.value > $1.value }.map { $0.key.uppercased() }.joined(separator: " · ")
    }
}

// MARK: Artistes

/// De quoi ouvrir la page d'un artiste.
nonisolated struct ArtistRef: Hashable, Sendable {
    let id: String
    let name: String
}

nonisolated struct Artist: Decodable, Sendable {
    let name: String
    let musicbrainzId: String
    let disambiguation: String?
    /// Group, Person, Orchestra…
    let type: String?
    /// Code pays : GB, FR…
    let country: String?
    let lifeSpan: LifeSpan?
    let image: String?
    let fanartUrl: String?
    let fanartUrl2: String?
    let fanartUrl3: String?
    let fanartUrl4: String?
    let wideThumbUrl: String?
    let thumbUrl: String?
    let tags: [String]?
    let aliases: [String]?
    let externalLinks: [ExternalLink]?
    let followed: Bool?
    let albums: [Release]?
    let singles: [Release]?
    let eps: [Release]?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        name = c.value("name") ?? ""
        musicbrainzId = c.value("musicbrainz_id") ?? ""
        disambiguation = c.value("disambiguation")
        type = c.value("type")
        country = c.value("country")
        lifeSpan = c.value("life_span")
        let images: ArtistImages? = c.value("images")
        image = images?.thumbUrl
        fanartUrl = images?.fanartUrl
        fanartUrl2 = images?.fanartUrl2
        fanartUrl3 = images?.fanartUrl3
        fanartUrl4 = images?.fanartUrl4
        wideThumbUrl = images?.wideThumbUrl
        thumbUrl = images?.thumbUrl
        tags = c.value("tags")
        aliases = c.value("aliases")
        externalLinks = c.lossyList(AnyKey("external_links"))
        followed = c.value("followed")
        albums = c.lossyList(AnyKey("albums"))
        singles = c.lossyList(AnyKey("singles"))
        eps = c.lossyList(AnyKey("eps"))
    }

    private struct ArtistImages: Decodable {
        let fanartUrl: String?
        let fanartUrl2: String?
        let fanartUrl3: String?
        let fanartUrl4: String?
        let wideThumbUrl: String?
        let thumbUrl: String?
    }
}

nonisolated struct Release: Decodable, Sendable, Identifiable {
    let id: String?
    let title: String?
    let type: String?
    let year: Int?
    let inLibrary: Bool?

    func album(by artist: ArtistRef) -> LocalAlbum {
        LocalAlbum(musicbrainzId: id ?? "", name: title ?? "", artistName: artist.name, artistMbid: artist.id,
                   year: year, trackCount: nil, primaryFormat: nil, coverUrl: nil, releaseGroupMbid: id)
    }
}

nonisolated struct LifeSpan: Decodable, Sendable {
    /// AAAA ou AAAA-MM-JJ.
    let begin: String?
    let end: String?
}

nonisolated struct ExternalLink: Decodable, Sendable {
    let type: String?
    let url: String
    let label: String?
}

/// La biographie, à part de la fiche de l'artiste.
nonisolated struct ArtistExtended: Decodable, Sendable {
    let description: String?
}

nonisolated struct TopAlbums: Decodable, Sendable {
    let albums: [TopAlbum]

    init(from decoder: Decoder) throws {
        albums = try decoder.container(keyedBy: AnyKey.self).lossyList(AnyKey("albums"))
    }
}

nonisolated struct TopAlbum: Decodable, Sendable {
    let title: String
    let listenCount: Int?
}

nonisolated struct ArtistReleases: Decodable, Sendable {
    let albums: [Release]
    let eps: [Release]
    let singles: [Release]

    init(albums: [Release], eps: [Release], singles: [Release]) {
        self.albums = albums
        self.eps = eps
        self.singles = singles
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        albums = c.lossyList(AnyKey("albums"))
        eps = c.lossyList(AnyKey("eps"))
        singles = c.lossyList(AnyKey("singles"))
    }
}

/// L'en-tête d'un album du catalogue.
nonisolated struct AlbumBasic: Decodable, Sendable {
    let releaseDate: String?
    let type: String?
    let artistId: String?
    let albumThumbUrl: String?
}

nonisolated struct AlbumInfo: Sendable {
    let releaseDate: String?
    let type: String?
    let label: String?
    let country: String?
    /// En millisecondes.
    let totalLength: Int?
    let albumBackUrl: String?
    let albumCdartUrl: String?
    let catalog: CatalogTracks

    init(basic: AlbumBasic, tracks: CatalogTracks) {
        releaseDate = basic.releaseDate
        type = basic.type
        label = tracks.label
        country = tracks.country
        totalLength = tracks.totalLength
        // La v3 ne donne plus le verso ni la galette.
        albumBackUrl = nil
        albumCdartUrl = nil
        catalog = tracks
    }
}

nonisolated struct CatalogTracks: Decodable, Sendable {
    let tracks: [CatalogTrack]
    let selectedReleaseMbid: String?
    var label: String? = nil
    var country: String? = nil
    /// En millisecondes.
    var totalLength: Int? = nil
}

/// Une plage d'un album du catalogue : pas de fichier, mais de quoi la demander.
nonisolated struct CatalogTrack: Decodable, Sendable, Identifiable {
    let position: Int
    let title: String
    let discNumber: Int?
    /// En millisecondes.
    let length: Int?
    let recordingId: String?

    var id: String { "\(discNumber ?? 1)-\(position)-\(title)" }
}

nonisolated struct TrackRequest: Encodable, Sendable {
    let artistName: String
    let trackTitle: String
    let albumTitle: String?
    let durationSeconds: Int?
    let releaseGroupMbid: String?
    let artistMbid: String?
    let releaseMbid: String?
    /// Rempli par `requestTrack`.
    var recordingMbid: String = ""

    init(artistName: String, trackTitle: String, albumTitle: String?, durationSeconds: Int?, releaseGroupMbid: String?,
         artistMbid: String?, releaseId: String?) {
        self.artistName = artistName
        self.trackTitle = trackTitle
        self.albumTitle = albumTitle
        self.durationSeconds = durationSeconds
        self.releaseGroupMbid = releaseGroupMbid
        self.artistMbid = artistMbid
        releaseMbid = releaseId
    }
}

nonisolated struct TrackRequestStatus: Decodable, Sendable {
    /// awaiting_approval, queued…
    let status: String
}

nonisolated struct TopSongs: Decodable, Sendable {
    let songs: [TopSong]

    init(songs: [TopSong]) { self.songs = songs }

    init(from decoder: Decoder) throws {
        songs = try decoder.container(keyedBy: AnyKey.self).lossyList(AnyKey("songs"))
    }
}

nonisolated struct TopSong: Decodable, Sendable {
    let title: String
    let artistName: String
    let recordingMbid: String?
    let releaseGroupMbid: String?
    let originalReleaseMbid: String?
    let releaseName: String?
    /// Toutes écoutes confondues sur ListenBrainz ou Last.fm, pas les tiennes.
    let listenCount: Int?
}

nonisolated struct SimilarArtists: Decodable, Sendable {
    let similarArtists: [SimilarArtist]

    init(from decoder: Decoder) throws {
        similarArtists = try decoder.container(keyedBy: AnyKey.self).lossyList(AnyKey("similar_artists"))
    }
}

nonisolated struct SimilarArtist: Decodable, Sendable, Identifiable {
    let musicbrainzId: String
    let name: String
    let imageUrl: String?

    var id: String { musicbrainzId }
}

nonisolated struct FollowStatus: Decodable, Sendable {
    let followed: Bool
}

// MARK: Concerts

nonisolated struct Concerts: Decodable, Sendable {
    /// Faux quand l'admin n'a branché aucune source (Ticketmaster, Skiddle).
    let configured: Bool
    let items: [Concert]

    init(configured: Bool, items: [Concert]) {
        self.configured = configured
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        configured = c.value("configured") ?? false
        items = c.lossyList(AnyKey("items"))
    }
}

nonisolated struct Concert: Decodable, Sendable, Identifiable {
    let artistMbid: String
    let artistName: String
    let eventName: String
    /// AAAA-MM-JJ, à l'heure de la salle.
    let localDate: String
    /// scheduled, cancelled ou rescheduled.
    let status: String
    let sourceEventId: String
    let venueName: String?
    let city: String?
    let startsAt: String?
    let ticketUrl: String?

    var id: String { sourceEventId }
}

// MARK: Présence et scrobbling

nonisolated struct NowPlayingReport: Encodable, Sendable {
    let trackName: String
    let artistName: String
    let albumName: String?
    let coverUrl: String
    var source = "local"
    var device = "Platine (iPhone)"
    let isPaused: Bool
    let progressMs: Int
    let durationMs: Int
}

/// Une écoute pour ListenBrainz ou Last.fm, telle que le serveur la relaie.
nonisolated struct Listen: Encodable, Sendable {
    let trackName: String
    let artistName: String
    let albumName: String
    let durationMs: Int
    var timestamp: Int?
    var source = "local"
    let releaseGroupMbid: String?
}

// MARK: Réglages du compte

nonisolated struct Profile: Decodable, Sendable {
    let displayName: String
    let avatarUrl: String?
    let username: String?
    let email: String?
}

nonisolated struct Connections: Decodable, Sendable {
    let connections: [Connection]

    init(from decoder: Decoder) throws {
        connections = try decoder.container(keyedBy: AnyKey.self).lossyList(AnyKey("connections"))
    }
}

nonisolated struct Connection: Decodable, Sendable, Identifiable {
    let service: String
    let enabled: Bool
    let username: String?

    var id: String { service }
}

/// Le scrobbling et ce que les autres voient de ce qu'on écoute.
nonisolated struct ListeningPreferences: Codable, Sendable, Equatable {
    var scrobbleToLastfm: Bool
    var scrobbleToListenbrainz: Bool
    /// listenbrainz ou lastfm.
    var primaryMusicSource: String
    /// full, track_hidden ou offline.
    var nowPlayingVisibility: String

    enum CodingKeys: String, CodingKey {
        case scrobbleToLastfm, scrobbleToListenbrainz, primaryMusicSource, nowPlayingVisibility
    }

    /// La v3 peut omettre un champ : sa valeur par défaut, alors.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scrobbleToLastfm = (try? c.decodeIfPresent(Bool.self, forKey: .scrobbleToLastfm)) ?? false
        scrobbleToListenbrainz = (try? c.decodeIfPresent(Bool.self, forKey: .scrobbleToListenbrainz)) ?? false
        primaryMusicSource = (try? c.decodeIfPresent(String.self, forKey: .primaryMusicSource)) ?? "listenbrainz"
        nowPlayingVisibility = (try? c.decodeIfPresent(String.self, forKey: .nowPlayingVisibility)) ?? "full"
    }
}

nonisolated struct Version: Decodable, Sendable {
    let version: String
}

// MARK: JSON brut

/// Une valeur JSON quelconque, pour les formulaires de réglages.
nonisolated enum JSON: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value):
            // Les entiers repartent en entiers : le serveur les valide comme tels.
            if value.rounded() == value, abs(value) < 1e15 { try container.encode(Int(value)) } else { try container.encode(value) }
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    /// La valeur sous un chemin « a.b.c », ou nil.
    subscript(path: String) -> JSON? {
        get {
            path.split(separator: ".").reduce(Optional(self)) { node, key in
                if case let .object(fields)? = node { fields[String(key)] } else { nil }
            }
        }
        set {
            let keys = path.split(separator: ".").map(String.init)
            self = Self.setting(self, keys[...], newValue ?? .null)
        }
    }

    private static func setting(_ node: JSON, _ keys: ArraySlice<String>, _ value: JSON) -> JSON {
        guard let key = keys.first else { return value }
        var fields: [String: JSON] = if case let .object(existing) = node { existing } else { [:] }
        fields[key] = setting(fields[key] ?? .null, keys.dropFirst(), value)
        return .object(fields)
    }

    var bool: Bool? { if case let .bool(value) = self { value } else { nil } }
    var number: Double? { if case let .number(value) = self { value } else { nil } }
    var string: String? { if case let .string(value) = self { value } else { nil } }
    var array: [JSON]? { if case let .array(value) = self { value } else { nil } }
}

// MARK: Paroles

nonisolated struct Lyrics: Decodable, Sendable {
    let text: String
    let isSynced: Bool
    let lines: [Line]

    struct Line: Decodable, Sendable {
        let text: String
        let startSeconds: Double?
    }
}

// MARK: Discothèque complète

nonisolated struct TopAlbumRange: Decodable, Sendable {
    let items: [HomeItem]

    init(from decoder: Decoder) throws {
        items = try decoder.container(keyedBy: AnyKey.self).lossyList(AnyKey("items"))
    }
}

nonisolated struct LibraryTracks: Decodable, Sendable {
    let items: [LibraryTrack]
    let total: Int
    let next: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        items = c.lossyList(AnyKey("items"))
        total = c.value("total") ?? items.count
        next = c.value("next")
    }
}

nonisolated struct LibraryTrack: Decodable, Sendable, Identifiable {
    let id: String
    let title: String
    let albumId: String
    let albumTitle: String
    let artistName: String
    let releaseGroupMbid: String?
    let artistMbid: String?
    let durationSeconds: Double?
    let format: String?
    let coverAvailable: Bool?

    var track: Track {
        let cover = coverAvailable == true ? DroppedNeedle.artwork(album: albumId) : DroppedNeedle.cover(nil, album: releaseGroupMbid)
        return Track(id: id, title: title, artist: artistName, album: albumTitle, cover: cover,
                     duration: durationSeconds, albumID: albumId, artistID: artistMbid, format: format)
    }
}

nonisolated struct LibraryArtists: Decodable, Sendable {
    let items: [LibraryArtist]
    let total: Int
    let next: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        items = c.lossyList(AnyKey("items"))
        total = c.value("total") ?? items.count
        next = c.value("next")
    }
}

nonisolated struct LibraryArtist: Decodable, Sendable, Identifiable {
    let id: String
    let name: String
    let musicbrainzArtistId: String?
    let albumCount: Int?
    let trackCount: Int?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.decode(String.self, forKey: AnyKey("id"))
        name = c.value("name") ?? ""
        musicbrainzArtistId = c.value("artist_mbid")
        albumCount = c.value("album_count")
        trackCount = c.value("track_count")
    }
}

// MARK: Playlists

nonisolated struct Playlists: Decodable, Sendable {
    let playlists: [PlaylistSummary]

    /// Les playlists privées des autres arrivent masquées, sans nom : on ne les garde pas.
    init(from decoder: Decoder) throws {
        playlists = try decoder.container(keyedBy: AnyKey.self).lossyList(AnyKey("playlists"))
    }
}

nonisolated struct PlaylistSummary: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let trackCount: Int?
    let coverUrls: [String]?
    let customCoverUrl: String?
    let isOwner: Bool?
    let ownerName: String?

    var covers: [String?] { customCoverUrl.map { [$0] } ?? (coverUrls ?? []).map { $0 } }
}

nonisolated struct PlaylistDetail: Decodable, Sendable {
    let id: String
    let name: String
    let tracks: [PlaylistEntry]
    let isOwner: Bool?
    var ownerName: String? = nil
    /// En secondes.
    var totalDuration: Double? = nil
    /// En secondes depuis 1970.
    var createdAt: Double? = nil
    var updatedAt: Double? = nil
    var isPublic: Bool? = nil
}

nonisolated struct PlaylistEntry: Decodable, Sendable, Identifiable {
    let id: String
    let trackName: String
    let artistName: String
    let albumName: String
    let albumId: String?
    let artistId: String?
    let trackSourceId: String?
    let coverUrl: String?
    let sourceType: String?
    let duration: Double?
    let format: String?
    let libraryFileId: String?

    /// Jouable quand le morceau est dans la discothèque locale.
    var track: Track? {
        let file = libraryFileId ?? (sourceType == "local" ? trackSourceId : nil)
        return file.map {
            Track(id: $0, title: trackName, artist: artistName, album: albumName,
                  cover: DroppedNeedle.cover(coverUrl, album: albumId), duration: duration,
                  albumID: albumId, artistID: artistId, format: format)
        }
    }
}

nonisolated private struct PlaylistAddition: Encodable, Sendable {
    let tracks: [PlaylistTrackInput]
}

nonisolated private struct PlaylistTrackInput: Encodable, Sendable {
    let trackName: String
    let artistName: String
    let albumName: String
    let albumId: String?
    let artistId: String?
    let trackSourceId: String
    let coverUrl: String?
    var sourceType = "local"
    let format: String?
    let duration: Double?

    init(_ track: Track) {
        trackName = track.title
        artistName = track.artist
        albumName = track.album
        albumId = track.albumID
        artistId = track.artistID
        trackSourceId = track.id
        coverUrl = track.cover
        format = track.format
        duration = track.duration
    }
}

nonisolated private struct PlaylistMove: Encodable, Sendable {
    let trackId: String
    let newPosition: Int
}

// MARK: Classements

nonisolated enum Chart: String, Sendable {
    case popular = "popular/albums"
    case trending = "trending/artists"
    case yourTop = "your-top/albums"
}

nonisolated struct ChartPage: Decodable, Sendable {
    let label: String
    let items: [HomeItem]
    let hasMore: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        label = c.value("label") ?? ""
        items = c.lossyList(AnyKey("items"))
        hasMore = c.value("has_more") ?? false
    }
}

// MARK: Spotify

nonisolated struct SpotifyPlaylists: Decodable, Sendable {
    let playlists: [SpotifyPlaylist]
}

nonisolated struct SpotifyPlaylist: Decodable, Sendable, Identifiable {
    let id: String
    let name: String
    let trackCount: Int
    let coverUrl: String?
    let owner: String
    let importedPlaylistId: String?
}

nonisolated struct SpotifyImport: Decodable, Sendable {
    let playlistId: String
}

// MARK: Suivis

nonisolated struct FollowedArtists: Decodable, Sendable {
    let artists: [FollowedArtist]

    init(from decoder: Decoder) throws {
        artists = try decoder.container(keyedBy: AnyKey.self).lossyList(AnyKey("artists"))
    }
}

nonisolated struct FollowedArtist: Decodable, Sendable, Identifiable {
    let mbid: String
    let name: String
    let autoDownload: Bool?
    let imageUrl: String?

    var id: String { mbid }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        mbid = try c.decode(String.self, forKey: AnyKey("artist_mbid"))
        name = c.value("name") ?? ""
        autoDownload = c.value("auto_download")
        imageUrl = nil
    }
}

nonisolated struct NewReleases: Decodable, Sendable {
    let items: [NewRelease]
    let total: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        items = c.lossyList(AnyKey("items"))
        total = c.value("total") ?? items.count
    }
}

nonisolated struct NewRelease: Decodable, Sendable, Identifiable {
    let releaseGroupMbid: String
    let title: String
    let artistName: String
    let artistMbid: String
    let primaryType: String?
    let firstReleaseDate: String?
    let inLibrary: Bool?

    var id: String { releaseGroupMbid }

    var album: LocalAlbum {
        LocalAlbum(musicbrainzId: releaseGroupMbid, name: title, artistName: artistName, artistMbid: artistMbid,
                   year: firstReleaseDate.flatMap { Int($0.prefix(4)) }, trackCount: nil, primaryFormat: nil, coverUrl: nil,
                   releaseGroupMbid: releaseGroupMbid)
    }
}

nonisolated struct Unseen: Decodable, Sendable {
    let count: Int
}

nonisolated struct ConcertCities: Codable, Sendable {
    let items: [ConcertCity]
}

nonisolated struct ConcertCity: Codable, Sendable, Hashable {
    let cityName: String
    let latitude: Double
    let longitude: Double
    var radiusKm: Double
    let countryCode: String?
}

nonisolated struct CitySearch: Decodable, Sendable {
    let items: [CityResult]
}

nonisolated struct CityResult: Decodable, Sendable, Hashable {
    let name: String
    let latitude: Double
    let longitude: Double
    let countryCode: String?
    let country: String?
    let region: String?
}

// MARK: Discover

nonisolated struct Discover: Decodable, Sendable {
    let topPicks: TopPicks?
    let dailyMixes: [HomeSection]?
    let radioSections: [HomeSection]?
    let becauseYouListenTo: [BecauseYouListen]?
    let listenersLikeYou: HomeSection?
    let rediscover: HomeSection?
    let missingEssentials: HomeSection?
    let artistsYouMightLike: HomeSection?
    let popularInYourGenres: HomeSection?
    let newFromFollowed: HomeSection?
    let anniversaries: HomeSection?
    let unexploredGenres: HomeSection?
    let genreList: HomeSection?
    let genreArtwork: [String: GenreArtwork]?
    let globallyTrending: HomeSection?
    let refreshing: Bool?
    let generatedAt: Double?
    /// Les dernières recommandations gardées sur l'appareil, pendant que le serveur recalcule.
    var fromCache = false

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let sections = Sections(c)
        topPicks = sections.picks("top_picks")
        dailyMixes = sections.shelves("daily_mixes")
        radioSections = sections.shelves("radio_sections")
        becauseYouListenTo = sections.entries("because_you_listen_to")
        listenersLikeYou = sections.shelf("listeners_like_you")
        rediscover = sections.shelf("rediscover")
        missingEssentials = sections.shelf("missing_essentials")
        artistsYouMightLike = sections.shelf("artists_you_might_like")
        popularInYourGenres = sections.shelf("popular_in_your_genres")
        newFromFollowed = sections.shelf("new_from_followed")
        anniversaries = sections.shelf("anniversaries")
        unexploredGenres = sections.shelf("unexplored_genres")
        genreList = sections.shelf("genre_list")
        genreArtwork = c.value("genre_artwork")
        globallyTrending = sections.shelf("globally_trending")
        refreshing = c.value("refreshing")
        generatedAt = c.value("generated_at")
    }

    /// Sans date, le serveur n'a pas ces recommandations sous la main, même s'il ne dit pas
    /// `refreshing` : il renvoie alors tout vide, puis les retrouve une minute plus tard.
    var isPending: Bool { refreshing == true || generatedAt == nil }

    /// Vrai tant que le serveur n'a encore rien calculé pour soi.
    var isEmpty: Bool {
        (topPicks?.items.isEmpty ?? true) && (dailyMixes ?? []).isEmpty && (radioSections ?? []).isEmpty
            && (becauseYouListenTo ?? []).isEmpty
            && [listenersLikeYou, rediscover, missingEssentials, artistsYouMightLike, popularInYourGenres,
                newFromFollowed, anniversaries].allSatisfy { $0?.items.isEmpty ?? true }
    }
}

/// Les pochettes d'un genre, s'il en a dans la discothèque.
nonisolated struct GenreArtwork: Decodable, Sendable {
    struct Album: Decodable, Sendable {
        let albumId: String
        let coverVersion: Int?
    }

    let albums: [Album]?

    var covers: [String?] {
        (albums ?? []).map { DroppedNeedle.artwork(album: $0.albumId, version: $0.coverVersion) }
    }
}

nonisolated struct IgnoredRelease: Encodable, Sendable {
    let releaseGroupMbid: String
    let artistMbid: String
    let releaseName: String
    let artistName: String
}

nonisolated struct PlaylistSuggestions: Decodable, Sendable {
    let suggestions: HomeSection
}

nonisolated struct TopPicks: Decodable, Sendable {
    let items: [TopPick]

    init(from decoder: Decoder) throws {
        items = try decoder.container(keyedBy: AnyKey.self).lossyList(AnyKey("items"))
    }
}

nonisolated struct TopPick: Decodable, Sendable, Identifiable {
    let album: HomeItem
    let matchPct: Int?
    let reasons: [String]?
    let seedArtist: String?

    var id: String { album.id }
}

nonisolated struct BecauseYouListen: Decodable, Sendable, Identifiable {
    let seedArtist: String
    let seedArtistMbid: String
    let section: HomeSection

    var id: String { seedArtistMbid }
}

#if DEBUG
/// ponytail: la lecture des formes v3, lancée avec `-platineSelfTest YES`. Des réponses écrites d'après
/// l'OpenAPI du serveur (pas captées en vrai) : elles vérifient surtout les clés snake_case.
nonisolated enum V3DecodingCheck {
    static func run() {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
            do { return try decoder.decode(T.self, from: Data(json.utf8)) } catch { print("platine v3 check: \(T.self) \(error)"); return nil }
        }
        let album = decode(LocalAlbumPage.self, """
        {"items":[{"id":"loc-1","title":"Vol. 1","artist_name":"The Plot in You","artist_id":"a","artist_mbid":"m-1",
        "release_group_mbid":"rg-1","track_count":1,"format":"flac","cover_available":true,"total_size_bytes":10,
        "date_added":1793709775.9,"art_missing":false,"favorite":false,"identity_state":"x","is_compilation":false,
        "total_duration_seconds":208}],"next":"c2","total":201}
        """)
        assert(album?.items.first?.name == "Vol. 1" && album?.items.first?.releaseGroupMbid == "rg-1" && album?.next == "c2")
        assert(album?.items.first?.cover == DroppedNeedle.prefix + "/library/albums/loc-1/artwork?size=500")
        let home = decode(Home.self, """
        {"sections":[{"key":"popular_albums","zone":"whats_hot","content":{"shape":"shelf","shelf":{"title":"Populaire",
        "type":"albums","items":[{"kind":"album","title":"Discovery","musicbrainz_id":"rg-2","artist_name":"Daft Punk",
        "in_library":true,"requested":false,"local_id":"loc-2"}]}}},
        {"key":"weekly_exploration","zone":"for_you","content":{"shape":"weekly","weekly":{"title":"W","playlist_date":"2026-11-16",
        "source_url":"u","tracks":[{"title":"T","artist_name":"A","album_name":"B"}]}}}],
        "genre_artwork":{},"genre_artwork_schema_version":"1","refreshing":false,"service_prompts":[]}
        """)
        assert(home?.popularAlbums?.items.first?.name == "Discovery" && home?.popularAlbums?.items.first?.localId == "loc-2")
        assert(home?.weeklyExploration?.playlistDate == "2026-11-16")
        let discover = decode(Discover.self, """
        {"sections":[{"key":"daily_mixes","zone":"made_for_you","content":{"shape":"shelves","shelves":[{"title":"Daily Mix 1 - Rock",
        "type":"albums","items":[]}]}},{"key":"top_picks","zone":"for_you","content":{"shape":"picks","picks":{"title":"P",
        "personalizing":false,"items":[{"album":{"title":"X","in_library":false,"requested":false},"match_pct":51,"reasons":[]}]}}}],
        "discover_queue_enabled":true,"genre_artwork":{},"genre_artwork_schema_version":"1","refreshing":false,
        "service_prompts":[],"generated_at":1794000000}
        """)
        assert(discover?.dailyMixes?.first?.title == "Daily Mix 1 - Rock" && discover?.topPicks?.items.first?.matchPct == 51)
        assert(discover?.isPending == false)
        let artist = decode(Artist.self, """
        {"name":"Muse","musicbrainz_id":"m","albums":[{"id":"r1","in_library":true,"requested":false}],"eps":[],"singles":[],
        "aliases":[],"tags":["rock"],"external_links":[],"followed":true,"images":{"fanart_url":"f","fanart_url_2":"f2","thumb_url":"t"},
        "appears_in_library":true,"auto_download":false,"auto_download_state":"off","in_library":true,"release_group_count":1,
        "service_status":null,"source":"musicbrainz"}
        """)
        assert(artist?.fanartUrl2 == "f2" && artist?.thumbUrl == "t" && artist?.albums?.first?.inLibrary == true)
        let tracks = decode(LibraryTracks.self, """
        {"items":[{"id":"t1","title":"Divide","album_id":"loc-1","album_title":"Vol. 1","artist_name":"A","album_artist_name":"A",
        "release_group_mbid":"2cb5da39-27ed-44ea-8f02-f0d4af3bec9e","artist_mbid":"m-1","duration_seconds":208.8,"format":"flac","cover_available":false,
        "art_missing":true,"disc_number":1,"track_number":1,"favorite":false,"file_size_bytes":1,"row_revision":1}],"total":1}
        """)
        assert(tracks?.items.first?.track.albumID == "loc-1" && tracks?.items.first?.track.cover?.contains("release-group/2cb5da39-27ed-44ea-8f02-f0d4af3bec9e") == true)
        let prefs = decode(ListeningPreferences.self, #"{"scrobble_to_lastfm":true}"#)
        assert(prefs?.scrobbleToLastfm == true && prefs?.nowPlayingVisibility == "full")
        let search = decode(SearchResponse.self, """
        {"albums":[{"title":"Homework","musicbrainz_id":"rg-3","artist":"Daft Punk","in_library":false,"requested":false,
        "art_missing":false,"kind":"album","score":1},{"title":"Sans id","in_library":false,"requested":false,"art_missing":true,
        "kind":"album","score":1}],"artists":[],"tracks":[],"album_status":"ok","artist_status":"ok","track_status":"ok"}
        """)
        assert(search?.albums.map(\.musicbrainzId) == ["rg-3"])
        // Sur l'erreur standard : pas de tampon, le message survit si l'app est fermée juste après.
        FileHandle.standardError.write(Data("platine v3 check: \(album != nil && home != nil && discover != nil && artist != nil && tracks != nil ? "ok" : "ÉCHEC")\n".utf8))
    }
}
#endif

nonisolated extension Array {
    /// Alterne les groupes (un élément de chacun à tour de rôle), dans l'ordre où ils apparaissent,
    /// avec au plus `cap` éléments par groupe.
    func interleaved(cap: Int = .max, by group: (Element) -> String) -> [Element] {
        var order: [String] = []
        var groups: [String: [Element]] = [:]
        for item in self {
            let key = group(item)
            if groups[key] == nil { order.append(key) }
            if groups[key, default: []].count < cap { groups[key, default: []].append(item) }
        }
        var result: [Element] = []
        for round in 0 ..< (groups.values.map(\.count).max() ?? 0) {
            for key in order where round < groups[key]!.count { result.append(groups[key]![round]) }
        }
        return result
    }
}
