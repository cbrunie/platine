import SwiftUI

/// Les jetons d'aperçu : secrets, indispensables pour appliquer, gardés en
/// mémoire le temps de la session comme le web les garde en sessionStorage.
@MainActor
enum PreviewTokens {
    static var tokens: [String: String] = [:]
}

/// La phrase à taper pour toute écriture de fichiers, comme sur le web.
let confirmationPhrase = "CONFIRM"

// MARK: Rangement

/// Le rangement des fichiers : ce qui tourne, les aperçus prêts, la création
/// d'un aperçu, la restauration, la préparation et la vérification des identités.
struct OrganizePane: View {
    @Environment(\.client) private var client
    @State private var operations: [JSON] = []
    @State private var recovery: JSON?
    @State private var management: JSON?
    @State private var library: JSON?
    @State private var readiness: JSON?
    @State private var preparations: [JSON] = []
    @State private var repairs: [JSON] = []
    @State private var runner: OrganizeRunner.Mode?
    @State private var discarding: JSON?
    @State private var confirm: (title: String, message: String, action: () -> Void)?
    @State private var alert: ServerAlert?

    var body: some View {
        List {
            if let recovery, (recovery["needs_attention_count"]?.int ?? 0) + (recovery["cleanup_pending_count"]?.int ?? 0) > 0 {
                Section {
                    Label("La récupération demande ton attention : \(recovery["needs_attention_count"]?.int ?? 0) lot(s) à revoir, \(recovery["cleanup_pending_count"]?.int ?? 0) nettoyage(s) en attente. Aucun fichier incertain n'est supprimé automatiquement.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    ForEach((recovery["needs_attention_bundles"]?.array ?? []).indices, id: \.self) { index in
                        let bundle = recovery["needs_attention_bundles"]?.array?[index]["bundle_id"]?.string ?? ""
                        Button("Marquer \(bundle.prefix(8)) comme traité") { resolve(bundle) }
                    }
                }
                .settingsRow()
            }

            Section {
                Button("Prévisualiser un rangement…", systemImage: "wand.and.stars") { runner = .manage }
                Button("Restaurer l'état d'origine…", systemImage: "clock.arrow.circlepath") { runner = .baseline }
            } footer: {
                Text("Rien n'est écrit tant qu'un aperçu n'est pas appliqué.")
            }
            .settingsRow()
            .disabled(management == nil || library?["policy_revision"]?.string == nil)

            if let active = operations.first(where: { ["queued", "running", "paused"].contains($0["operation"]?["state"]?.string ?? "") }) {
                Section("En cours") { activeRow(active) }.settingsRow()
            }

            let ready = operations.filter { $0["operation"]?["state"]?.string == "ready" && $0["activation_preview"]?.bool != true }
            if !ready.isEmpty {
                Section("Aperçus prêts") {
                    ForEach(ready.indices, id: \.self) { index in
                        let item = ready[index]
                        NavigationLink { PreviewView(id: item["operation"]?["id"]?.string ?? "") } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item["profile_name"]?.string ?? "Aperçu")
                                HStack(spacing: 6) {
                                    Pill(text: "\(item["eligible_count"]?.int ?? 0) prêts")
                                    if let warnings = item["warning_count"]?.int, warnings > 0 { Pill(text: "\(warnings) avertis", color: .yellow) }
                                    if let blocked = item["blocked_count"]?.int, blocked > 0 { Pill(text: "\(blocked) bloqués", color: .red) }
                                }
                            }
                        }
                        .swipeActions { Button("Abandonner", role: .destructive) { discarding = item } }
                    }
                }
                .settingsRow()
            }

            Section {
                if let readiness {
                    StatGrid(items: [("Prêts", readiness["ready_album_count"]?.int ?? 0),
                                     ("À relier", readiness["mapping_required_count"]?.int ?? 0),
                                     ("Édition à choisir", readiness["exact_release_required_count"]?.int ?? 0)])
                }
                if let job = preparations.first { preparationRow(job) }
                Button("Préparer les identités…", systemImage: "checkmark.seal") {
                    confirm = ("Préparer les identités ?",
                               "Cet essai à blanc vérifie les éditions MusicBrainz exactes et la correspondance des plages. Il lit le catalogue et MusicBrainz, sans écrire dans les fichiers.",
                               startPreparation)
                }
                .disabled(preparations.contains { ["queued", "running", "paused"].contains($0["state"]?.string ?? "") })
            } header: {
                Text("Préparation des identités")
            }
            .settingsRow()

            Section {
                ForEach(repairs.prefix(3).indices, id: \.self) { index in repairRow(repairs[index]) }
                Button("Vérifier les identités existantes…", systemImage: "stethoscope") {
                    confirm = ("Vérifier les identités ?",
                               "Les identités des albums sont revérifiées avec les règles les plus récentes. Cette analyse ne modifie ni la discothèque ni les fichiers.",
                               startRepair)
                }
            } header: {
                Text("Vérification des identités")
            }
            .settingsRow()
        }
        .sheet(item: $runner) { mode in
            OrganizeRunner(mode: mode, management: management, library: library)
        }
        .confirmationDialog("Abandonner cet aperçu ?", isPresented: .constant(discarding != nil), titleVisibility: .visible) {
            Button("Abandonner l'aperçu", role: .destructive) { if let discarding { discard(discarding) }; discarding = nil }
            Button("Garder l'aperçu", role: .cancel) { discarding = nil }
        } message: {
            Text("Il ne pourra plus être appliqué. Aucun fichier, étiquette ni opération terminée n'est modifié ; il reste dans l'historique.")
        }
        .confirmationDialog(confirm?.title ?? "", isPresented: .constant(confirm != nil), titleVisibility: .visible) {
            Button("Lancer") { confirm?.action(); confirm = nil }
            Button("Annuler", role: .cancel) { confirm = nil }
        } message: {
            Text(confirm?.message ?? "")
        }
        .serverAlert($alert)
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(2.5))
            }
        }
    }

    /// Trois lignes : l'état, puis la pause et le détail chacun sur la sienne (deux boutons
    /// dans une même ligne de liste n'en font qu'un).
    @ViewBuilder
    private func activeRow(_ item: JSON) -> some View {
        let operation = item["operation"]
        let state = operation?["state"]?.string ?? ""
        VStack(alignment: .leading, spacing: 6) {
            Text(item["activation_preview"]?.bool == true ? "Essai à blanc d'activation" : (item["profile_name"]?.string ?? "Rangement"))
                .font(.headline)
            Text("\(HistoryLabels.mode(item["mode"]?.string)) · " + ((operation?["expected_work_count"]?.int ?? 0) > 0
                ? "\(operation?["completed_count"]?.int ?? 0) sur \(operation?["expected_work_count"]?.int ?? 0)"
                : "en préparation"))
                .font(.caption).foregroundStyle(.secondary)
            if let total = operation?["expected_work_count"]?.number, total > 0 {
                ProgressView(value: operation?["completed_count"]?.number ?? 0, total: total).tint(.sage)
            }
        }
        .padding(.vertical, 2)
        Button(state == "paused" ? "Reprendre" : "Mettre en pause", systemImage: state == "paused" ? "play.fill" : "pause.fill") {
            control(operation, state == "paused" ? "resume" : "pause")
        }
        NavigationLink {
            if item["mode"]?.string == "preview" { PreviewView(id: operation?["id"]?.string ?? "") }
            else { OperationDetailView(id: operation?["id"]?.string ?? "") }
        } label: {
            Label("Détails", systemImage: "doc.text.magnifyingglass")
        }
    }

    private func preparationRow(_ job: JSON) -> some View {
        let state = job["state"]?.string ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Dernière préparation")
                Spacer()
                Pill(text: ActivityLabels.state(state), color: HistoryLabels.color(state))
            }
            Text("\(job["completed_count"]?.int ?? 0) sur \(job["expected_work_count"]?.int ?? 0) sorties vérifiées")
                .font(.caption).foregroundStyle(.secondary)
            if ["queued", "running", "paused"].contains(state) {
                HStack {
                    Button(state == "paused" ? "Reprendre" : "Pause") { control(job, state == "paused" ? "resume" : "pause") }
                    Button("Arrêter", role: .destructive) { control(job, "stop") }.disabled(job["control_request"]?.string != "none")
                }
                } else if state == "ready", job["repair_summary"] != nil {
                NavigationLink("Voir le rapport") { FindingsView(kind: .preparation, job: job) }
            }
        }
    }

    private func repairRow(_ job: JSON) -> some View {
        let state = job["state"]?.string ?? ""
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Revérification")
                Spacer()
                Pill(text: ActivityLabels.state(state), color: HistoryLabels.color(state))
            }
            Text("\(job["completed_count"]?.int ?? 0) sur \(job["expected_work_count"]?.int ?? 0) vérifiées · \(job["failed_count"]?.int ?? 0) échecs")
                .font(.caption).foregroundStyle(.secondary)
            if ["queued", "running", "paused"].contains(state) {
                HStack {
                    Button(state == "paused" ? "Reprendre" : "Pause") { control(job, state == "paused" ? "resume" : "pause") }
                    Button("Arrêter", role: .destructive) { control(job, "stop") }
                }
                } else if job["repair_summary"] != nil {
                NavigationLink("Voir le rapport") { FindingsView(kind: .repair, job: job) }
            }
        }
    }

    // MARK: Actions

    private func load() async {
        async let operations = try? client.json("GET", "/library/management/operations?limit=20")
        async let recovery = try? client.json("GET", "/library/management/recovery/diagnostics")
        async let readiness = try? client.json("GET", "/library/management/identity-preparations/estimate")
        async let preparations = try? client.json("GET", "/library/management/identity-preparations?limit=5")
        async let repairs = try? client.json("GET", "/library/identity-repairs?limit=10")
        self.operations = await operations?["items"]?.array ?? self.operations
        self.recovery = await recovery ?? self.recovery
        self.readiness = await readiness ?? self.readiness
        self.preparations = await preparations?["items"]?.array ?? self.preparations
        self.repairs = await repairs?["items"]?.array ?? self.repairs
        if management == nil { management = try? await client.json("GET", "/settings/library-management") }
        if library == nil { library = try? await client.json("GET", "/settings/library") }
    }

    private func control(_ operation: JSON?, _ action: String) {
        guard let id = operation?["id"]?.string else { return }
        run("/library/operations/\(id)/\(action)", .object(["expected_row_revision": operation?["row_revision"] ?? .null]))
    }

    private func discard(_ item: JSON) {
        guard let id = item["operation"]?["id"]?.string else { return }
        PreviewTokens.tokens[id] = nil
        run("/library/management/previews/\(id)/discard",
            .object(["expected_operation_row_revision": item["operation"]?["row_revision"] ?? .null]))
    }

    private func resolve(_ bundle: String) {
        run("/library/management/recovery/import-bundles/\(bundle)/resolve", nil)
    }

    private func startPreparation() {
        run("/library/management/identity-preparations",
            .object(["idempotency_key": .string(UUID().uuidString.lowercased()), "root_ids": .array([])]))
    }

    private func startRepair() {
        run("/library/identity-repairs", .object([
            "idempotency_key": .string(UUID().uuidString.lowercased()), "root_ids": .array([]),
            "target_matcher_version": .string("quiet-reconfirm-v1"),
        ]))
    }

    private func run(_ path: String, _ body: JSON?) {
        Task {
            do {
                _ = try await client.json("POST", path, body: body)
                await load()
            } catch {
                alert = ServerAlert(title: "Rangement", message: error.localizedDescription)
            }
        }
    }
}

enum ActivityLabels {
    static func state(_ state: String?) -> String {
        ["queued": "En file", "running": "En cours", "pausing": "Mise en pause…", "paused": "En pause", "stopping": "Arrêt…",
         "ready": "Prêt", "succeeded": "Réussi", "failed": "Échec", "cancelled": "Annulé", "stopped": "Arrêté"][state ?? ""]
            ?? (state?.capitalized ?? "")
    }
}

enum HistoryLabels {
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

// MARK: Assistant

/// Créer un aperçu : la portée, le profil, le travail, puis la relecture.
struct OrganizeRunner: View {
    enum Mode: String, Identifiable {
        case manage, baseline
        var id: String { rawValue }
    }

    let mode: Mode
    let management: JSON?
    let library: JSON?

    @Environment(\.client) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var scope = "roots"
    @State private var roots: Set<String> = []
    @State private var search = ""
    @State private var found: [(id: String, title: String, subtitle: String)] = []
    @State private var picked: [(id: String, title: String)] = []
    @State private var profile = ""
    @State private var customize = false
    @State private var work: [String: Bool] = [:]
    @State private var creating = false
    @State private var created: String?
    @State private var alert: ServerAlert?

    private static let workKeys = [("metadata_enabled", "Étiquettes"), ("genres_enabled", "Genres"),
                                   ("embedded_artwork_enabled", "Pochette intégrée"), ("external_artwork_enabled", "Pochette externe"),
                                   ("rename_enabled", "Renommer les fichiers"), ("move_enabled", "Déplacer dans le dossier"),
                                   ("move_sidecars", "Déplacer les fichiers annexes")]

    var body: some View {
        NavigationStack {
            Form {
                Section("Portée") {
                    Picker("Portée", selection: $scope) {
                        Text("Dossiers").tag("roots")
                        Text("Artistes").tag("artists")
                        Text("Sorties").tag("albums")
                        Text("Plages").tag("tracks")
                    }
                    .pickerStyle(.segmented)
                    if scope == "roots" {
                        ForEach((library?["library_roots"]?.array ?? []).indices, id: \.self) { index in
                            let root = library?["library_roots"]?.array?[index]
                            let id = root?["id"]?.string ?? ""
                            Toggle(root?["label"]?.string ?? root?["path"]?.string ?? id, isOn: Binding(
                                get: { roots.contains(id) },
                                set: { if $0 { roots.insert(id) } else { roots.remove(id) } }
                            ))
                        }
                    } else {
                        TextField("Chercher (2 lettres min.)", text: $search).autocorrectionDisabled()
                        ForEach(picked, id: \.id) { item in
                            Label(item.title, systemImage: "checkmark.circle.fill").foregroundStyle(Color.sage)
                                .onTapGesture { picked.removeAll { $0.id == item.id } }
                        }
                        ForEach(found.filter { item in !picked.contains { $0.id == item.id } }, id: \.id) { item in
                            Button { picked.append((item.id, item.title)) } label: {
                                VStack(alignment: .leading) {
                                    Text(item.title).foregroundStyle(.primary)
                                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .settingsRow()

                if mode == .manage {
                    Section {
                        Picker("Profil", selection: $profile) {
                            ForEach((management?["profiles"]?.array ?? []).indices, id: \.self) { index in
                                let item = management?["profiles"]?.array?[index]
                                Text(item?["name"]?.string ?? "").tag(item?["id"]?.string ?? "")
                            }
                        }
                    } header: {
                        Text("Profil")
                    } footer: {
                        Text("Le profil est figé dans l'aperçu : le modifier ensuite rend l'aperçu périmé.")
                    }
                    .settingsRow()

                    Section("Travail") {
                        Toggle("Adapter ce passage", isOn: $customize)
                        if customize {
                            ForEach(Self.workKeys, id: \.0) { key, label in
                                Toggle(label, isOn: Binding(get: { work[key] ?? true }, set: { work[key] = $0 }))
                            }
                        }
                    }
                    .settingsRow()
                } else {
                    Section {
                        Text("La restauration remet les fichiers dans l'état où ils étaient avant que DroppedNeedle ne les gère. C'est différent d'une annulation.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .settingsRow()
                }

                if let created {
                    Section {
                        NavigationLink("Ouvrir l'aperçu") { PreviewView(id: created) }
                    }
                    .settingsRow()
                }
            }
            .settingsStyle()
            .navigationTitle(mode == .manage ? "Prévisualiser un rangement" : "Restaurer l'état d'origine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if creating { ProgressView() } else {
                        Button("Générer l'aperçu") { create() }.disabled(selection == nil || created != nil)
                    }
                }
            }
            .serverAlert($alert)
            .task(id: "\(scope)|\(search)") { await find() }
            .onAppear {
                profile = management?["default_profile_id"]?.string ?? ""
                roots = Set((library?["library_roots"]?.array ?? []).compactMap { $0["id"]?.string })
                seedWork()
            }
            .onChange(of: profile) { seedWork() }
        }
    }

    /// Les cases « travail » partent des valeurs du profil choisi.
    private func seedWork() {
        let chosen = (management?["profiles"]?.array ?? []).first { $0["id"]?.string == profile }
        work = [
            "metadata_enabled": chosen?["metadata"]?["enabled"]?.bool ?? true,
            "genres_enabled": chosen?["genres"]?["enabled"]?.bool ?? true,
            "embedded_artwork_enabled": chosen?["artwork"]?["embedded_enabled"]?.bool ?? true,
            "external_artwork_enabled": chosen?["artwork"]?["external_enabled"]?.bool ?? false,
            "rename_enabled": chosen?["organization"]?["rename_enabled"]?.bool ?? false,
            "move_enabled": chosen?["organization"]?["move_enabled"]?.bool ?? false,
            "move_sidecars": chosen?["organization"]?["move_sidecars"]?.bool ?? false,
        ]
    }

    private var selection: JSON? {
        if scope == "roots" {
            return roots.isEmpty ? nil : .object(["kind": .string("roots"), "ids": .array(roots.sorted().map(JSON.string))])
        }
        return picked.isEmpty ? nil : .object(["kind": .string(scope), "ids": .array(picked.map { .string($0.id) })])
    }

    private func find() async {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard scope != "roots", query.count >= 2,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { found = []; return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        switch scope {
        case "albums":
            let page = try? await client.json("GET", "/library/albums?limit=12&sort=name&q=\(encoded)")
            found = (page?["items"]?.array ?? []).map { ($0["id"]?.string ?? "", $0["title"]?.string ?? "",
                                                           $0["artist_name"]?.string ?? "") }
        case "artists":
            let page = try? await client.json("GET", "/library/artists?limit=12&sort=name&order=asc&scope=album_artists&q=\(encoded)")
            found = (page?["items"]?.array ?? []).map { ($0["id"]?.string ?? "", $0["name"]?.string ?? "",
                                                           "\($0["album_count"]?.int ?? 0) albums") }
        default:
            let page = try? await client.json("GET", "/library/tracks?limit=12&sort=title&q=\(encoded)")
            found = (page?["items"]?.array ?? []).map { ($0["id"]?.string ?? "", $0["title"]?.string ?? "",
                                                           "\($0["artist_name"]?.string ?? "") · \($0["album_title"]?.string ?? "")") }
        }
    }

    private func create() {
        guard let selection else { return }
        creating = true
        Task {
            defer { creating = false }
            do {
                var body: [String: JSON] = [
                    "selection": selection,
                    "expected_settings_revision": management?["settings_revision"] ?? .null,
                    "expected_policy_revision": library?["policy_revision"] ?? .null,
                    "idempotency_key": .string(UUID().uuidString.lowercased()),
                ]
                let path: String
                if mode == .manage {
                    path = "/library/management/previews"
                    body["profile_id"] = .string(profile)
                    if customize {
                        var overrides = work.mapValues(JSON.bool)
                        // v3 n'a plus de nettoyage de la source, d'horodatage gardé ni d'acceptation d'édition par passage.
                        for key in ["naming_script_id", "multi_disc_naming_script_id"] { overrides[key] = .null }
                        overrides["multi_disc_naming_mode"] = .string("inherit")
                        body["overrides"] = .object(overrides)
                    }
                } else {
                    path = "/library/management/baselines/restore-previews"
                }
                let result = try await client.json("POST", path, body: .object(body))
                if let id = result["job_id"]?.string {
                    PreviewTokens.tokens[id] = result["preview_token"]?.string
                    created = id
                }
            } catch {
                alert = ServerAlert(title: "Aperçu impossible", message: error.localizedDescription)
            }
        }
    }
}

// MARK: Aperçu

/// Un aperçu : ce qui sera écrit, fichier par fichier, et le bouton qui
/// l'applique après avoir tapé CONFIRM.
struct PreviewView: View {
    let id: String

    @Environment(\.client) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var detail: JSON?
    @State private var items: [JSON] = []
    @State private var cursor: String?
    @State private var hasMore = true
    @State private var eligibility = "all"
    @State private var applying = false
    @State private var typed = ""
    @State private var discarding = false
    @State private var applied: String?
    @State private var alert: ServerAlert?

    var body: some View {
        List {
            if let detail {
                let summary = detail["summary"]
                Section {
                    Text("Appliquer est la première écriture · aucun fichier n'a changé").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        stat("Prêts à écrire", (summary?["eligible_count"]?.int ?? 0) + (summary?["warning_count"]?.int ?? 0))
                        stat("Bloqués", summary?["blocked_count"]?.int ?? 0)
                        stat("Sans changement", summary?["no_change_count"]?.int ?? 0)
                    }
                    HStack(spacing: 6) {
                        Pill(text: "\(summary?["tag_change_count"]?.int ?? 0) étiquettes", color: .sky)
                        Pill(text: "\(summary?["path_change_count"]?.int ?? 0) chemins", color: .sky)
                        Pill(text: "\(summary?["artwork_change_count"]?.int ?? 0) pochettes", color: .sky)
                    }
                    if detail["stale"]?.bool == true || detail["expired"]?.bool == true {
                        Label("Cet aperçu ne peut plus être appliqué : \(detail["stale_input_count"]?.int ?? 0) fichier(s) ont changé depuis. Génère un nouvel aperçu.",
                              systemImage: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    } else if detail["ready_for_confirmation"]?.bool != true {
                        Label("Préparation en cours, toujours en lecture seule…", systemImage: "hourglass").foregroundStyle(.secondary)
                    }
                    if detail["proposed_settings_revision"] != nil, detail["proposed_settings_revision"] != .null {
                        Label("Essai à blanc d'activation : consultation seulement.", systemImage: "eye").foregroundStyle(.secondary)
                    }
                }
                .settingsRow()

                Section {
                    Picker("Résultat", selection: $eligibility) {
                        Text("Tous").tag("all")
                        Text("Prêts").tag("eligible")
                        Text("Avertis").tag("warning")
                        Text("Bloqués").tag("blocked")
                    }
                    .pickerStyle(.segmented)
                    ForEach(items.indices, id: \.self) { index in
                        NavigationLink { PlanItemView(item: items[index]) } label: { planRow(items[index]) }
                            .onAppear { if index == items.count - 1, hasMore { Task { await loadItems() } } }
                    }
                } header: {
                    Text("Fichiers")
                }
                .settingsRow()
            } else {
                ProgressView().listRowBackground(Color.clear)
            }
        }
        .settingsStyle()
        .navigationTitle(HistoryLabels.mode(detail?["mode"]?.string))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { footer }
        .alert("Taper \(confirmationPhrase) pour appliquer", isPresented: $applying) {
            TextField(confirmationPhrase, text: $typed).textInputAutocapitalization(.characters).autocorrectionDisabled()
            Button("Annuler", role: .cancel) { typed = "" }
            Button(applyTitle, role: .destructive) { apply() }
        } message: {
            Text("DroppedNeedle va écrire les étiquettes et ranger \(eligibleCount) fichier(s). Aucune destination n'est écrasée automatiquement.")
        }
        .confirmationDialog("Abandonner cet aperçu ?", isPresented: $discarding, titleVisibility: .visible) {
            Button("Abandonner l'aperçu", role: .destructive) { discard() }
        }
        .navigationDestination(item: Binding(get: { applied.map { IdentifiedJSON(value: .string($0)) } },
                                             set: { applied = $0?.value.string })) {
            OperationDetailView(id: $0.value.string ?? "")
        }
        .serverAlert($alert)
        .task {
            while !Task.isCancelled {
                detail = try? await client.json("GET", "/library/management/previews/\(id)")
                if items.isEmpty { await loadItems() }
                await ensureToken()
                let state = detail?["state"]?.string ?? ""
                if detail?["ready_for_confirmation"]?.bool == true || detail?["stale"]?.bool == true || detail?["expired"]?.bool == true
                    || ["failed", "cancelled", "discarded", "stopped", "succeeded"].contains(state) { break }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onChange(of: eligibility) {
            items = []
            cursor = nil
            hasMore = true
            Task { await loadItems() }
        }
    }

    private var eligibleCount: Int {
        (detail?["summary"]?["eligible_count"]?.int ?? 0) + (detail?["summary"]?["warning_count"]?.int ?? 0)
    }

    private var applyTitle: String {
        switch detail?["mode"]?.string {
        case "undo": "Annuler l'opération"
        case "baseline_restore": "Restaurer l'état d'origine"
        case "duplicate_resolution": "Appliquer la résolution"
        default: "Appliquer cet aperçu"
        }
    }

    private var canApply: Bool {
        guard let detail else { return false }
        return detail["ready_for_confirmation"]?.bool == true && detail["stale"]?.bool != true && detail["expired"]?.bool != true
            && (detail["proposed_settings_revision"] == nil || detail["proposed_settings_revision"] == .null)
            && eligibleCount > 0 && PreviewTokens.tokens[id] != nil
    }

    private var footer: some View {
        HStack {
            Button("Abandonner", role: .destructive) { discarding = true }
                .disabled(detail?["state"]?.string != "ready")
            Spacer()
            Button { typed = ""; applying = true } label: {
                Text(eligibleCount > 0 ? "\(applyTitle) (\(eligibleCount))" : applyTitle).foregroundStyle(Color.base100)
            }
            .buttonStyle(.glassProminent)
            .disabled(!canApply)
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(value)).font(.display(20, relativeTo: .headline))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func planRow(_ item: JSON) -> some View {
        let eligibility = item["eligibility"]?.string ?? "blocked"
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(item["capability"]?["catalog_track_title"]?.string ?? item["source_relative_path"]?.string?.split(separator: "/").last.map(String.init) ?? "")
                    .lineLimit(1)
                Spacer()
                Pill(text: ["eligible": "Prêt", "warning": "Averti", "blocked": "Bloqué", "stale": "Périmé"][eligibility] ?? eligibility,
                     color: ["eligible": .sage, "warning": .yellow, "blocked": .red][eligibility] ?? .gray)
            }
            if let destination = item["destination_relative_path"]?.string, destination != item["source_relative_path"]?.string {
                Text("→ \(destination)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            }
            if let reason = item["reason"]?["message"]?.string ?? item["reason_code"]?.string?.replacingOccurrences(of: "_", with: " ").lowercased().capitalized(with: nil) {
                Text(reason).font(.caption).foregroundStyle(.yellow)
            }
        }
    }

    private func loadItems() async {
        var path = "/library/management/previews/\(id)/items?limit=50"
        if let cursor, let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { path += "&cursor=\(encoded)" }
        if eligibility != "all" { path += "&eligibility=\(eligibility)" }
        guard let page = try? await client.json("GET", path) else { return }
        items += page["items"]?.array ?? []
        cursor = page["next_cursor"]?.string
        hasMore = cursor != nil
    }

    /// Sans jeton (aperçu ouvert dans une autre session), on en redemande un.
    private func ensureToken() async {
        guard PreviewTokens.tokens[id] == nil, detail?["ready_for_confirmation"]?.bool == true,
              detail?["stale"]?.bool != true, detail?["expired"]?.bool != true else { return }
        if let result = try? await client.json("POST", "/library/management/previews/\(id)/reissue") {
            PreviewTokens.tokens[id] = result["preview_token"]?.string
        }
    }

    private func apply() {
        guard typed == confirmationPhrase, let token = PreviewTokens.tokens[id] else {
            alert = ServerAlert(title: "Rien n'a été écrit", message: "Tape exactement \(confirmationPhrase) pour appliquer.")
            return
        }
        typed = ""
        Task {
            do {
                let operation = try await client.json("POST", "/library/management/previews/\(id)/apply", body: .object([
                    "preview_token": .string(token), "expected_operation_row_revision": detail?["operation_row_revision"] ?? .null,
                    "idempotency_key": .string(UUID().uuidString.lowercased()), "confirmation": .bool(true),
                ]))
                PreviewTokens.tokens[id] = nil
                applied = operation["id"]?.string
            } catch {
                alert = ServerAlert(title: "Application refusée", message: error.localizedDescription)
            }
        }
    }

    private func discard() {
        Task {
            do {
                _ = try await client.json("POST", "/library/management/previews/\(id)/discard",
                                          body: .object(["expected_operation_row_revision": detail?["operation_row_revision"] ?? .null]))
                PreviewTokens.tokens[id] = nil
                dismiss()
            } catch {
                alert = ServerAlert(title: "Impossible d'abandonner", message: error.localizedDescription)
            }
        }
    }
}

/// Le détail d'un fichier de l'aperçu : chemins et champs modifiés.
private struct PlanItemView: View {
    let item: JSON

    var body: some View {
        List {
            Section("Chemin") {
                LabeledContent("Avant", value: item["source_relative_path"]?.string ?? "—")
                LabeledContent("Après", value: item["destination_relative_path"]?.string ?? "—")
            }
            .settingsRow()
            let mutations = item["diff"]?["field_mutations"]?.array ?? []
            if !mutations.isEmpty {
                Section("Étiquettes") {
                    ForEach(mutations.indices, id: \.self) { index in
                        let mutation = mutations[index]
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mutation["name"]?.string ?? "").font(.subheadline.weight(.medium))
                            Text("\(mutation["before"]?.display ?? "—") → \(mutation["after"]?.display ?? "—")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .settingsRow()
            }
            let collisions = item["collisions"]?.array ?? []
            if !collisions.isEmpty {
                Section("Collisions") {
                    ForEach(collisions.indices, id: \.self) { index in
                        Text(collisions[index]["classification"]?.string?.replacingOccurrences(of: "_", with: " ") ?? "")
                    }
                }
                .settingsRow()
            }
        }
        .settingsStyle()
        .navigationTitle("Fichier")
    }
}

// MARK: Rapports d'identité

/// Le rapport d'une préparation ou d'une vérification d'identités, par catégorie,
/// avec l'application ou l'abandon confirmés.
private struct FindingsView: View {
    enum Kind { case preparation, repair }

    let kind: Kind
    let job: JSON

    @Environment(\.client) private var client
    @State private var category: String
    @State private var findings: [JSON] = []
    @State private var refreshRequired = false
    @State private var confirming = false
    @State private var discarding = false
    @State private var alert: ServerAlert?

    init(kind: Kind, job: JSON) {
        self.kind = kind
        self.job = job
        _category = State(initialValue: kind == .preparation ? "mapping_ready" : "safe_detach")
    }

    private var categories: [(String, String)] {
        kind == .preparation
            ? [("mapping_ready", "À relier"), ("ready", "Prêtes"), ("exact_release_required", "Édition"),
               ("exact_release_suggested", "Suggérée"), ("exact_release_auto_accepted", "Auto"), ("needs_review", "À revoir"), ("unverifiable", "Plus tard")]
            : [("valid", "Valides"), ("safe_detach", "À détacher"), ("needs_review", "À revoir"),
               ("unverifiable", "Invérifiables"), ("manual_identity", "Manuelles")]
    }

    private var base: String {
        let id = job["id"]?.string ?? ""
        return kind == .preparation ? "/library/management/identity-preparations/\(id)" : "/library/identity-repairs/\(id)"
    }

    var body: some View {
        List {
            if let summary = job["repair_summary"] {
                Section {
                    LabeledContent("Identités évaluées", value: summary["total_identities"]?.display ?? "0")
                    LabeledContent("Changements prévus", value: summary["estimated_apply_changes"]?.display ?? "0")
                    LabeledContent("Plages qui restent jouables", value: "\(summary["playable_after_detach_track_count"]?.int ?? 0) sur \(summary["input_track_count"]?.int ?? 0)")
                }
                .settingsRow()
            }
            Section {
                Picker("Catégorie", selection: $category) {
                    ForEach(categories, id: \.0) { Text($0.1).tag($0.0) }
                }
                if refreshRequired {
                    Text("Ces vérifications utilisent d'anciennes règles. Lance une nouvelle vérification.").foregroundStyle(.yellow)
                }
                ForEach(findings.indices, id: \.self) { index in
                    let finding = findings[index]
                    VStack(alignment: .leading, spacing: 3) {
                        Text(finding["album_title"]?.string ?? "")
                        Text(finding["album_artist_name"]?.string ?? "").font(.caption).foregroundStyle(.secondary)
                        if let edition = finding["suggested_edition"]?["title"]?.string {
                            Text("Édition proposée : \(edition)").font(.caption).foregroundStyle(Color.sky)
                        }
                        if let undo = finding["automatic_undo"], undo != .null, let album = finding["local_album_id"]?.string {
                            Button("Annuler l'acceptation automatique") {
                                send("/library/albums/\(album)/undo-automatic-edition", undo)
                            }
                            .font(.caption)
                        }
                    }
                }
                if findings.isEmpty { Text("Rien dans cette catégorie.").foregroundStyle(.secondary) }
            }
            .settingsRow()

            if job["state"]?.string == "ready", !refreshRequired {
                Section {
                    Button(kind == .preparation ? "Accepter les identités…" : "Appliquer les réparations sûres…") { confirming = true }
                    if kind == .preparation {
                        Button("Écarter le rapport", role: .destructive) { discarding = true }
                    }
                }
                .settingsRow()
            }
        }
        .settingsStyle()
        .navigationTitle(kind == .preparation ? "Préparation" : "Vérification")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(kind == .preparation ? "Accepter les identités exactes ?" : "Appliquer les réparations sûres ?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button(kind == .preparation ? "Accepter les identités" : "Appliquer") {
                send("\(base)/apply", .object(["expected_row_revision": job["row_revision"] ?? .null, "confirmation": .bool(true)]))
            }
        } message: {
            Text(kind == .preparation
                 ? "Seules des identités MusicBrainz vérifiées sont écrites dans le catalogue. Ni étiquettes, ni chemins, ni audio ne changent."
                 : "Les identités externes seront retirées de ces albums. Fichiers, identifiants, playlists et lecture ne changent pas.")
        }
        .confirmationDialog("Écarter ce rapport ?", isPresented: $discarding, titleVisibility: .visible) {
            Button("Écarter", role: .destructive) {
                send("\(base)/discard", .object(["expected_row_revision": job["row_revision"] ?? .null]))
            }
        } message: {
            Text("Il quitte l'espace de travail ; sa trace reste dans l'historique.")
        }
        .serverAlert($alert)
        .task(id: category) {
            let page = try? await client.json("GET", "\(base)/findings?limit=100&finding_category=\(category)")
            findings = page?["items"]?.array ?? []
            refreshRequired = page?["refresh_required"]?.bool ?? false
        }
    }

    private func send(_ path: String, _ body: JSON) {
        Task {
            do {
                _ = try await client.json("POST", path, body: body)
                alert = ServerAlert(title: "C'est fait", message: "")
            } catch {
                alert = ServerAlert(title: "Refusé", message: error.localizedDescription)
            }
        }
    }
}
