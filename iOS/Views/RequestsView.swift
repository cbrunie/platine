import SwiftUI

/// Les demandes : en cours, terminées, et celles que DroppedNeedle relance seul.
/// Les trois listes se chargent ensemble ; changer d'onglet ne recharge rien,
/// pour ne pas faire clignoter l'écran.
struct RequestsView: View {
    @Environment(\.client) private var client
    @State private var tab = RequestTab.active
    @State private var active: [ActiveRequest]?
    @State private var history: [PastRequest]?
    @State private var wanted: [WantedItem]?
    @State private var error: String?

    private enum RequestTab: String, CaseIterable {
        case active = "En cours"
        case history = "Historique"
        case wanted = "Wanted"
    }

    var body: some View {
        List {
            FilterChips(options: RequestTab.allCases.map { ($0.rawValue, $0.rawValue) },
                        selection: Binding(get: { tab.rawValue }, set: { tab = RequestTab(rawValue: $0) ?? .active }))
                .bareRow()

            switch tab {
            case .active:
                ForEach(running) { item in
                    AlbumRow(cover: item.cover, title: item.title, subtitle: item.artist,
                             detail: item.error ?? RequestStatus.label(item.status)) {
                        // La barre tourne sans pourcentage quand le client n'en donne pas.
                        if let progress = item.progress {
                            VStack(alignment: .trailing, spacing: 3) {
                                ProgressView(value: min(progress, 100), total: 100).tint(.sage)
                                Text("\(Int(progress)) %").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .frame(width: 70)
                        } else if RequestStatus.isTransferring(item.status) {
                            ProgressView().progressViewStyle(.linear).tint(.sage).frame(width: 70)
                        }
                    }
                }
            case .history:
                ForEach(finished) { item in
                    AlbumRow(cover: item.cover, title: item.trackTitle ?? item.albumTitle, subtitle: item.artistName,
                             detail: RequestStatus.label(item.status)) {
                        if item.inLibrary == true { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.sage) }
                    }
                }
            case .wanted:
                ForEach(wanted ?? []) { item in
                    AlbumRow(cover: item.coverUrl, title: item.albumTitle, subtitle: item.artistName,
                             detail: "\(item.state) · \(item.checkCount) recherches" + (item.lastOutcome.map { " · \($0)" } ?? "")) {
                        EmptyView()
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay { placeholder }
        .pageBackground()
        .navigationTitle("Demandes")
        .task {
            // Tenir la progression à jour tant que la page est ouverte.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .refreshable { await load() }
    }

    @ViewBuilder
    private var placeholder: some View {
        if let error, active == nil {
            ContentUnavailableView("Impossible de charger", systemImage: "wifi.exclamationmark", description: Text(error))
        } else {
            switch tab {
            case .active:
                if active == nil || history == nil { SkeletonList() } else if running.isEmpty {
                    ContentUnavailableView("Aucune demande en cours", systemImage: "tray")
                }
            case .history:
                if history == nil { SkeletonList() } else if finished.isEmpty {
                    ContentUnavailableView("Aucune demande", systemImage: "tray")
                }
            case .wanted:
                if wanted == nil { SkeletonList() } else if wanted?.isEmpty == true {
                    ContentUnavailableView("Rien en attente", systemImage: "binoculars")
                }
            }
        }
    }

    /// Ce qui est en cours : la liste du serveur, plus ce qu'elle omet pour un admin (file d'attente,
    /// import, pause) et qu'on retrouve dans l'historique.
    private var running: [RunningRequest] {
        let listed = active ?? []
        let ids = Set(listed.map(\.musicbrainzId))
        return listed.map(RunningRequest.init)
            + (history ?? []).filter { !ids.contains($0.musicbrainzId) && !RequestStatus.allowsNewRequest($0.status) }
                .map(RunningRequest.init)
    }

    /// L'historique, sans ce qui est encore en cours et déjà affiché dans l'autre onglet.
    private var finished: [PastRequest] {
        (history ?? []).filter { RequestStatus.allowsNewRequest($0.status) }
    }

    private func load() async {
        async let active = try? client.activeRequests().items
        // 100 : l'historique sert aussi à retrouver ce qui n'est plus listé en cours.
        async let history = try? client.requestHistory(pageSize: 100).items
        async let wanted = try? client.wanted().items
        self.active = await active ?? self.active ?? []
        self.history = await history ?? self.history ?? []
        self.wanted = await wanted ?? self.wanted ?? []
    }
}

/// Une ligne de l'onglet « En cours », qu'elle vienne de la liste ou de l'historique.
private struct RunningRequest: Identifiable {
    let id: String
    let cover: String?
    let title: String
    let artist: String
    let status: String
    let progress: Double?
    let error: String?

    init(_ request: ActiveRequest) {
        id = request.musicbrainzId
        cover = request.coverUrl
        title = request.trackTitle ?? request.albumTitle
        artist = request.artistName
        status = request.status
        progress = request.progress
        error = request.errorMessage
    }

    init(_ request: PastRequest) {
        id = request.musicbrainzId
        cover = request.cover
        title = request.trackTitle ?? request.albumTitle
        artist = request.artistName
        status = request.status
        progress = nil
        error = nil
    }
}

/// Les statuts d'une demande, partagés par la page d'album et Demandes.
enum RequestStatus {
    /// Les plages seules encore en route, par enregistrement.
    static func tracks(active: [ActiveRequest], past: [PastRequest]) -> [String: String] {
        let held = past.filter { $0.requestKind == "track" && !allowsNewRequest($0.status) }
        return Dictionary(active.filter { $0.requestKind == "track" }.map { ($0.musicbrainzId, $0.status) }
                          + held.map { ($0.musicbrainzId, $0.status) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// Les états finaux, sans fichiers à attendre : on peut redemander.
    static func allowsNewRequest(_ status: String) -> Bool {
        ["failed", "cancelled", "rejected", "importFailed", "importBlocked", "incomplete", "imported"].contains(status)
    }

    /// Des fichiers bougent : la barre de progression a du sens.
    static func isTransferring(_ status: String?) -> Bool {
        status == "downloading" || status == "importing"
    }

    static func label(_ status: String?) -> String {
        switch status {
        case "pending", nil: "Demande envoyée"
        case "queued": "En file d'attente"
        case "awaiting_approval": "En attente de validation"
        case "downloading": "Téléchargement en cours"
        case "importing": "Import dans ta discothèque"
        case "paused": "En pause"
        case "downloadClientUnavailable": "Client de téléchargement indisponible"
        case "imported": "Dans tes bacs"
        case "incomplete": "Incomplet"
        case "importFailed": "Échec de l'import"
        case "importBlocked": "Import bloqué"
        case "failed": "Échec"
        case "cancelled": "Annulée"
        case "rejected": "Refusée"
        default: status?.capitalized ?? ""
        }
    }
}
