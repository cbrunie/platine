import SwiftUI

/// Les contrôles de la discothèque, pour les admins (`/library/management` et
/// `/library/review` du web), rangés comme l'app Réglages : ce qui tourne en
/// direct en haut, puis une page par sujet.
struct LibraryControlsView: View {
    @Environment(\.client) private var client
    @State private var activity: JSON?
    @State private var reviews = 0
    @State private var ready = 0

    var body: some View {
        List {
            Section {
                let work = (activity?["work_items"]?.array ?? []).filter { $0["synthetic"]?.bool != true }
                if work.isEmpty {
                    Label("Tout est calme", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                ForEach(work.indices, id: \.self) { index in
                    let item = work[index]
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(ActivityPane.title(item)).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(ActivityPane.state(item["state"]?.string)).font(.caption).foregroundStyle(.secondary)
                        }
                        if let total = item["total"]?.number, total > 0, item["indeterminate"]?.bool != true {
                            ProgressView(value: min(item["processed"]?.number ?? 0, total), total: total).tint(.sage)
                        } else {
                            ProgressView().progressViewStyle(.linear).tint(.sage)
                        }
                        if let phase = item["phase"]?.string {
                            Text(ActivityPane.phase(phase)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("En direct")
            }
            .settingsRow()

            Section("Discothèque") {
                link("Analyse et identification", "magnifyingglass", .blue) { ActivityPane().paneStyle("Analyse") }
                link("Revue des albums", "checklist", .orange, badge: reviews) { ReviewPane().paneStyle("Revue") }
                link("Doublons d'artistes", "person.2.fill", .purple) { ArtistDeskView() }
            }
            .settingsRow()

            Section {
                link("Ranger les fichiers", "wand.and.stars", .sage.mix(with: .green, by: 0.3), badge: ready) {
                    OrganizePane().paneStyle("Ranger")
                }
                link("Automatisation", "gearshape.2.fill", .gray) { AutomationPane().paneStyle("Automatisation") }
                link("Historique des opérations", "clock.arrow.circlepath", .indigo) { HistoryPane().paneStyle("Historique") }
            } header: {
                Text("Fichiers")
            } footer: {
                Text("Rien n'est écrit dans tes fichiers sans un aperçu que tu appliques.")
            }
            .settingsRow()
        }
        .settingsStyle()
        .navigationTitle("Admin")
        .task {
            while !Task.isCancelled {
                async let activity = try? client.json("GET", "/library/activity")
                async let reviews = try? client.json("GET", "/library/reviews?state=pending&limit=1")
                async let operations = try? client.json("GET", "/library/management/operations?limit=20")
                self.activity = await activity ?? self.activity
                self.reviews = await reviews?["total"]?.int ?? self.reviews
                self.ready = (await operations?["items"]?.array ?? []).filter {
                    $0["operation"]?["state"]?.string == "ready" && $0["activation_preview"]?.bool != true
                }.count
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func link(_ title: String, _ symbol: String, _ color: Color, badge: Int = 0,
                      @ViewBuilder destination: @escaping () -> some View) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                IconTile(symbol: symbol, color: color)
                Text(title)
                Spacer()
                if badge > 0 {
                    Text(String(badge)).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.sage, in: .capsule).foregroundStyle(Color.base100)
                }
            }
        }
    }
}

extension View {
    /// Une page des contrôles : fond, titre en ligne.
    func paneStyle(_ title: String) -> some View {
        settingsStyle()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: Activité

struct ActivityPane: View {
    @Environment(\.client) private var client
    @State private var activity: JSON?
    @State private var current: JSON?
    @State private var runs: [JSON] = []
    @State private var settings: JSON?
    @State private var stopping: String?
    @State private var alert: ServerAlert?

    var body: some View {
        List {
            Section("En cours") {
                let work = (activity?["work_items"]?.array ?? []).filter { $0["synthetic"]?.bool != true }
                if work.isEmpty {
                    Text("Rien ne tourne en ce moment.").foregroundStyle(.secondary)
                }
                ForEach(work.indices, id: \.self) { index in workRow(work[index]) }
            }
            .settingsRow()

            if let run = current?["active"], run != .null {
                Section("Analyse") { scanCard(run) }.settingsRow()
            }

            if let identification = (activity?["items"]?.array ?? []).first(where: { $0["kind"]?.string == "identification" }) {
                Section("Identification") { identificationCard(identification) }.settingsRow()
            }

            Section {
                Button("Analyser les changements", systemImage: "magnifyingglass") { scan("incremental") }
                Button("Réanalyser tous les fichiers", systemImage: "arrow.clockwise") { scan("rescan_files") }
            }
            .settingsRow()
            .disabled(settings?["policy_revision"]?.string == nil || settings?["enabled"]?.bool == false)

            Section("Analyses récentes") {
                ForEach(runs.indices, id: \.self) { index in
                    NavigationLink { RunDetailView(run: runs[index]) } label: { runRow(runs[index]) }
                }
            }
            .settingsRow()
        }
        .confirmationDialog("Arrêter cette analyse ?", isPresented: .constant(stopping != nil), titleVisibility: .visible) {
            Button("Arrêter l'analyse", role: .destructive) { control("stop") }
            Button("Continuer l'analyse", role: .cancel) { stopping = nil }
        } message: {
            Text("Les fichiers déjà indexés restent disponibles. Le travail inachevé est abandonné ; la prochaine analyse compare à nouveau la discothèque.")
        }
        .serverAlert($alert)
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func workRow(_ item: JSON) -> some View {
        let processed = item["processed"]?.number ?? 0
        let total = item["total"]?.number
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.title(item)).font(.headline)
                Spacer()
                Text(Self.state(item["state"]?.string)).font(.caption).foregroundStyle(.secondary)
            }
            if let phase = item["phase"]?.string { Text(Self.phase(phase)).font(.subheadline).foregroundStyle(.secondary) }
            if let total, total > 0, item["indeterminate"]?.bool != true {
                ProgressView(value: min(processed, total), total: total).tint(.sage)
                Text("\(Int(processed)) sur \(Int(total))").font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(Self.effect(item["effect"]?.string)).font(.caption)
                .foregroundStyle(item["effect"]?.string == "file_writing" ? Color.yellow : .secondary)
        }
    }

    @ViewBuilder
    private func scanCard(_ run: JSON) -> some View {
        let state = run["state"]?.string ?? ""
        let counters = run["counters"]
        VStack(alignment: .leading, spacing: 10) {
            Text(Self.scanState(state)).font(.headline)
            StatGrid(items: [("Nouveaux", counters?["new_count"]?.int ?? 0), ("Modifiés", counters?["changed_count"]?.int ?? 0),
                             ("Inchangés", counters?["unchanged_count"]?.int ?? 0), ("Exclus", counters?["excluded_count"]?.int ?? 0),
                             ("Manquants", counters?["missing_count"]?.int ?? 0), ("Erreurs", counters?["errored_count"]?.int ?? 0)])
        }
        if state == "paused" {
            Button("Reprendre l'analyse", systemImage: "play.fill") { control("resume", run) }
        } else {
            Button("Mettre en pause", systemImage: "pause.fill") { control("pause", run) }
                .disabled(state == "pausing" || state == "stopping")
        }
        Button("Arrêter l'analyse…", systemImage: "stop.fill", role: .destructive) { stopping = run["id"]?.string }
    }

    @ViewBuilder
    private func identificationCard(_ item: JSON) -> some View {
        let state = item["state"]?.string ?? ""
        StatGrid(items: [("Identifiés", item["identified_count"]?.int ?? 0), ("En attente", item["waiting_count"]?.int ?? 0),
                         ("En local", item["kept_local_count"]?.int ?? 0), ("À décider", item["needs_review_count"]?.int ?? 0),
                         ("Échecs", item["failed_count"]?.int ?? 0), ("Reportés", item["deferred_count"]?.int ?? 0)])
        if item["provider_unavailable"]?.bool == true {
            Label("MusicBrainz est indisponible pour l'instant ; l'identification reprendra seule.", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(.yellow)
        }
        if let revision = item["control_revision"], revision != .null {
            if state == "paused" {
                Button("Reprendre l'identification", systemImage: "play.fill") { identification("resume", revision) }
            } else if (item["waiting_count"]?.int ?? 0) > 0 {
                Button(state == "pausing" ? "Mise en pause…" : "Mettre en pause", systemImage: "pause.fill") {
                    identification("pause", revision)
                }
                .disabled(state == "pausing")
            }
        }
    }

    private func runRow(_ run: JSON) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(Self.scanState(run["state"]?.string ?? "")).font(.subheadline)
                Spacer()
                Text(Self.date(run["started_at"]?.number ?? run["queued_at"]?.number)).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(Self.kind(run["kind"]?.string)) · \(run["counters"]?["changed_count"]?.int ?? 0) modifiés · \(run["counters"]?["errored_count"]?.int ?? 0) erreurs")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private func load() async {
        async let activity = try? client.json("GET", "/library/activity")
        async let current = try? client.json("GET", "/library/scan/runs/current")
        async let runs = try? client.json("GET", "/library/scan/runs/history?limit=20")
        self.activity = await activity ?? self.activity
        self.current = await current ?? self.current
        self.runs = await runs?["items"]?.array ?? self.runs
        if settings == nil { settings = try? await client.json("GET", "/settings/library") }
    }

    private func scan(_ kind: String) {
        Task {
            do {
                let result = try await client.json("POST", "/library/scan/runs", body: .object([
                    "kind": .string(kind), "scope_ids": .array([]), "expected_policy_revision": settings?["policy_revision"] ?? .string(""),
                ]))
                alert = ServerAlert(title: "Analyse", message: [
                    "started": "L'analyse a démarré.", "queued": "L'analyse attend son tour.",
                    "coalesced": "Une analyse identique tourne déjà.", "expanded": "L'analyse en cours a été élargie.",
                    "conflict": "Une autre opération bloque l'analyse.",
                ][result["disposition"]?.string ?? ""] ?? "Demandée.")
                await load()
            } catch {
                alert = ServerAlert(title: "Analyse impossible", message: error.localizedDescription)
                settings = try? await client.json("GET", "/settings/library")
            }
        }
    }

    private func control(_ action: String, _ run: JSON? = nil) {
        let run = run ?? current?["active"]
        stopping = nil
        guard let id = run?["id"]?.string else { return }
        Task {
            do {
                _ = try await client.json("POST", "/library/scan/runs/\(id)/\(action)",
                                          body: .object(["expected_revision": run?["row_revision"] ?? .null]))
                await load()
            } catch {
                alert = ServerAlert(title: "Analyse", message: error.localizedDescription)
            }
        }
    }

    private func identification(_ action: String, _ revision: JSON) {
        Task {
            do {
                _ = try await client.json("POST", "/library/identification/\(action)", body: .object(["expected_revision": revision]))
                await load()
            } catch {
                alert = ServerAlert(title: "Identification", message: error.localizedDescription)
            }
        }
    }

    // MARK: Libellés

    static func title(_ item: JSON) -> String {
        [
            "scan": "Analyse de la discothèque", "identification": "Identification des albums modifiés",
            "identity_preparation": "Préparation des identités MusicBrainz", "reidentification": "Nouvelle identification",
            "identity_review": "Revue d'identité", "maintenance": "Maintenance",
            "library_management": "Étiquetage et rangement des fichiers", "recovery": "Restauration de l'état d'origine",
        ][item["kind"]?.string ?? ""] ?? (item["kind"]?.string?.capitalized ?? "Tâche")
    }

    static func phase(_ phase: String) -> String {
        [
            "discovering": "Comptage des fichiers locaux", "indexing": "Lecture des métadonnées",
            "reconciling": "Finalisation du catalogue", "identifying_albums": "Rapprochement des albums avec MusicBrainz",
            "planning": "Inspection des fichiers", "ready": "Prêt à vérifier", "applying": "Application des changements prévus",
            "undoing": "Retour à l'état précédent", "restoring": "Restauration de l'état d'origine",
            "preparing_snapshots": "Préparation des instantanés", "writing_staged_files": "Écriture des fichiers préparés",
            "validating_staged_files": "Vérification des fichiers préparés", "publishing_files": "Publication des fichiers vérifiés",
            "committing_catalog": "Mise à jour du catalogue", "cleaning_up": "Nettoyage",
            "checking_identities": "Vérification des identités exactes", "recovery": "La restauration demande un admin",
        ][phase] ?? phase.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func state(_ state: String?) -> String {
        ["queued": "En file", "running": "En cours", "pausing": "Mise en pause…", "paused": "En pause",
         "stopping": "Arrêt…", "failed": "Échec"][state ?? ""] ?? (state?.capitalized ?? "")
    }

    static func effect(_ effect: String?) -> String {
        switch effect {
        case "file_writing": "Écrit dans les fichiers musicaux"
        case "attention": "Demande ton attention"
        default: "Les fichiers ne sont pas modifiés"
        }
    }

    static func scanState(_ state: String) -> String {
        [
            "queued": "En file", "discovering": "Comptage des fichiers", "indexing": "Indexation des fichiers",
            "reconciling": "Rapprochement de la discothèque", "pausing": "Mise en pause après le fichier en cours…",
            "paused": "En pause", "stopping": "Arrêt après le fichier en cours…", "completed": "Terminée",
            "cancelled": "Arrêtée", "superseded_policy_changed": "Arrêtée : la politique a changé", "failed": "Échec",
        ][state] ?? state.capitalized
    }

    static func kind(_ kind: String?) -> String {
        ["incremental": "Changements", "rescan_files": "Réanalyse complète", "policy_reconcile": "Politique appliquée"][kind ?? ""] ?? ""
    }

    static func date(_ seconds: Double?) -> String {
        guard let seconds else { return "" }
        return Date(timeIntervalSince1970: seconds).formatted(.relative(presentation: .named))
    }
}

/// Une analyse passée : ses compteurs, ses durées et les fichiers en échec.
private struct RunDetailView: View {
    let run: JSON

    @Environment(\.client) private var client
    @State private var failures: [JSON] = []

    var body: some View {
        List {
            Section {
                LabeledContent("État", value: ActivityPane.scanState(run["state"]?.string ?? ""))
                LabeledContent("Type", value: ActivityPane.kind(run["kind"]?.string))
                LabeledContent("Déclenchée", value: run["trigger"]?.string?.capitalized ?? "")
                LabeledContent("Début", value: ActivityPane.date(run["started_at"]?.number))
                if let reason = run["terminal_code"]?.string { LabeledContent("Fin", value: reason.replacingOccurrences(of: "_", with: " ").capitalized) }
            }
            .settingsRow()
            JSONRows(title: "Compteurs", value: run["counters"] ?? .object([:]))
            if let timings = run["phase_timings"], timings != .null { JSONRows(title: "Durées par phase (s)", value: timings) }
            if !failures.isEmpty {
                Section("Fichiers en échec") {
                    ForEach(failures.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(failures[index]["relative_path"]?.string ?? "").font(.callout.monospaced()).lineLimit(2)
                            Text(failures[index]["failure_detail"]?.string ?? failures[index]["failure_code"]?.string ?? "")
                                .font(.caption).foregroundStyle(.yellow)
                        }
                    }
                }
                .settingsRow()
            }
        }
        .settingsStyle()
        .navigationTitle("Analyse")
        .task {
            guard let id = run["id"]?.string,
                  run["state"]?.string == "failed" || (run["counters"]?["errored_count"]?.int ?? 0) > 0 else { return }
            failures = (try? await client.json("GET", "/library/scan/runs/\(id)/failures?limit=50"))?["items"]?.array ?? []
        }
    }
}

// MARK: Revue

/// Les albums qui attendent une décision : l'identification n'a pas su
/// trancher seule, ou une édition est à confirmer.
struct ReviewPane: View {
    @Environment(\.client) private var client
    @State private var state = "pending"
    @State private var search = ""
    @State private var page: JSON?
    @State private var bulkPreview: (action: String, preview: JSON)?
    @State private var retryPreview: JSON?
    @State private var bulkError: String?

    private static let states = [("pending", "À décider"), ("rejected", "Étiquettes gardées"), ("excluded", "Exclus"),
                                 ("resolved", "Résolus"), ("all", "Tous")]

    var body: some View {
        List {
            // Les filtres reposent sur le dégradé, sans carte, comme les rayons de l'Accueil.
            FilterChips(options: Self.states.map { ($0.0, $0.1) }, selection: $state).bareRow()
            SearchField(prompt: "Chercher un album ou un artiste", text: $search) { Task { await load() } }.bareRow()
            HStack {
                if let total = page?["total"]?.int {
                    Text("^[\(total) album](inflect: true)").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if state == "pending", (page?["total"]?.int ?? 0) > 0 {
                    Menu {
                        Button("Garder mes étiquettes", systemImage: "tag") { bulk("keep_tagged") }
                        Button("Prendre la meilleure édition", systemImage: "checkmark.seal") { bulk("accept") }
                        Button("Chercher à nouveau", systemImage: "arrow.clockwise") { retryAll() }
                        Button("Retirer de la discothèque", systemImage: "eye.slash", role: .destructive) { bulk("exclude") }
                    } label: {
                        Label("Tout traiter", systemImage: "ellipsis.circle").font(.subheadline)
                    }
                    .buttonStyle(.glass)
                }
            }
            .bareRow()

            Section {
                let items = page?["items"]?.array ?? []
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    NavigationLink { ReviewDetailView(id: item["id"]?.string ?? "") } label: {
                        HStack(spacing: 12) {
                            Cover(path: ReviewDetailView.cover(item), size: 48, radius: 6)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item["album_title"]?.string ?? "").oneLine()
                                Text(item["artist_name"]?.string ?? "").font(.subheadline).foregroundStyle(.secondary).oneLine()
                                Text(item["reason"]?["message"]?.string ?? ReviewDetailView.reason(item["reason_code"]?.string))
                                    .font(.caption).foregroundStyle(.yellow).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            if item["state"]?.string != "pending" {
                                Text(ReviewDetailView.stateName(item["state"]?.string)).font(.caption).foregroundStyle(.secondary)
                            } else if let count = item["candidates"]?.array?.count, count > 0 {
                                Pill(text: "\(count) candidat\(count > 1 ? "s" : "")", color: .sky)
                            }
                        }
                    }
                }
                if items.isEmpty, page != nil {
                    Text("Aucun album dans cette file.").foregroundStyle(.secondary)
                }
            }
            .settingsRow()
        }
        .task(id: state) { await load() }
        .refreshable { await load() }
        .confirmationDialog("Appliquer à \(bulkPreview?.preview["eligible"]?.int ?? 0) album(s) ?",
                            isPresented: .constant(bulkPreview != nil), titleVisibility: .visible) {
            Button("Appliquer") { applyBulk() }
            Button("Annuler", role: .cancel) { bulkPreview = nil }
        } message: {
            let preview = bulkPreview?.preview
            let skipped = (preview?["skipped"]?.array ?? []).reduce(0) { $0 + ($1["count"]?.int ?? 0) }
            Text("\(preview?["eligible"]?.int ?? 0) concernés sur \(preview?["matched"]?.int ?? 0), \(skipped) laissés de côté. Rien n'a encore changé.")
        }
        .confirmationDialog("Relancer l'identification de \(retryPreview?["started"]?.int ?? 0) album(s) ?",
                            isPresented: .constant(retryPreview != nil), titleVisibility: .visible) {
            Button("Relancer") { retryAll(confirmed: true) }
            Button("Annuler", role: .cancel) { retryPreview = nil }
        } message: {
            Text("Les fichiers sont revérifiés en arrière-plan. La lecture reste disponible.")
        }
        .alert("Action groupée", isPresented: .constant(bulkError != nil)) { Button("OK") { bulkError = nil } } message: { Text(bulkError ?? "") }
    }

    /// Le filtre de la file, tel que le serveur l'attend dans une action groupée.
    private var filter: JSON {
        var filter: [String: JSON] = ["state": .string(state)]
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { filter["search"] = .string(query) }
        return .object(filter)
    }

    private func bulkBody(_ action: String, token: JSON = .null) -> JSON {
        .object(["action": .string(action), "review_ids": .array([]), "filter": filter,
                 "candidate_key": .null, "preview_token": token])
    }

    /// Une action groupée : l'aperçu dit combien d'albums seront touchés, puis on applique.
    private func bulk(_ action: String) {
        Task {
            do {
                bulkPreview = (action, try await client.json("POST", "/library/reviews/bulk-preview", body: bulkBody(action)))
            } catch {
                bulkError = error.localizedDescription
            }
        }
    }

    private func applyBulk() {
        guard let (action, preview) = bulkPreview else { return }
        bulkPreview = nil
        Task {
            do {
                _ = try await client.json("POST", "/library/reviews/bulk-apply",
                                          body: bulkBody(action, token: preview["preview_token"] ?? .null))
                await load()
            } catch {
                bulkError = error.localizedDescription
            }
        }
    }

    /// Relancer l'identification de toute la file : un aperçu d'abord, puis la tâche de fond.
    private func retryAll(confirmed: Bool = false) {
        retryPreview = nil
        Task {
            do {
                let result = try await client.json("POST", "/library/reviews/retry-pending", body: .object([
                    "confirm_local_metadata": .bool(false), "filter": filter, "scope_ids": .array([]), "preview": .bool(!confirmed),
                ]))
                if confirmed { await load() } else { retryPreview = result }
            } catch {
                bulkError = error.localizedDescription
            }
        }
    }

    private func load() async {
        var path = "/library/reviews?limit=100&sort=newest&state=\(state)"
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty, let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { path += "&search=\(encoded)" }
        page = try? await client.json("GET", path)
    }
}

/// Un album à revoir : les éditions candidates et leurs preuves par plage, et
/// les décisions possibles, avec les confirmations du web.
struct ReviewDetailView: View {
    let id: String

    @Environment(\.client) private var client
    @Environment(Session.self) private var session
    @State private var review: JSON?
    @State private var confirm: (action: String, title: String, message: String)?
    @State private var alert: ServerAlert?

    var body: some View {
        List {
            if let review {
                let state = review["state"]?.string ?? ""
                Section {
                    HStack(spacing: 14) {
                        Cover(path: Self.cover(review), size: 72, radius: 8)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(review["album_title"]?.string ?? "").font(.headline)
                            Text(review["artist_name"]?.string ?? "").foregroundStyle(.secondary)
                            Text(Self.stateName(state)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Label(review["reason"]?["message"]?.string ?? Self.reason(review["reason_code"]?.string),
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    if let hint = review["reason"]?["action"]?.string, !hint.isEmpty {
                        Text(hint).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .settingsRow()

                let candidates = review["candidates"]?.array ?? []
                if !candidates.isEmpty {
                    Section("Éditions candidates") {
                        ForEach(candidates.indices, id: \.self) { index in
                            candidateRow(candidates[index], selected: review["selected_candidate_key"], pending: state == "pending")
                        }
                    }
                    .settingsRow()
                } else if state == "pending" {
                    Section {
                        Text("Aucune édition candidate. Cherche à nouveau, ou choisis une édition depuis la page de l'album.")
                            .foregroundStyle(.secondary)
                    }
                    .settingsRow()
                }

                Section("Décision") {
                    if state == "pending" {
                        Button("Garder mes étiquettes", systemImage: "tag") { act("keep-tagged") }
                        Button("Retirer la correspondance…", systemImage: "link.badge.minus") {
                            confirm = ("detach", "Retirer la correspondance MusicBrainz ?",
                                       "L'album garde ses propres étiquettes. On peut défaire depuis la page de l'album.")
                        }
                        Button("Décider plus tard", systemImage: "clock") { act("dismiss") }
                        if session.isAdmin {
                            if review["manual_identity"]?.bool != true {
                                Button("Chercher à nouveau", systemImage: "arrow.clockwise") { retry() }
                            }
                            Button("Retirer de la discothèque…", systemImage: "eye.slash", role: .destructive) {
                                confirm = ("exclude", "Retirer cet album de la discothèque ?",
                                           "Il sera masqué de DroppedNeedle et des applis connectées. Les fichiers restent sur le disque et la décision est réversible.")
                            }
                        }
                    } else if state == "excluded", session.isAdmin {
                        Button("Remettre dans la discothèque", systemImage: "arrow.uturn.backward") { act("restore") }
                    } else {
                        Button("Rouvrir", systemImage: "arrow.uturn.backward") { act("reopen") }
                    }
                }
                .settingsRow()
            } else {
                ProgressView().listRowBackground(Color.clear)
            }
        }
        .settingsStyle()
        .navigationTitle("Revue")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(confirm?.title ?? "", isPresented: .constant(confirm != nil), titleVisibility: .visible) {
            Button("Confirmer", role: confirm?.action == "exclude" ? .destructive : nil) {
                if let action = confirm?.action { act(action) }
                confirm = nil
            }
            Button("Annuler", role: .cancel) { confirm = nil }
        } message: {
            Text(confirm?.message ?? "")
        }
        .serverAlert($alert)
        .task { await load() }
    }

    private func candidateRow(_ candidate: JSON, selected: JSON?, pending: Bool) -> some View {
        let fit = candidate["supported_tracks"]?.int ?? 0
        let total = candidate["track_evidence"]?.array?.count ?? 0
        let contradictions = candidate["contradictory_tracks"]?.int ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Cover(path: DroppedNeedle.cover(nil, album: candidate["release_group_mbid"]?.string), size: 52, radius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate["album_title"]?.string ?? "").oneLine()
                    Text([candidate["album_artist_name"]?.string, total > 0 ? "\(fit) plages sur \(total) concordent" : nil,
                          contradictions > 0 ? "\(contradictions) ne collent pas" : nil]
                        .compactMap(\.self).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    Text("Score \(candidate["score"]?.number ?? 0, format: .number.precision(.fractionLength(2)))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if candidate["candidate_key"] == selected, selected != nil, selected != .null {
                    Pill(text: "Choisie", color: .sage)
                }
            }
            if pending {
                Button("Prendre cette édition") { choose(candidate) }.buttonStyle(.bordered)
            }
        }
    }

    private var revision: JSON { review?["row_revision"] ?? .null }

    private func act(_ action: String) {
        send("/library/reviews/\(id)/\(action)", ["expected_revision": revision])
    }

    private func retry() {
        send("/library/reviews/\(id)/retry", ["expected_revision": revision, "confirm_local_metadata": .bool(false),
                                              "idempotency_key": .string(UUID().uuidString.lowercased())])
    }

    private func choose(_ candidate: JSON) {
        send("/library/reviews/\(id)/approve", ["expected_revision": revision, "candidate_key": candidate["candidate_key"] ?? .null])
    }

    private func send(_ path: String, _ body: [String: JSON]) {
        Task {
            do {
                _ = try await client.json("POST", path, body: .object(body))
                alert = ServerAlert(title: "Décision enregistrée", message: "")
            } catch {
                alert = ServerAlert(title: "Décision refusée", message: error.localizedDescription)
            }
            await load()
        }
    }

    private func load() async { review = try? await client.json("GET", "/library/reviews/\(id)") }

    /// La pochette de la meilleure candidate : la revue ne porte plus d'identité à elle.
    static func cover(_ review: JSON) -> String? {
        let candidates = review["candidates"]?.array ?? []
        let selected = candidates.first { $0["candidate_key"] == review["selected_candidate_key"] }
        return DroppedNeedle.cover(nil, album: (selected ?? candidates.first)?["release_group_mbid"]?.string)
    }

    static func stateName(_ state: String?) -> String {
        ["pending": "À décider", "approved": "Résolu", "dismissed": "Pour plus tard", "rejected": "Étiquettes gardées",
         "excluded": "Exclu"][state ?? ""] ?? (state ?? "")
    }

    static func reason(_ code: String?) -> String {
        let code = code?.uppercased()
        return [
            "NO_CANDIDATE": "Aucun résultat externe", "AMBIGUOUS": "Plusieurs sorties aussi probables",
            "CONTRADICTORY": "Les plages se contredisent", "EDITION_UNCERTAIN": "Édition à confirmer",
            "MAX_DEFERRALS_EXCEEDED": "Limite d'essais atteinte", "SUBJECT_NOT_AVAILABLE": "Album plus disponible",
            "RELEASE_TYPE_REQUIRES_CONFIRMATION": "Compilation ou live à confirmer", "UNSAFE_RELEASE_TYPE": "Compilation ou live à confirmer",
            "NO_EXTERNAL_RESULT": "Aucun résultat externe", "INVALID_EMBEDDED_IDS": "Identifiants intégrés invalides",
            "CONFLICTING_TRACK_EVIDENCE": "Les plages se contredisent", "MULTIPLE_LIKELY_RELEASES": "Plusieurs sorties probables",
            "INCOMPLETE_SUPPORT": "Preuves incomplètes", "UNKNOWN_EXTRAS": "Plages en trop inconnues",
        ][code ?? ""] ?? (code.map { $0.replacingOccurrences(of: "_", with: " ").lowercased().capitalized(with: nil) } ?? "")
    }
}

// MARK: Historique des opérations

struct HistoryPane: View {
    @Environment(\.client) private var client
    @State private var operations: [JSON] = []

    var body: some View {
        List {
            ForEach(operations.indices, id: \.self) { index in
                let item = operations[index]
                let operation = item["operation"]
                NavigationLink { OperationDetailView(id: operation?["id"]?.string ?? "") } label: {
                    // La pastille d'état centrée sur les deux lignes, pas collée à la première.
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item["profile_name"]?.string ?? Self.mode(item["mode"]?.string)).oneLine()
                            Text("\(Self.mode(item["mode"]?.string)) · \(item["origin"]?.string?.replacingOccurrences(of: "_", with: " ") ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Pill(text: ActivityPane.state(operation?["state"]?.string), color: Self.color(operation?["state"]?.string))
                    }
                }
                .settingsRow()
            }
            if operations.isEmpty { Text("Aucune opération pour l'instant.").foregroundStyle(.secondary).settingsRow() }
        }
        .task { operations = (try? await client.json("GET", "/library/management/operations?limit=50"))?["items"]?.array ?? [] }
        .refreshable { operations = (try? await client.json("GET", "/library/management/operations?limit=50"))?["items"]?.array ?? [] }
    }

    static func mode(_ mode: String?) -> String {
        ["preview": "Aperçu", "apply": "Application", "automatic_apply": "Application automatique", "undo": "Annulation",
         "baseline_restore": "Retour à l'origine", "duplicate_resolution": "Doublons"][mode ?? ""] ?? (mode?.capitalized ?? "")
    }

    static func color(_ state: String?) -> Color {
        switch state {
        case "succeeded": .sage
        case "failed", "cancelled", "stopped": .red
        case "ready": .sky
        default: .yellow
        }
    }
}

/// Une opération : sa progression, ses compteurs, et pause, reprise ou arrêt.
struct OperationDetailView: View {
    let id: String

    @Environment(\.client) private var client
    @State private var detail: JSON?
    @State private var stopping = false
    @State private var undo: String?
    @State private var alert: ServerAlert?

    var body: some View {
        List {
            if let detail {
                let operation = detail["operation"] ?? detail
                let state = operation["state"]?.string ?? ""
                Section {
                    LabeledContent("État", value: ActivityPane.state(state))
                    LabeledContent("Mode", value: HistoryPane.mode(detail["mode"]?.string))
                    if let profile = detail["profile_name"]?.string { LabeledContent("Profil", value: profile) }
                    if let expected = operation["expected_work_count"]?.number, expected > 0 {
                        ProgressView(value: operation["completed_count"]?.number ?? 0, total: expected).tint(.sage)
                    }
                }
                .settingsRow()
                Section {
                    LabeledContent("Réussis", value: operation["succeeded_count"]?.display ?? "0")
                    LabeledContent("Échecs", value: operation["failed_count"]?.display ?? "0")
                    LabeledContent("Ignorés", value: operation["skipped_count"]?.display ?? "0")
                }
                .settingsRow()
                if ["succeeded", "stopped"].contains(state), (detail["undo_available_count"]?.int ?? 0) > 0 {
                    Section {
                        Button("Préparer une annulation…", systemImage: "arrow.uturn.backward") { undoPreview() }
                    } footer: {
                        Text("Un aperçu d'annulation est créé ; rien ne change avant de l'appliquer.")
                    }
                    .settingsRow()
                }
                if ["queued", "running", "paused"].contains(state) {
                    Section {
                        if state == "paused" {
                            Button("Reprendre", systemImage: "play.fill") { control("resume", operation) }
                        } else {
                            Button("Pause", systemImage: "pause.fill") { control("pause", operation) }
                        }
                        Button("Arrêter…", systemImage: "stop.fill", role: .destructive) { stopping = true }
                    }
                    .settingsRow()
                }
            } else {
                ProgressView().listRowBackground(Color.clear)
            }
        }
        .settingsStyle()
        .navigationTitle("Opération")
        .navigationDestination(item: Binding(get: { undo.map { IdentifiedJSON(value: .string($0)) } },
                                             set: { undo = $0?.value.string })) { PreviewView(id: $0.value.string ?? "") }
        .confirmationDialog("Arrêter au prochain point sûr ?", isPresented: $stopping, titleVisibility: .visible) {
            Button("Arrêter l'opération", role: .destructive) { control("stop", detail?["operation"] ?? detail) }
            Button("Continuer", role: .cancel) {}
        } message: {
            Text("Les changements déjà faits sont gardés, pas annulés.")
        }
        .serverAlert($alert)
        .task {
            while !Task.isCancelled {
                detail = try? await client.json("GET", "/library/management/operations/\(id)")
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func undoPreview() {
        Task {
            do {
                let created = try await client.json("POST", "/library/management/operations/\(id)/undo-preview", body: .object([
                    "expected_operation_row_revision": detail?["operation_row_revision"] ?? .null,
                    "idempotency_key": .string(UUID().uuidString.lowercased()),
                ]))
                if let job = created["job_id"]?.string {
                    PreviewTokens.tokens[job] = created["preview_token"]?.string
                    undo = job
                }
            } catch {
                alert = ServerAlert(title: "Annulation impossible", message: error.localizedDescription)
            }
        }
    }

    private func control(_ action: String, _ operation: JSON?) {
        Task {
            do {
                _ = try await client.json("POST", "/library/operations/\(id)/\(action)",
                                          body: .object(["expected_row_revision": operation?["row_revision"] ?? detail?["operation_row_revision"] ?? .null]))
            } catch {
                alert = ServerAlert(title: "Opération", message: error.localizedDescription)
            }
        }
    }
}
