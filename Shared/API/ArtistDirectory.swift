import Foundation
import Observation

/// Retrouve la page d'un artiste à partir de son nom. Les réponses de la discothèque locale
/// (albums, pistes du bac, recherche) ne donnent pas d'identifiant d'artiste : sans cet annuaire,
/// ni le nom sur la page d'un album ni « Aller à l'artiste » ne mènent nulle part.
@Observable
final class ArtistDirectory {
    static let shared = ArtistDirectory()

    private var refs: [String: ArtistRef] = [:]

    /// La page d'un artiste : son identifiant s'il est déjà connu, sinon son nom, sinon celui de
    /// l'artiste principal (« Linkin Park feat. Jonathan Davis » mène à Linkin Park).
    func ref(id: String? = nil, named name: String) -> ArtistRef? {
        if let id { return ArtistRef(id: id, name: Self.main(of: name)) }
        return refs[Self.key(name)] ?? refs[Self.key(Self.main(of: name))]
    }

    /// Les artistes de la discothèque. Ceux qu'elle n'a pas pu relier à MusicBrainz sont cherchés
    /// par leur nom exact : « Ye » ne doit pas devenir « Glutamato Ye-Ye ».
    func load(_ client: DroppedNeedle) async {
        var artists: [LibraryArtist] = []
        // Deux listes distinctes : ceux qui ont un album, et ceux qui sont seulement invités.
        for scope in ["album_artists", "contributors"] {
            var cursor: String?
            repeat {
                guard let page = try? await client.libraryArtists(after: cursor, scope: scope) else { break }
                artists += page.items
                cursor = page.next
            } while cursor != nil
        }
        var found: [String: ArtistRef] = [:]
        for artist in artists {
            if let id = artist.musicbrainzArtistId {
                found[Self.key(artist.name)] = ArtistRef(id: id, name: artist.name)
            }
        }
        refs = found
        for artist in artists where artist.musicbrainzArtistId == nil {
            let results = (try? await client.search(artist.name))?.artists ?? []
            if let match = results.first(where: { Self.key($0.title) == Self.key(artist.name) }) {
                refs[Self.key(artist.name)] = ArtistRef(id: match.musicbrainzId, name: artist.name)
            }
        }
    }

    /// Le nom sans casse, accents ni ponctuation : « alt‐J » et « alt-J » sont le même artiste.
    static func key(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }

    /// L'artiste principal d'un crédit, sans ses invités.
    static func main(of credit: String) -> String {
        let cut = credit.range(of: #"\s+(feat\.?|ft\.?|featuring)\s+"#, options: [.regularExpression, .caseInsensitive])
        return cut.map { String(credit[..<$0.lowerBound]) } ?? credit
    }
}
