import Foundation
import Synchronization

/// Le mode démo, pour l'App Review : « demo » dans le champ Serveur, n'importe quel identifiant.
/// Un faux DroppedNeedle répond depuis l'app (`DemoServer`, rien ne sort) ; les morceaux et les
/// pochettes viennent de Git LFS (`Demo/media` du dépôt), pas du build.
// ponytail: une discothèque figée de trois albums ; demandes, concerts et suivis restent vides.
nonisolated enum Demo {
    static let server = URL(string: "https://demo.platine.invalid")!
    static let media = URL(string: "https://media.githubusercontent.com/media/cbrunie/platine/main/Demo/media/")!

    static func isDemo(_ url: URL) -> Bool { url.host() == server.host() }
    static func stream(_ track: String) -> URL { media.appending(path: "\(track).mp3") }

    /// Une image de l'API (pochette d'album, photo d'artiste) : son fichier sur Git LFS.
    static func image(_ path: String) -> URL? {
        let parts = path.split(separator: "?")[0].split(separator: "/").map(String.init)
        guard let id = parts.first(where: { UUID(uuidString: $0) != nil }) else { return nil }
        return media.appending(path: (parts.contains("artist") ? "artist-" : "cover-") + id + ".jpg")
    }

    // MARK: Discothèque (musique sous licence CC BY, voir Demo/CREDITS.md)

    struct Artist {
        let id, name, country, bio: String
        let tags: [String]
    }

    struct Album {
        let id, title: String
        let artist: Artist
        let year: Int?
        let file: String
        let tracks: [(title: String, seconds: Double)]
        /// Il y a tant de jours.
        let added: Double
    }

    static let jan = Artist(id: "b0000000-0000-4000-8000-000000000001", name: "Jan Morgenstern", country: "DE",
                            bio: "Compositeur allemand, auteur des musiques des films libres du Blender Studio : Elephants Dream, Big Buck Bunny et Sintel.",
                            tags: ["musique de film", "orchestral"])
    static let kevin = Artist(id: "b0000000-0000-4000-8000-000000000002", name: "Kevin MacLeod", country: "US",
                              bio: "Compositeur américain qui publie des milliers de morceaux sous licence Creative Commons sur incompetech.com.",
                              tags: ["comédie", "jazz", "ambiance"])
    static let artists = [jan, kevin]

    static let albums = [
        Album(id: "a0000000-0000-4000-8000-000000000001", title: "Elephants Dream (Original Film Score)", artist: jan, year: 2006, file: "ed",
              tracks: [("The Wires", 75), ("Typewriter Dance", 70), ("The Safest Place", 45), ("Emo Creates", 60),
                       ("End Title", 91), ("Teaser Music", 75), ("Ambience", 110)], added: 2),
        Album(id: "a0000000-0000-4000-8000-000000000002", title: "Comédies (sélection)", artist: kevin, year: nil, file: "comedy",
              tracks: [("Sneaky Snitch", 137), ("Monkeys Spinning Monkeys", 125), ("Fluffing a Duck", 67), ("Carefree", 205),
                       ("Local Forecast - Elevator", 189), ("Cool Vibes", 218), ("Funkorama", 201)], added: 5),
        Album(id: "a0000000-0000-4000-8000-000000000003", title: "Suspense (sélection)", artist: kevin, year: nil, file: "suspense",
              tracks: [("Investigations", 94), ("Wallpaper", 220), ("Darkest Child", 239), ("Hitman", 201), ("Lightless Dawn", 380)], added: 9),
    ]

    static func trackID(_ album: Album, _ index: Int) -> String { "\(album.file)-\(index + 1)" }
    static func artwork(_ album: Album) -> String { DroppedNeedle.artwork(album: album.id) }
    static func photo(_ artist: Artist) -> String { DroppedNeedle.artistImage(artist.id) }

    static let allTracks: [(album: Album, index: Int)] = albums.flatMap { album in album.tracks.indices.map { (album, $0) } }
    static func track(_ id: String) -> (album: Album, index: Int)? { allTracks.first { trackID($0.album, $0.index) == id } }
}

/// Le faux serveur. Les playlists sont gardées en mémoire le temps de la session.
nonisolated final class DemoServer: URLProtocol {
    private struct Playlist {
        var id, name: String
        var entries: [(entry: String, track: String)]
    }

    private static let playlists = Mutex([
        Playlist(id: "p-demo", name: "Pour travailler", entries: ["ed-3", "suspense-1", "ed-7", "comedy-4"].map { ("e-\($0)", $0) }),
    ])

    override class func canInit(with request: URLRequest) -> Bool { request.url.map(Demo.isDemo) ?? false }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let query = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [],
                               uniquingKeysWith: { $1 })
        let path = url.path().split(separator: "/").map(String.init).dropFirst(2) // « api », « v3 »
        let (status, object) = Self.respond(request.httpMethod ?? "GET", Array(path), query, Self.body(of: request))
        let data = object.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                                              headerFields: ["Content-Type": "application/json"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// URLSession passe le corps en flux, pas dans `httpBody`.
    private static func body(of request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 { data.append(buffer, count: count) }
            stream.close()
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: Routes

    static func respond(_ method: String, _ path: [String], _ query: [String: String], _ body: [String: Any]) -> (Int, Any?) {
        let part = { (index: Int) in path.indices.contains(index) ? path[index] : "" }
        let text = query["q"]?.lowercased() ?? ""
        func matches(_ value: String) -> Bool { text.isEmpty || value.lowercased().contains(text) }
        let me: [String: Any] = ["id": "demo", "display_name": "Démo", "role": "user", "username": "demo"]

        switch (method, part(0), part(1), part(2), part(3)) {
        case ("POST", "auth", "login", "", ""):
            return (200, ["token": "demo", "user": me])
        case ("GET", "me", "", "", ""):
            return (200, me)
        case ("GET", "version", "", "", ""):
            return (200, ["version": "démo"])

        // Discothèque
        case ("GET", "library", "recently-added", "", ""):
            return (200, page(Demo.albums.sorted { $0.added < $1.added }.map(album)))
        case ("GET", "library", "albums", "", ""):
            var found = Demo.albums.filter { matches($0.title) || matches($0.artist.name) }
            if let decade = query["decade"].flatMap(Int.init) { found = found.filter { ($0.year ?? 0) / 10 * 10 == decade } }
            if query["sort"] == "name" { found.sort { $0.title < $1.title } }
            return (200, page(found.map(album)))
        case ("GET", "library", "albums", "match", let id), ("GET", "library", "albums", let id, ""):
            guard let found = Demo.albums.first(where: { $0.id == id }) else { return part(2) == "match" ? (200, page([])) : (404, nil) }
            return (200, part(2) == "match" ? page(found.tracks.indices.map { track(found, $0) }) : album(found))
        case ("GET", "library", "suggestions", "", ""):
            let reasons = ["recent", "rediscover", "surprise", "same_era"]
            return (200, ["items": Demo.allTracks.enumerated().map { offset, entry in
                crate(entry.album, entry.index, reason: reasons[offset % reasons.count])
            }])
        case ("GET", "library", "stats", "", ""):
            let count = Demo.allTracks.count
            return (200, ["total_tracks": count, "total_albums": Demo.albums.count, "total_artists": Demo.artists.count,
                          "total_size_bytes": 50_000_000, "format_breakdown": ["mp3": count]])
        case ("GET", "library", "decades", "", ""):
            return (200, ["items": [["decade": 2000, "label": "Années 2000"]]])
        case ("GET", "library", "tracks", "", ""):
            let found = Demo.allTracks.filter { matches($0.album.tracks[$0.index].title) }
                .sorted { $0.album.tracks[$0.index].title < $1.album.tracks[$1.index].title }
            return (200, page(found.map { libraryTrack($0.album, $0.index) }))
        case ("GET", "library", "artists", "", ""):
            return (200, page(Demo.artists.map { artist in
                let albums = Demo.albums.filter { $0.artist.id == artist.id }
                return ["id": artist.id, "name": artist.name, "artist_mbid": artist.id, "album_count": albums.count,
                        "track_count": albums.map(\.tracks.count).reduce(0, +)]
            }))
        case ("GET", "search", "", "", ""):
            let albums = Demo.albums.filter { matches($0.title) || matches($0.artist.name) }
            if query["scope"] == "library" {
                let tracks = Demo.allTracks.filter { matches($0.album.tracks[$0.index].title) || matches($0.album.artist.name) }
                return (200, ["albums": albums.map { ["id": $0.id, "title": $0.title, "artist": $0.artist.name, "year": null($0.year),
                                                      "art_missing": false] },
                              "tracks": tracks.map { entry in
                                  let (album, index) = entry
                                  return ["id": Demo.trackID(album, index), "title": album.tracks[index].title, "artist": album.artist.name,
                                          "art_missing": false,
                                          "track": ["album_id": album.id, "album_title": album.title, "cover_available": true,
                                                    "duration_seconds": album.tracks[index].seconds, "format": "mp3"]]
                              }])
            }
            return (200, ["artists": Demo.artists.filter { matches($0.name) }.map { ["title": $0.name, "musicbrainz_id": $0.id, "in_library": true] },
                          "albums": albums.map { ["title": $0.title, "musicbrainz_id": $0.id, "artist": $0.artist.name,
                                                  "year": null($0.year), "in_library": true] }])

        // Accueil et Discover
        case ("GET", "home", "", "", ""):
            return (200, ["sections": [
                shelf("recently_played", "Écoutés récemment", "albums", Demo.albums.map(homeAlbum)),
                shelf("your_top_albums", "Tes albums préférés", "albums", Demo.albums.reversed().map(homeAlbum)),
                shelf("favorite_artists", "Tes artistes", "artists", Demo.artists.map(homeArtist)),
            ]])
        case ("GET", "discover", "", "", ""):
            return (200, ["sections": [shelf("rediscover", "À redécouvrir", "albums", Demo.albums.map(homeAlbum))],
                          "generated_at": Date.now.timeIntervalSince1970])
        case ("GET", "home", _, _, _):
            return (200, ["label": "", "items": Demo.albums.map(homeAlbum), "has_more": false])

        // Artistes (ceux de la démo seulement)
        case ("GET", "artists", let id, let what, ""):
            guard let artist = Demo.artists.first(where: { $0.id == id }) else { return (404, nil) }
            let albums = Demo.albums.filter { $0.artist.id == id }
            let releases = albums.map { ["id": $0.id, "title": $0.title, "type": "Album", "year": null($0.year), "in_library": true] }
            switch what {
            case "":
                return (200, ["name": artist.name, "musicbrainz_id": artist.id, "type": "Person", "country": artist.country,
                              "images": ["thumb_url": Demo.photo(artist), "fanart_url": Demo.photo(artist)],
                              "tags": artist.tags, "followed": false, "albums": releases])
            case "extended": return (200, ["description": artist.bio])
            case "releases": return (200, ["albums": releases, "eps": [], "singles": []])
            case "top-albums": return (200, ["albums": albums.map { ["title": $0.title, "listen_count": 1000] }])
            case "top-songs":
                return (200, ["songs": albums.flatMap { album in album.tracks.map { track in
                    ["title": track.title, "artist_name": artist.name, "release_group_mbid": album.id, "release_name": album.title,
                     "listen_count": 1000] as [String: Any]
                } }])
            case "similar":
                return (200, ["similar_artists": Demo.artists.filter { $0.id != id }.map {
                    ["musicbrainz_id": $0.id, "name": $0.name, "image_url": Demo.photo($0)]
                }])
            default: return (404, nil)
            }
        case ("PUT", "artists", _, "follow", ""):
            return (200, ["followed": body["followed"] as? Bool ?? false])
        case ("GET", "albums", let id, let what, ""):
            guard let album = Demo.albums.first(where: { $0.id == id }) else { return (404, nil) }
            if what == "basic" { return (200, ["release_date": null(album.year.map(String.init)), "type": "Album", "artist_id": album.artist.id]) }
            return (200, ["tracks": album.tracks.enumerated().map { ["position": $0.offset + 1, "title": $0.element.title, "disc_number": 1,
                                                                     "length": Int($0.element.seconds * 1000)] },
                          "selected_release_mbid": NSNull()])

        // Playlists
        case ("GET", "playlists", "", "", ""):
            return (200, ["playlists": playlists.withLock { $0.map(summary) }])
        case ("POST", "playlists", "", "", ""):
            let created = Playlist(id: "p-\(UUID().uuidString)", name: body["name"] as? String ?? "Playlist", entries: [])
            playlists.withLock { $0.append(created) }
            return (200, detail(created))
        case (_, "playlists", let id, _, _):
            return playlist(method, id, part(2), part(3), body)

        // Lecture
        case (_, "now-playing", _, _, _), (_, "scrobble", _, _, _):
            return (204, nil)

        default:
            // Demandes, suivis, concerts… : vides en démo. La forme commune convient à toutes ces listes.
            if method == "GET" {
                return (200, ["items": [], "total": 0, "count": 0, "artists": [], "playlists": [], "connections": [],
                              "configured": false, "sections": []])
            }
            return (403, ["detail": "Indisponible en mode démo."])
        }
    }

    private static func playlist(_ method: String, _ id: String, _ what: String, _ entry: String, _ body: [String: Any]) -> (Int, Any?) {
        playlists.withLock { lists in
            guard let index = lists.firstIndex(where: { $0.id == id }) else { return (404, nil) }
            switch (method, what, entry) {
            case ("GET", "", ""): break
            case ("PUT", "", ""): lists[index].name = body["name"] as? String ?? lists[index].name
            case ("DELETE", "", ""): lists.remove(at: index); return (204, nil)
            case ("POST", "tracks", ""):
                let added = (body["tracks"] as? [[String: Any]] ?? []).compactMap { $0["track_source_id"] as? String }
                lists[index].entries += added.map { ("e-\(UUID().uuidString)", $0) }
            case ("DELETE", "tracks", let removed): lists[index].entries.removeAll { $0.entry == removed }
            case ("PATCH", "tracks", "reorder"):
                if let from = lists[index].entries.firstIndex(where: { $0.entry == body["track_id"] as? String }),
                   let to = body["new_position"] as? Int {
                    let moved = lists[index].entries.remove(at: from)
                    lists[index].entries.insert(moved, at: min(max(to, 0), lists[index].entries.count))
                }
            default: return (404, nil)
            }
            return (200, detail(lists[index]))
        }
    }

    // MARK: Formes de l'API v3

    /// JSONSerialization refuse les optionnels : nil devient `null`.
    private static func null(_ value: (some Any)?) -> Any { value.map { $0 as Any } ?? NSNull() }

    private static func page(_ items: [Any]) -> [String: Any] { ["items": items, "total": items.count, "next": NSNull()] }

    private static func album(_ album: Demo.Album) -> [String: Any] {
        ["id": album.id, "title": album.title, "artist_name": album.artist.name, "artist_mbid": album.artist.id, "year": null(album.year),
         "track_count": album.tracks.count, "format": "mp3", "cover_available": true, "total_size_bytes": album.tracks.count * 3_000_000,
         "date_added": Date.now.timeIntervalSince1970 - album.added * 86_400]
    }

    private static func track(_ album: Demo.Album, _ index: Int) -> [String: Any] {
        ["id": Demo.trackID(album, index), "title": album.tracks[index].title, "track_number": index + 1, "disc_number": 1,
         "duration_seconds": album.tracks[index].seconds, "format": "mp3"]
    }

    private static func crate(_ album: Demo.Album, _ index: Int, reason: String) -> [String: Any] {
        ["track_id": Demo.trackID(album, index), "title": album.tracks[index].title, "album_title": album.title,
         "artist_name": album.artist.name, "album_id": album.id, "cover_available": true,
         "duration_seconds": album.tracks[index].seconds, "format": "mp3", "reason": reason]
    }

    private static func libraryTrack(_ album: Demo.Album, _ index: Int) -> [String: Any] {
        ["id": Demo.trackID(album, index), "title": album.tracks[index].title, "album_id": album.id, "album_title": album.title,
         "artist_name": album.artist.name, "artist_mbid": album.artist.id, "duration_seconds": album.tracks[index].seconds,
         "format": "mp3", "cover_available": true]
    }

    private static func homeAlbum(_ album: Demo.Album) -> [String: Any] {
        ["title": album.title, "musicbrainz_id": album.id, "local_id": album.id, "artist_name": album.artist.name,
         "artist_id": album.artist.id, "image_url": Demo.artwork(album), "in_library": true]
    }

    private static func homeArtist(_ artist: Demo.Artist) -> [String: Any] {
        ["name": artist.name, "musicbrainz_id": artist.id, "image_url": Demo.photo(artist), "in_library": true]
    }

    private static func shelf(_ key: String, _ title: String, _ type: String, _ items: [[String: Any]]) -> [String: Any] {
        ["key": key, "content": ["shape": "shelf", "shelf": ["title": title, "type": type, "items": items]]]
    }

    private static func summary(_ list: Playlist) -> [String: Any] {
        let covers = list.entries.compactMap { Demo.track($0.track).map { Demo.artwork($0.album) } }
        return ["id": list.id, "name": list.name, "track_count": list.entries.count, "cover_urls": Array(Set(covers)).sorted(),
                "is_owner": true, "owner_name": "Démo"]
    }

    private static func detail(_ list: Playlist) -> [String: Any] {
        let entries: [[String: Any]] = list.entries.compactMap { entry in
            guard let (album, index) = Demo.track(entry.track) else { return nil }
            return ["id": entry.entry, "track_name": album.tracks[index].title, "artist_name": album.artist.name,
                    "album_name": album.title, "album_id": album.id, "artist_id": album.artist.id, "track_source_id": entry.track,
                    "cover_url": Demo.artwork(album), "source_type": "local", "duration": album.tracks[index].seconds,
                    "format": "mp3", "library_file_id": entry.track]
        }
        return ["id": list.id, "name": list.name, "tracks": entries, "is_owner": true, "owner_name": "Démo", "is_public": false,
                "total_duration": entries.compactMap { $0["duration"] as? Double }.reduce(0, +)]
    }
}
