import Foundation

/// Les sorties d'un artiste rangées comme sur Musique : une seule version de chaque disque
/// (pas dix rééditions de « Discovery »). Pas de rayon live : le serveur n'envoie que le
/// studio (réglage « Types de sorties ») et ne dit pas quels disques sont live.
struct Discography: Sendable {
    var albums: [Release] = []
    var eps: [Release] = []
    var singles: [Release] = []

    init() {}

    init(_ releases: ArtistReleases) {
        albums = Self.unique(releases.albums)
        eps = Self.unique(releases.eps)
        singles = Self.unique(releases.singles)
    }

    /// Une version par titre : celle qu'on a, sinon la plus ancienne (l'originale). Les plus
    /// récentes d'abord, comme sur Musique.
    static func unique(_ releases: [Release]) -> [Release] {
        var kept: [String: Release] = [:]
        for release in releases where release.id != nil {
            let key = titleKey(release.title ?? "")
            guard let current = kept[key] else { kept[key] = release; continue }
            if better(release, than: current) { kept[key] = release }
        }
        return kept.values.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    }

    private static func better(_ a: Release, than b: Release) -> Bool {
        if (a.inLibrary == true) != (b.inLibrary == true) { return a.inLibrary == true }
        return (a.year ?? .max) < (b.year ?? .max)
    }

    /// Mots qui signalent une autre version du même disque ou de la même plage.
    private static let versionWords = ["remaster", "deluxe", "edition", "édition", "version", "expanded",
                                       "anniversary", "mono", "stereo", "bonus", "reissue", "explicit",
                                       "clean", "edit", "single", "mix"]

    /// Le titre sans ce qui distingue les versions : « Discovery (Beta Version) », « Discovery
    /// - 2011 Remaster » et « Discovery » donnent tous « discovery ».
    static func titleKey(_ title: String) -> String {
        var text = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        // Les parenthèses et crochets qui parlent de version.
        let bracketed = /\s*[\(\[]([^\)\]]*)[\)\]]/
        text = text.replacing(bracketed) { match in
            let inside = String(match.output.1)
            return versionWords.contains { inside.contains($0) } ? "" : " " + inside
        }
        // « Titre - 2011 Remaster », « Titre - Radio Edit ».
        if let dash = text.range(of: " - ", options: .backwards),
           versionWords.contains(where: { text[dash.upperBound...].contains($0) }) {
            text = String(text[..<dash.lowerBound])
        }
        let kept = text.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
}

#if DEBUG
/// ponytail: la vérification du rangement, lancée avec `-platineSelfTest YES` (builds de debug).
enum DiscographyCheck {
    static func run() {
        assert(Discography.titleKey("Discovery (Beta Version)") == "discovery")
        assert(Discography.titleKey("Discovery - 2011 Remaster") == "discovery")
        assert(Discography.titleKey("Abbey Road (Super Deluxe Edition)") == "abbey road")
        assert(Discography.titleKey("One More Time (Radio Edit)") == "one more time")
        assert(Discography.titleKey("Harder, Better, Faster, Stronger") == "harder better faster stronger")
        assert(Discography.titleKey("Revolution 909 (Live)") == "revolution 909 live")
        let releases = ArtistReleases(
            albums: [Release(id: "a", title: "Discovery (Beta Version)", type: "Album", year: 2001, inLibrary: false),
                     Release(id: "b", title: "Discovery", type: "Album", year: 2001, inLibrary: true),
                     Release(id: "c", title: "Alive 2007", type: "Album", year: 2007, inLibrary: false)],
            eps: [], singles: [])
        let sorted = Discography(releases)
        assert(sorted.albums.map(\.id) == ["c", "b"])
    }
}
#endif
