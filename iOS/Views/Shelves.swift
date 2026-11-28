import SwiftUI

extension View {
    /// Les pages qu'on peut ouvrir de partout : un album, un artiste, un mix.
    /// `ownHeader` : une page principale qui dessine son en-tête (`PageTitle`) et règle sa barre elle-même.
    func platineDestinations(ownHeader: Bool = false) -> some View {
        Group { if ownHeader { self } else { compactTitle() } }
            .navigationDestination(for: LocalAlbum.self) { AlbumView(album: $0) }
            .navigationDestination(for: ArtistRef.self) { ArtistView(artist: $0) }
            .navigationDestination(for: Route.self) { $0.page.compactTitle(pushed: true) }
    }

    /// Le grand titre à gauche, sur la même ligne que les boutons de la barre : pas une ligne de
    /// boutons puis une ligne de titre. Une page qui choisit son propre mode (un en-tête) le garde.
    /// `pushed` : une page ouverte depuis une autre. iOS ne pose pas de grand titre à côté du bouton
    /// retour : son titre va au centre de la ligne des boutons.
    @ViewBuilder func compactTitle(pushed: Bool = false) -> some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        toolbarTitleDisplayMode(pushed ? .inline : .inlineLarge)
        #else
        self
        #endif
    }
}

extension View {
    /// Une pulsation douce pour dire « ça arrive ». Sans effet quand `active` est faux.
    func pulsing(_ active: Bool = true) -> some View { modifier(Pulsing(active: active)) }
}

extension View {
    /// Une page dont l'image passe sous la barre : sur Mac, ni bandeau ni nom de l'app dans le titre.
    func heroBar(title: String) -> some View {
        #if targetEnvironment(macCatalyst)
        navigationTitle(title)
            .toolbar(removing: .title)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .scrollEdgeEffectHidden(true, for: .top)
        #else
        self
        #endif
    }
}

private struct Pulsing: ViewModifier {
    let active: Bool
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(active && dim ? 0.45 : 1)
            .onChange(of: active, initial: true) { _, active in
                guard active, !reduceMotion else { return dim = false }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// Une ligne de texte qui n'est pas encore arrivée.
struct SkeletonLine: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    /// Sur un fond teinté, comme la page d'un album, un blanc transparent prend sa couleur.
    var color = Color.base300

    var body: some View {
        Capsule().fill(color).frame(width: width, height: height).pulsing()
    }
}

/// La fiche d'un artiste, d'un album ou d'une playlist : une ligne par fait, libellé à gauche.
struct FactsTable: View {
    let facts: [(label: String, value: String)]
    /// Sur un fond teinté, comme la page d'un album, un blanc transparent prend sa couleur.
    var background = Color.base200

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                if index > 0 { Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5) }
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(fact.label).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(fact.value).multilineTextAlignment(.trailing)
                }
                .font(.subheadline)
                .padding(.vertical, 10)
            }
        }
        .padding(.horizontal, 14)
        .background(background, in: .rect(cornerRadius: 14))
    }

    /// Les faits connus, dans l'ordre, sans les vides.
    static func known(_ facts: [(String, String?)]) -> [(label: String, value: String)] {
        facts.compactMap { label, value in value.flatMap { $0.isEmpty ? nil : (label, $0) } }
    }
}

/// Le bas d'une page comme dans Musique : date, nombre de plages, durée, en petit.
struct PageFooter: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines, id: \.self) { Text($0) }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

enum Credits {
    /// « Sum 41, Blink-182, Green Day et 4 autres » : les plus présents d'abord.
    static func artists(_ names: [String], shown: Int = 3) -> String? {
        let counts = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
        let ranked = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
        guard !ranked.isEmpty else { return nil }
        let rest = ranked.count - shown
        return ranked.prefix(shown).joined(separator: ", ") + (rest > 0 ? " et \(rest) autre\(rest > 1 ? "s" : "")" : "")
    }
}

enum Dates {
    /// « 2001-06-13 » ou « 2026-11-03T12:38:46+00:00 » : la date seule, à la française.
    static func day(_ text: String?) -> String? {
        guard let text, let date = try? Date(String(text.prefix(10)), strategy: .iso8601.year().month().day()) else {
            return text.map { String($0.prefix(4)) }
        }
        return date.formatted(.dateTime.day().month(.wide).year())
    }

    /// Une date en secondes depuis 1970, comme la v3 les donne.
    static func day(seconds: Double?) -> String? {
        seconds.map { Date(timeIntervalSince1970: $0).formatted(.dateTime.day().month(.wide).year()) }
    }

    /// « 51 minutes », « 1 heure 4 minutes ».
    static func length(seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }

    /// « 11 plages, 51 minutes ».
    static func summary(tracks: Int, seconds: Double?) -> String {
        let count = tracks == 1 ? "1 plage" : "\(tracks) plages"
        guard let seconds, seconds > 0 else { return count }
        return count + ", " + length(seconds: seconds)
    }
}

/// Des lignes en cours de chargement, à poser dans une liste à la place des vraies.
struct SkeletonRows: View {
    var count = 10
    /// Le côté de la vignette ; sans, les numéros d'un album.
    var side: CGFloat? = 44
    var round = false
    var color = Color.base300

    private static let widths: [CGFloat] = [180, 140, 200, 120, 160, 190, 130, 170]

    var body: some View {
        ForEach(0 ..< count, id: \.self) { index in
            HStack(spacing: 12) {
                if let side {
                    RoundedRectangle(cornerRadius: round ? side / 2 : 6).fill(color)
                        .frame(width: side, height: side).pulsing()
                } else {
                    Text(String(index + 1)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(minWidth: 24)
                }
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonLine(width: Self.widths[index % Self.widths.count], color: color)
                    if side != nil { SkeletonLine(width: 100, height: 10, color: color) }
                }
                Spacer(minLength: 0)
            }
            .macRowSpacing()
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        .accessibilityHidden(true)
    }
}

/// Une page de lignes en cours de chargement, à la place d'une liste qui n'existe pas encore.
struct SkeletonList: View {
    var body: some View {
        List { SkeletonRows() }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .allowsHitTesting(false)
    }
}

/// Une grille de disques en cours de chargement.
struct SkeletonGrid: View {
    var count = 12

    var body: some View {
        ForEach(0 ..< count, id: \.self) { _ in
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 8).fill(Color.base300).aspectRatio(1, contentMode: .fit).pulsing()
                SkeletonLine(width: 110)
                SkeletonLine(width: 70, height: 10)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Un rayon en cours de chargement : son titre, et des pochettes vides à la bonne taille.
struct SkeletonShelf: View {
    let title: String
    var count = 6
    var side: CGFloat = 150
    var round = false

    var body: some View {
        Shelf(title) {
            ForEach(0 ..< count, id: \.self) { _ in
                VStack(alignment: round ? .center : .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: round ? side / 2 : 6)
                        .fill(Color.base300)
                        .frame(width: side, height: side)
                        .pulsing()
                    SkeletonLine(width: side * 0.75)
                    if !round { SkeletonLine(width: side * 0.45, height: 10) }
                }
            }
        }
        .scrollDisabled(true)
        .accessibilityLabel("\(title), chargement")
    }
}

/// Les morceaux phares en cours de chargement.
struct SkeletonTrackList: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.display(20, relativeTo: .title3))
            ForEach(0 ..< 5, id: \.self) { index in
                HStack(spacing: 12) {
                    Text(String(index + 1)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20)
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonLine(width: [190, 150, 170, 130, 160][index])
                        SkeletonLine(width: 100, height: 10)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(.horizontal)
        .accessibilityLabel("\(title), chargement")
    }
}

/// La page à ouvrir depuis le lecteur : il se referme et l'accueil la pose sur sa pile.
/// ponytail: toujours sur l'onglet Accueil ; viser l'onglet en cours demanderait un chemin par onglet.
@Observable
final class PlayerNavigation {
    static let shared = PlayerNavigation()

    var target: Route?
}

extension Track {
    /// La page de son album, si on sait laquelle.
    var albumRoute: Route? {
        guard let albumID else { return nil }
        let album = LocalAlbum(musicbrainzId: albumID, name: self.album, artistName: artist,
                               artistMbid: artistRef?.id, year: nil, trackCount: nil,
                               primaryFormat: nil, coverUrl: cover)
        return Route("album-\(albumID)") { AlbumView(album: album) }
    }

    /// La page de son artiste, si on la retrouve.
    var artistRoute: Route? {
        artistRef.map { artist in Route("artist-\(artist.id)") { ArtistView(artist: artist) } }
    }

    private var artistRef: ArtistRef? { ArtistDirectory.shared.ref(id: artistID, named: artist) }
}

/// Une page ouverte par valeur, comme les albums. Les liens qui portent leur page en dur
/// (`NavigationLink { … }`) se mélangent mal avec ceux à valeur : ouvrir un album depuis un
/// mix ouvert ainsi réempilait le mix par-dessus l'album.
struct Route: Hashable {
    let id: String
    let page: AnyView

    init(_ id: String, @ViewBuilder page: () -> some View) {
        self.id = id
        self.page = AnyView(page())
    }

    static func == (a: Route, b: Route) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Un rayon : un titre, un « Tout voir » facultatif, et des pochettes qui défilent. Le rayon de
/// Coulisse, celui de Projecteur.
struct Shelf<Content: View, More: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @ViewBuilder var more: More

    var body: some View {
        Rail(title, content: { content }, accessory: { more })
    }
}

extension Shelf where More == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, content: content) { EmptyView() }
    }
}

/// Un artiste en médaillon rond, comme « Trending Artists » sur le web.
struct ArtistBubble: View {
    let name: String
    let image: String?
    var size: CGFloat = 120

    var body: some View {
        VStack(spacing: 8) {
            Cover(path: image, size: size, radius: size / 2)
            Text(name).font(.subheadline.weight(.medium)).oneLine()
        }
        .frame(width: size)
        .foregroundStyle(.primary)
    }
}

/// La date d'un concert en petite page de calendrier, comme dans Musique.
struct DateTile: View {
    let date: Date?

    var body: some View {
        VStack(spacing: 0) {
            Text(date?.formatted(.dateTime.month(.abbreviated)) ?? "—")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.sage)
                .textCase(.lowercase)
            Text(date?.formatted(.dateTime.day()) ?? "?")
                .font(.display(26, relativeTo: .title))
        }
        .frame(width: 56, height: 56)
        .background(Color.base300, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
    }
}

/// Un concert : la date, la ville, la salle et l'heure ; un tap ouvre la billetterie.
struct ConcertRow: View {
    let concert: Concert
    var showsArtist = true

    var body: some View {
        let date = Self.day.date(from: concert.localDate)
        let cancelled = concert.status == "cancelled"
        let row = HStack(spacing: 14) {
            DateTile(date: date)
            VStack(alignment: .leading, spacing: 3) {
                Text(showsArtist ? concert.artistName : concert.city ?? concert.eventName)
                    .font(.headline).oneLine()
                    .strikethrough(cancelled)
                Text([showsArtist ? concert.city : nil, concert.venueName,
                      date?.formatted(.dateTime.weekday(.abbreviated)), time]
                    .compactMap(\.self).joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary).oneLine()
            }
            Spacer(minLength: 0)
            if cancelled {
                Pill(text: "Annulé", color: .red)
            } else if concert.status == "rescheduled" {
                Pill(text: "Reporté", color: .yellow)
            }
        }
        .contentShape(.rect)

        if let link = concert.ticketUrl.flatMap(URL.init(string:)) {
            Link(destination: link) { row }.buttonStyle(.plain)
        } else {
            row
        }
    }

    private var time: String? {
        guard let startsAt = concert.startsAt, let date = try? Date(startsAt, strategy: .iso8601) else { return nil }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
