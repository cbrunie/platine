import SwiftUI

extension JSON {
    var object: [String: JSON]? { if case let .object(value) = self { value } else { nil } }
    var int: Int? { number.map { Int($0) } }
    /// Un texte lisible pour une valeur quelconque.
    var display: String {
        switch self {
        case .null: "—"
        case let .bool(value): value ? "Oui" : "Non"
        case let .number(value): value.rounded() == value ? String(Int(value)) : value.formatted()
        case let .string(value): value.isEmpty ? "—" : value
        case let .array(items): items.isEmpty ? "—" : items.map(\.display).joined(separator: ", ")
        case let .object(fields): "\(fields.count) champs"
        }
    }
}

/// Un message du serveur en alerte, pour les écrans sur mesure.
struct ServerAlert: Identifiable {
    let title: String
    let message: String
    var id: String { title + message }
}

extension View {
    func serverAlert(_ alert: Binding<ServerAlert?>) -> some View {
        self.alert(item: alert) { Alert(title: Text($0.title), message: Text($0.message)) }
    }
}

// MARK: Discothèque

/// Les dossiers de la discothèque et leur politique, l'analyse et son calendrier.
/// L'enregistrement passe par l'aperçu d'impact, comme sur le web.
struct LibrarySettingsView: View {
    @Environment(\.client) private var client
    @State private var settings: JSON?
    @State private var original: JSON?
    @State private var impact: JSON?
    @State private var alert: ServerAlert?
    @State private var busy = false

    private static let policies: [(String, String)] = [
        ("automatic", "Identification automatique"), ("local_metadata", "Métadonnées locales"), ("excluded", "Exclu"),
    ]

    var body: some View {
        Form {
            if let settings {
                Section {
                    Toggle("Discothèque locale", isOn: bool("enabled"))
                } footer: {
                    Text("Tant que c'est activé, l'analyse, l'identification et le rangement des fichiers tournent.")
                }
                .settingsRow()

                Section("Dossiers") {
                    ForEach(Array((settings["library_roots"]?.array ?? []).enumerated()), id: \.offset) { index, _ in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Nom (ex. Discothèque principale)", text: rootText(index, "label"))
                                .font(.headline)
                            TextField("Chemin (ex. /music)", text: rootText(index, "path"))
                                .font(.callout.monospaced())
                                .textInputAutocapitalization(.never)
                            Picker("Politique", selection: rootText(index, "policy")) {
                                ForEach(Self.policies, id: \.0) { Text($0.1).tag($0.0) }
                            }
                            let rules = self.settings?["library_roots"]?.array?[index]["rules"]?.array?.count ?? 0
                            NavigationLink {
                                RulesEditor(rules: rulesBinding(index))
                            } label: {
                                Text(rules == 0 ? "Exceptions par sous-dossier" : "^[\(rules) exception](inflect: true) par sous-dossier")
                                    .font(.subheadline)
                            }
                        }
                    }
                    .onDelete { offsets in
                        var roots = self.settings?["library_roots"]?.array ?? []
                        roots.remove(atOffsets: offsets)
                        self.settings?["library_roots"] = .array(roots)
                    }
                    Button("Ajouter un dossier", systemImage: "plus") {
                        var roots = self.settings?["library_roots"]?.array ?? []
                        roots.append(.object(["id": .string(UUID().uuidString.lowercased()), "path": .string(""),
                                              "label": .string(""), "policy": .string("automatic"), "rules": .array([])]))
                        self.settings?["library_roots"] = .array(roots)
                    }
                }
                .settingsRow()

                Section {
                    TextEditor(text: text("naming_script"))
                        .font(.callout.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 100)
                } header: {
                    Text("Script de nommage")
                } footer: {
                    if let example = settings["naming_example"]?.string, !example.isEmpty {
                        Text("Où sont rangés les téléchargements et les fichiers déposés. Exemple : \(example)")
                    } else {
                        Text("Où sont rangés les téléchargements et les fichiers déposés.")
                    }
                }
                .settingsRow()

                Section {
                    SecureField("Clé d'API AcoustID", text: text("acoustid_api_key"))
                } header: {
                    Text("Identification")
                } footer: {
                    Text("AcoustID identifie la musique sans étiquettes par son empreinte, et vérifie les téléchargements.")
                }
                .settingsRow()

                if settings["reconciliation_required"]?.bool == true {
                    Section {
                        Button("Appliquer les changements…", systemImage: "arrow.triangle.2.circlepath") { applyPolicy() }
                    } footer: {
                        Text("Des changements de politique attendent d'être appliqués aux fichiers déjà indexés.")
                    }
                    .settingsRow()
                }

                Section("Analyse") {
                    Button("Analyser maintenant", systemImage: "magnifyingglass") { scan("incremental") }
                    Button("Réanalyser tous les fichiers", systemImage: "arrow.clockwise") { scan("rescan_files") }
                    NavigationLink { FormPanel(title: "Calendrier", spec: .librarySchedule) } label: {
                        Label("Calendrier", systemImage: "calendar")
                    }
                }
                .settingsRow()
                .disabled(busy)
            } else {
                ProgressView().listRowBackground(Color.clear)
            }
        }
        .settingsStyle()
        .navigationTitle("Discothèque")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Enregistrer") { preview() }.disabled(settings == original || busy)
            }
        }
        .confirmationDialog("Enregistrer la politique de la discothèque ?", isPresented: .constant(impact != nil),
                            titleVisibility: .visible) {
            Button("Enregistrer") { save() }
            Button("Annuler", role: .cancel) { impact = nil }
        } message: {
            Text(impactSummary)
        }
        .serverAlert($alert)
        .task { await load() }
    }

    private var impactSummary: String {
        guard let impact else { return "" }
        var lines: [String] = []
        if let count = impact["indexed_file_count"]?.int { lines.append("\(count) fichiers indexés concernés.") }
        if impact["content_will_become_unavailable"]?.bool == true { lines.append("Du contenu deviendra indisponible.") }
        if impact["queued_work_will_be_cancelled"]?.bool == true { lines.append("Des tâches en attente seront annulées.") }
        lines += (impact["warnings"]?.array ?? []).compactMap(\.string)
        lines.append("Enregistrer ne lance pas d'analyse.")
        return lines.joined(separator: "\n")
    }

    private func bool(_ key: String) -> Binding<Bool> {
        Binding(get: { settings?[key]?.bool ?? false }, set: { settings?[key] = .bool($0) })
    }

    private func text(_ key: String) -> Binding<String> {
        Binding(get: { settings?[key]?.string ?? "" }, set: { settings?[key] = .string($0) })
    }

    private func rootText(_ index: Int, _ key: String) -> Binding<String> {
        Binding(
            get: { settings?["library_roots"]?.array?[index][key]?.string ?? "" },
            set: { newValue in
                guard var roots = settings?["library_roots"]?.array, roots.indices.contains(index) else { return }
                roots[index][key] = .string(newValue)
                settings?["library_roots"] = .array(roots)
            }
        )
    }

    private func rulesBinding(_ index: Int) -> Binding<[JSON]> {
        Binding(
            get: { settings?["library_roots"]?.array?[index]["rules"]?.array ?? [] },
            set: { rules in
                guard var roots = settings?["library_roots"]?.array, roots.indices.contains(index) else { return }
                roots[index]["rules"] = .array(rules)
                settings?["library_roots"] = .array(roots)
            }
        )
    }

    /// Ce que le PUT attend : les réglages typés, sans les champs d'état.
    private var typedSettings: JSON {
        var typed: [String: JSON] = [:]
        for key in ["library_roots", "staging_path", "naming_script", "acoustid_api_key", "enabled"] {
            if let value = settings?[key], value != .null { typed[key] = value }
        }
        return .object(typed)
    }

    private func load() async {
        do {
            settings = try await client.json("GET", "/settings/library")
            original = settings
        } catch {
            alert = ServerAlert(title: "Discothèque", message: error.localizedDescription)
        }
    }

    private func preview() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let result = try await client.json("POST", "/settings/library/policy-impact", body: .object([
                    "settings": typedSettings, "expected_policy_revision": original?["policy_revision"] ?? .null,
                ]))
                if result["stale"]?.bool == true {
                    alert = ServerAlert(title: "Réglages modifiés ailleurs", message: "Recharge la page avant d'enregistrer.")
                    await load()
                } else {
                    impact = result
                }
            } catch {
                alert = ServerAlert(title: "Aperçu impossible", message: error.localizedDescription)
            }
        }
    }

    private func save() {
        let revision = impact?["current_policy_revision"] ?? .null
        impact = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                settings = try await client.json("PUT", "/settings/library", body: .object([
                    "settings": typedSettings, "expected_policy_revision": revision,
                ]))
                original = settings
            } catch {
                alert = ServerAlert(title: "Enregistrement impossible", message: error.localizedDescription)
            }
        }
    }

    private func applyPolicy() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let scopes = settings?["affected_scope_ids"] ?? .array([])
                let preview = try await client.json("POST", "/settings/library/policy-apply-preview", body: .object([
                    "scope_ids": scopes, "expected_policy_revision": settings?["pending_policy_revision"] ?? .null,
                ]))
                _ = try await client.json("POST", "/library/scan/runs", body: .object([
                    "kind": .string("policy_reconcile"), "scope_ids": preview["scope_ids"] ?? scopes,
                    "expected_policy_revision": preview["policy_revision"] ?? .null,
                ]))
                alert = ServerAlert(title: "Changements appliqués",
                                    message: "\(preview["estimated_file_count"]?.int ?? 0) fichiers à reprendre.")
                await load()
            } catch {
                alert = ServerAlert(title: "Application impossible", message: error.localizedDescription)
            }
        }
    }

    private func scan(_ kind: String) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let run = try await client.json("POST", "/library/scan/runs", body: .object([
                    "kind": .string(kind), "scope_ids": .array([]),
                    "expected_policy_revision": settings?["policy_revision"] ?? .null,
                ]))
                let disposition = run["disposition"]?.string ?? "started"
                alert = ServerAlert(title: "Analyse", message: [
                    "started": "L'analyse a démarré.", "queued": "L'analyse attend son tour.",
                    "coalesced": "Une analyse identique tourne déjà.", "expanded": "L'analyse en cours a été élargie.",
                    "conflict": "Une autre opération bloque l'analyse.",
                ][disposition] ?? disposition)
            } catch {
                alert = ServerAlert(title: "Analyse impossible", message: error.localizedDescription)
            }
        }
    }
}

/// Les exceptions d'un dossier : un sous-dossier relatif et sa propre politique.
private struct RulesEditor: View {
    @Binding var rules: [JSON]

    private static let policies: [(String, String)] = [
        ("automatic", "Identification automatique"), ("local_metadata", "Métadonnées locales"), ("excluded", "Exclu"),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(rules.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Sous-dossier (ex. Compilations/Live)", text: text(index, "relative_path"))
                            .font(.callout.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Picker("Politique", selection: text(index, "policy")) {
                            ForEach(Self.policies, id: \.0) { Text($0.1).tag($0.0) }
                        }
                    }
                }
                .onDelete { rules.remove(atOffsets: $0) }
                Button("Ajouter une exception", systemImage: "plus") {
                    rules.append(.object(["id": .string(UUID().uuidString.lowercased()), "relative_path": .string(""),
                                          "policy": .string("excluded")]))
                }
            } footer: {
                Text("Chemins relatifs au dossier. Pense à enregistrer la discothèque en revenant.")
            }
            .settingsRow()
        }
        .settingsStyle()
        .navigationTitle("Exceptions")
    }

    private func text(_ index: Int, _ key: String) -> Binding<String> {
        Binding(get: { rules[index][key]?.string ?? "" }, set: { rules[index][key] = .string($0) })
    }
}

// MARK: Indexeurs

/// Indexeurs Newznab ou Prowlarr : la source des recherches Usenet.
struct IndexersView: View {
    @Environment(\.client) private var client
    @State private var backend = "indexers"
    @State private var indexers: [JSON] = []
    @State private var editing: JSON?
    @State private var alert: ServerAlert?

    var body: some View {
        List {
            Section {
                Picker("Rechercher avec", selection: Binding(get: { backend }, set: { setBackend($0) })) {
                    Text("Mes indexeurs").tag("indexers")
                    Text("Prowlarr").tag("prowlarr")
                }
                NavigationLink { FormPanel(title: "Prowlarr", spec: .prowlarr) } label: {
                    Label { Text("Connexion à Prowlarr") } icon: { IconTile(.logo("logo-prowlarr")) }
                }
            }
            .settingsRow()

            Section {
                ForEach(Array(indexers.enumerated()), id: \.offset) { _, indexer in
                    Button { editing = indexer } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(indexer["name"]?.string ?? "Sans nom").foregroundStyle(.primary)
                                Text(indexer["url"]?.string ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(get: { indexer["enabled"]?.bool ?? false },
                                                     set: { toggle(indexer, $0) }))
                                .labelsHidden()
                        }
                    }
                }
                .onDelete { delete($0) }
                .onMove { move($0, $1) }
                Button("Ajouter un indexeur", systemImage: "plus") {
                    editing = .object(["id": .string(""), "type": .string("newznab"), "name": .string(""),
                                       "url": .string(""), "api_key": .string(""), "enabled": .bool(true),
                                       "priority": .number(1),
                                       "categories": .array([.number(3000), .number(3010), .number(3040)])])
                }
            } header: {
                Text("Indexeurs")
            } footer: {
                Text("Glisse pour réordonner : le premier est interrogé d'abord.")
            }
            .settingsRow()
        }
        .settingsStyle()
        .navigationTitle("Indexeurs")
        .toolbar { EditButton() }
        .sheet(item: Binding(get: { editing.map(IdentifiedJSON.init) }, set: { editing = $0?.value })) { item in
            IndexerEditor(indexer: item.value) { await load() }
        }
        .serverAlert($alert)
        .task { await load() }
    }

    private func load() async {
        backend = (try? await client.json("GET", "/settings/indexers/search-backend"))?["backend"]?.string ?? backend
        indexers = (try? await client.json("GET", "/settings/indexers"))?.array ?? []
    }

    private func setBackend(_ value: String) {
        backend = value
        Task { await report { _ = try await client.json("PUT", "/settings/indexers/search-backend", body: .object(["backend": .string(value)])) } }
    }

    private func toggle(_ indexer: JSON, _ enabled: Bool) {
        var updated = indexer
        updated["enabled"] = .bool(enabled)
        updated["api_key"] = .string("indexer****")
        Task { await report { _ = try await client.json("PUT", "/settings/indexers/\(indexer["id"]?.string ?? "")", body: updated) } }
    }

    private func delete(_ offsets: IndexSet) {
        let ids = offsets.compactMap { indexers[$0]["id"]?.string }
        indexers.remove(atOffsets: offsets)
        Task { await report { for id in ids { _ = try await client.json("DELETE", "/settings/indexers/\(id)") } } }
    }

    private func move(_ offsets: IndexSet, _ destination: Int) {
        indexers.move(fromOffsets: offsets, toOffset: destination)
        let ids = JSON.array(indexers.compactMap { $0["id"] })
        Task { await report { _ = try await client.json("POST", "/settings/indexers/reorder", body: .object(["ordered_ids": ids])) } }
    }

    private func report(_ work: () async throws -> Void) async {
        do { try await work() } catch { alert = ServerAlert(title: "Indexeurs", message: error.localizedDescription) }
        await load()
    }
}

/// Une valeur JSON qu'on présente (feuille, navigation). Son identité vient de
/// son contenu : stable d'un rendu à l'autre, sinon l'écran se rouvrirait.
struct IdentifiedJSON: Identifiable, Hashable {
    let value: JSON
    let id: String

    init(value: JSON) {
        self.value = value
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        id = (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? UUID().uuidString
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Un indexeur Newznab : nom, adresse, clé, catégories, et un test.
private struct IndexerEditor: View {
    @State var indexer: JSON
    let saved: () async -> Void

    @Environment(\.client) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var alert: ServerAlert?
    @State private var suggested: String?

    private static let categories: [(Double, String)] = [(3000, "Audio"), (3010, "MP3"), (3040, "Sans perte")]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nom (ex. Mon indexeur)", text: text("name"))
                    TextField("Adresse (https://indexer.example/api)", text: text("url"))
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                    SecureField("Clé d'API", text: text("api_key"))
                }
                .settingsRow()
                Section("Catégories") {
                    ForEach(Self.categories, id: \.0) { value, label in
                        let selected = (indexer["categories"]?.array ?? []).contains(.number(value))
                        Button {
                            var items = indexer["categories"]?.array ?? []
                            if selected { items.removeAll { $0 == .number(value) } } else { items.append(.number(value)) }
                            indexer["categories"] = .array(items)
                        } label: {
                            HStack {
                                Text("\(label) (\(Int(value)))").foregroundStyle(.primary)
                                Spacer()
                                if selected { Image(systemName: "checkmark").foregroundStyle(Color.sage) }
                            }
                        }
                    }
                }
                .settingsRow()
                Section {
                    Button("Tester", systemImage: "checkmark.seal") { test() }
                    if let suggested {
                        Button("Utiliser \(suggested)") {
                            indexer["url"] = .string(suggested)
                            self.suggested = nil
                            test()
                        }
                    }
                }
                .settingsRow()
            }
            .settingsStyle()
            .navigationTitle(indexer["id"]?.string?.isEmpty == false ? "Indexeur" : "Nouvel indexeur")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Enregistrer") { save() } }
            }
            .serverAlert($alert)
        }
    }

    private func text(_ key: String) -> Binding<String> {
        Binding(get: { indexer[key]?.string ?? "" }, set: { indexer[key] = .string($0) })
    }

    private func test() {
        Task {
            do {
                let result = try await client.json("POST", "/settings/indexers/test", body: indexer)
                suggested = result["suggested_url"]?.string
                alert = ServerAlert(title: result["valid"]?.bool == true ? "Ça répond" : "Échec du test",
                                    message: FormPanel.summary(of: result))
            } catch {
                alert = ServerAlert(title: "Échec du test", message: error.localizedDescription)
            }
        }
    }

    private func save() {
        Task {
            do {
                let id = indexer["id"]?.string ?? ""
                _ = try await client.json(id.isEmpty ? "POST" : "PUT", id.isEmpty ? "/settings/indexers" : "/settings/indexers/\(id)", body: indexer)
                await saved()
                dismiss()
            } catch {
                alert = ServerAlert(title: "Enregistrement impossible", message: error.localizedDescription)
            }
        }
    }
}

// MARK: Ordre des sources

/// L'ordre dans lequel les sources sont essayées, enregistré à chaque déplacement.
struct SourcePriorityView: View {
    @Environment(\.client) private var client
    @State private var order: [String] = []
    @State private var alert: ServerAlert?

    var body: some View {
        List {
            Section {
                ForEach(order, id: \.self) { key in
                    Label(Self.name(key), systemImage: key == "soulseek" ? "arrow.down.circle" : key == "usenet" ? "arrow.down.doc" : "puzzlepiece.extension")
                }
                .onMove { offsets, destination in
                    order.move(fromOffsets: offsets, toOffset: destination)
                    Task {
                        do {
                            _ = try await client.json("PUT", "/settings/download-clients/source-priority",
                                                      body: .object(["order": .array(order.map(JSON.string))]))
                        } catch {
                            alert = ServerAlert(title: "Ordre non enregistré", message: error.localizedDescription)
                        }
                    }
                }
            } footer: {
                Text("La première source est essayée d'abord.")
            }
            .settingsRow()
        }
        .environment(\.editMode, .constant(.active))
        .settingsStyle()
        .navigationTitle("Ordre des sources")
        .serverAlert($alert)
        .task { order = (try? await client.json("GET", "/settings/download-clients/source-priority"))?["order"]?.array?.compactMap(\.string) ?? [] }
    }

    private static func name(_ key: String) -> String {
        switch key {
        case "soulseek": "Soulseek (slskd)"
        case "usenet": "Usenet (SABnzbd)"
        default: key.capitalized
        }
    }
}

// MARK: Import Lidarr

/// Reprendre les artistes suivis par Lidarr.
struct LidarrImportView: View {
    @Environment(\.client) private var client
    @State private var artists: [JSON] = []
    @State private var selected: Set<String> = []
    @State private var loading = false
    @State private var alert: ServerAlert?

    var body: some View {
        List {
            Section {
                NavigationLink { FormPanel(title: "Lidarr", spec: .lidarr) } label: {
                    Label { Text("Connexion à Lidarr") } icon: { IconTile(.logo("logo-lidarr")) }
                }
            }
            .settingsRow()
            Section {
                ForEach(artists.indices, id: \.self) { index in
                    let artist = artists[index]
                    let mbid = artist["mbid"]?.string ?? ""
                    let following = artist["already_following"]?.bool == true
                    Button {
                        if selected.contains(mbid) { selected.remove(mbid) } else { selected.insert(mbid) }
                    } label: {
                        HStack {
                            Text(artist["name"]?.string ?? mbid).foregroundStyle(following ? .secondary : .primary)
                            Spacer()
                            if following {
                                Text("Déjà suivi").font(.caption).foregroundStyle(.secondary)
                            } else if selected.contains(mbid) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.sage)
                            } else {
                                Image(systemName: "circle").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(following)
                }
            } header: {
                HStack {
                    Text("Artistes de Lidarr")
                    Spacer()
                    Button("Revérifier") { Task { await load() } }.font(.caption)
                }
            }
            .settingsRow()
        }
        .settingsStyle()
        .navigationTitle("Import Lidarr")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Importer \(selected.count)") { importSelected() }.disabled(selected.isEmpty)
            }
        }
        .overlay { if loading { ProgressView() } }
        .serverAlert($alert)
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        artists = (try? await client.json("GET", "/acquire/lidarr-import/artists"))?["artists"]?.array ?? []
        selected = Set(artists.filter { $0["already_following"]?.bool != true }.compactMap { $0["mbid"]?.string })
    }

    private func importSelected() {
        Task {
            do {
                let result = try await client.json("POST", "/acquire/lidarr-import/import",
                                                   body: .object(["selected_mbids": .array(selected.map(JSON.string))]))
                alert = ServerAlert(title: "Import terminé",
                                    message: "\(result["imported"]?.int ?? 0) artistes suivis, \(result["already_following"]?.int ?? 0) déjà suivis.")
                await load()
            } catch {
                alert = ServerAlert(title: "Import impossible", message: error.localizedDescription)
            }
        }
    }
}

// MARK: Cache

/// Le cache du serveur : les réponses des fournisseurs par source, les images,
/// la taille de la base ; de quoi vider les unes ou les autres et rafraîchir les images.
struct CacheView: View {
    @Environment(\.client) private var client
    @State private var stats: JSON?
    @State private var clearing: (key: String, label: String)?
    @State private var refreshing = false
    @State private var alert: ServerAlert?

    private static let targets: [(key: String, label: String)] = [
        ("provider_data", "Données des fournisseurs"), ("covers", "Images"), ("all", "Tout"),
    ]

    var body: some View {
        List {
            if let stats {
                Section {
                    LabeledContent("Données des fournisseurs",
                                   value: "\(stats["entries"]?.int?.formatted() ?? "—") · \(Self.bytes(providerBytes))")
                    LabeledContent("Images", value: "\(stats["cover_images"]?.int?.formatted() ?? "—") · \(Self.bytes(stats["cover_bytes"]))")
                    LabeledContent("Base de données", value: Self.bytes(stats["database_bytes"]))
                    LabeledContent("Journal d'écriture", value: Self.bytes(stats["wal_bytes"]))
                } header: {
                    Text("Occupation")
                } footer: {
                    if stats["provider_data_on"]?.bool == false {
                        Text("Le cache des fournisseurs est désactivé.")
                    }
                }
                .settingsRow()

                if !sources.isEmpty {
                    Section("Par source") {
                        ForEach(sources.indices, id: \.self) { index in
                            let source = sources[index]
                            LabeledContent(Self.sourceName(source["source"]?.string ?? ""),
                                           value: "\(source["rows"]?.int?.formatted() ?? "—") · \(Self.bytes(source["bytes"]))")
                        }
                    }
                    .settingsRow()
                }
            }
            Section {
                Button(refreshing ? "Rafraîchissement lancé…" : "Rafraîchir les images de la discothèque",
                       systemImage: "photo.on.rectangle.angled") { refreshImages() }
                    .disabled(refreshing)
            } footer: {
                Text("Va chercher les images d'artistes et d'albums de la discothèque. Elles arrivent aussi après chaque analyse.")
            }
            .settingsRow()
            Section {
                ForEach(Self.targets, id: \.key) { target in
                    Button("Vider : \(target.label)", role: .destructive) { clearing = target }
                }
            } header: {
                Text("Vider")
            } footer: {
                Text("Ce qui est vidé est redemandé au besoin.")
            }
            .settingsRow()
        }
        .settingsStyle()
        .navigationTitle("Cache")
        .refreshable { await load() }
        .confirmationDialog("Vider « \(clearing?.label ?? "") » ?", isPresented: .constant(clearing != nil),
                            titleVisibility: .visible) {
            Button("Vider", role: .destructive) { clear() }
            Button("Annuler", role: .cancel) { clearing = nil }
        }
        .serverAlert($alert)
        .task { await load() }
    }

    /// Les sources les plus lourdes d'abord.
    private var sources: [JSON] {
        (stats?["sources"]?.array ?? []).sorted { ($0["bytes"]?.number ?? 0) > ($1["bytes"]?.number ?? 0) }
    }

    private var providerBytes: JSON {
        .number(sources.reduce(0) { $0 + ($1["bytes"]?.number ?? 0) })
    }

    private static func bytes(_ value: JSON?) -> String {
        guard let value = value?.number else { return "—" }
        return Int64(value).formatted(.byteCount(style: .file))
    }

    private static func sourceName(_ key: String) -> String {
        switch key {
        case "musicbrainz": "MusicBrainz"
        case "listenbrainz": "ListenBrainz"
        case "lastfm": "Last.fm"
        case "audiodb": "TheAudioDB"
        case "wikidata": "Wikidata"
        case "purchase": "Liens d'achat"
        case "plugins": "Plugins"
        case "youtube": "YouTube"
        case "lrclib": "LRCLIB (paroles)"
        case "previews": "Extraits"
        default: key
        }
    }

    private func load() async { stats = try? await client.json("GET", "/admin/cache/stats") }

    private func clear() {
        guard let target = clearing else { return }
        clearing = nil
        Task {
            do {
                let result = try await client.json("POST", "/admin/cache/clear", body: .object(["scope": .string(target.key)]))
                alert = ServerAlert(title: "Cache vidé", message: FormPanel.summary(of: result))
            } catch {
                alert = ServerAlert(title: "Échec", message: error.localizedDescription)
            }
            await load()
        }
    }

    private func refreshImages() {
        refreshing = true
        Task {
            do {
                _ = try await client.json("POST", "/admin/precache/run")
            } catch {
                refreshing = false
                alert = ServerAlert(title: "Rafraîchissement impossible", message: error.localizedDescription)
            }
        }
    }
}

// MARK: MusicBrainz

/// La source MusicBrainz : officielle, miroir, communautaire ou BrainzMash.
/// Un miroir se teste avant d'être enregistré ; BrainzMash passe par ses étapes.
struct MusicBrainzView: View {
    @Environment(\.client) private var client
    @State private var settings: JSON?
    @State private var mode = "official"
    @State private var url = ""
    @State private var rateLimit: Double = 1
    @State private var acknowledged = false
    @State private var tested = false
    @State private var alert: ServerAlert?

    var body: some View {
        Form {
            if let settings {
                Section {
                    LabeledContent("Source active", value: Self.name(settings["source_mode"]?.string ?? ""))
                    if settings["clamped_to_official_limits"]?.bool == true {
                        Label("Ramenée au rythme du serveur officiel", systemImage: "tortoise.fill")
                            .foregroundStyle(.yellow)
                    }
                }
                .settingsRow()

                Section("Changer de source") {
                    Picker("Source", selection: $mode) {
                        Text("BrainzMash (recommandé)").tag("brainzmash")
                        Text("Officielle").tag("official")
                        Text("Miroir auto-hébergé").tag("mirror")
                        Text("Serveur communautaire").tag("community")
                    }
                    .onChange(of: mode) { tested = false }
                    if mode == "mirror" || mode == "community" {
                        TextField("Adresse de l'API", text: $url).textInputAutocapitalization(.never).keyboardType(.URL)
                            .onChange(of: url) { tested = false }
                        LabeledContent("Requêtes par seconde (0 = illimité)") {
                            TextField("", value: $rateLimit, format: .number).multilineTextAlignment(.trailing).keyboardType(.decimalPad)
                        }
                    }
                    if mode == "community" {
                        Toggle("J'ai compris que ce serveur n'est pas tenu par MusicBrainz", isOn: $acknowledged)
                    }
                }
                .settingsRow()

                Section {
                    if mode == "brainzmash" {
                        Button("Préparer BrainzMash", systemImage: "1.circle") { step("/settings/musicbrainz/brainzmash/stage", nil) }
                        Button("Accepter les conditions", systemImage: "2.circle") { step("/settings/musicbrainz/brainzmash/consent", binding) }
                            .disabled(settings["pending_brainzmash"] == nil || settings["pending_brainzmash"] == .null)
                        Button("Vérifier", systemImage: "3.circle") { step("/settings/musicbrainz/verify", binding) }
                            .disabled(settings["pending_brainzmash"]?["consented"]?.bool != true)
                        Button("Activer", systemImage: "4.circle") { step("/settings/musicbrainz/activate", binding) }
                            .disabled(settings["pending_brainzmash"]?["verified"]?.bool != true)
                    } else {
                        Button("Tester la connexion", systemImage: "checkmark.seal") { test() }
                        Button("Enregistrer", systemImage: "square.and.arrow.down") { save() }
                            .disabled(!tested || (mode == "community" && !acknowledged))
                    }
                } footer: {
                    Text(mode == "brainzmash" ? "Chaque étape débloque la suivante." : "Enregistrer demande un test réussi.")
                }
                .settingsRow()
            } else {
                ProgressView().listRowBackground(Color.clear)
            }
        }
        .settingsStyle()
        .navigationTitle("MusicBrainz")
        .serverAlert($alert)
        .task { await load() }
    }

    private var update: JSON {
        let offOfficial = mode == "mirror" || mode == "community"
        return .object([
            "source_mode": .string(mode),
            "api_url": offOfficial ? .string(url) : .null,
            "rate_limit": .number(mode == "official" ? 1 : mode == "brainzmash" ? 10 : rateLimit),
            "community_acknowledged": mode == "community" ? .bool(acknowledged) : .null,
        ])
    }

    /// Ce qui lie chaque étape BrainzMash à la précédente.
    private var binding: JSON {
        let pending = settings?["pending_brainzmash"]
        var fields: [String: JSON] = [:]
        for key in ["access_revision", "source_id", "generation", "disclosure_version"] { fields[key] = pending?[key] ?? .null }
        return .object(fields)
    }

    private func load() async {
        settings = try? await client.json("GET", "/settings/musicbrainz")
        mode = settings?["selected_source_mode"]?.string ?? settings?["source_mode"]?.string ?? "official"
        url = settings?["api_url"]?.string ?? ""
        rateLimit = settings?["rate_limit"]?.number ?? 1
        acknowledged = settings?["community_acknowledged"]?.bool ?? false
    }

    private func test() {
        Task {
            do {
                _ = try await client.json("POST", "/settings/musicbrainz/verify", body: update)
                tested = true
                alert = ServerAlert(title: "Ça répond", message: "Tu peux enregistrer cette source.")
            } catch {
                alert = ServerAlert(title: "Échec du test", message: error.localizedDescription)
            }
        }
    }

    private func save() {
        Task {
            do {
                settings = try await client.json("PUT", "/settings/musicbrainz", body: update)
                alert = ServerAlert(title: "Enregistré", message: "La nouvelle source est active.")
            } catch {
                alert = ServerAlert(title: "Enregistrement impossible", message: error.localizedDescription)
            }
        }
    }

    private func step(_ path: String, _ body: JSON?) {
        Task {
            do { settings = try await client.json("POST", path, body: body) } catch {
                alert = ServerAlert(title: "BrainzMash", message: error.localizedDescription)
            }
        }
    }

    private static func name(_ mode: String) -> String {
        switch mode {
        case "brainzmash": "BrainzMash"
        case "mirror": "Miroir auto-hébergé"
        case "community": "Serveur communautaire"
        default: "Officielle"
        }
    }
}

// MARK: Plugins

/// Les plugins : les activer, les régler, en installer, en retirer.
struct PluginsView: View {
    @Environment(\.client) private var client
    @State private var plugins: [JSON] = []
    @State private var repository = ""
    @State private var alert: ServerAlert?

    var body: some View {
        List {
            Section {
                ForEach(plugins.indices, id: \.self) { index in
                    let plugin = plugins[index]
                    NavigationLink { PluginView(plugin: plugin) { await load() } } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(plugin["display_name"]?.string ?? plugin["name"]?.string ?? "")
                                Text(plugin["version"]?.string ?? "").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if plugin["error"]?.string != nil {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                                } else if plugin["enabled"]?.bool == true {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.sage)
                                }
                            }
                            if let description = plugin["description"]?.string, !description.isEmpty {
                                Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
            }
            .settingsRow()
            Section {
                TextField("https://github.com/…", text: $repository)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                Button("Installer", systemImage: "square.and.arrow.down") { install() }.disabled(repository.isEmpty)
            } header: {
                Text("Installer depuis GitHub")
            }
            .settingsRow()
        }
        .settingsStyle()
        .navigationTitle("Plugins")
        .serverAlert($alert)
        .task { await load() }
    }

    private func load() async { plugins = (try? await client.json("GET", "/plugins"))?["plugins"]?.array ?? [] }

    private func install() {
        Task {
            do {
                _ = try await client.json("POST", "/plugins/install", body: .object(["repository_url": .string(repository)]))
                repository = ""
                await load()
            } catch {
                alert = ServerAlert(title: "Installation impossible", message: error.localizedDescription)
            }
        }
    }
}

private struct PluginView: View {
    let plugin: JSON
    let changed: () async -> Void

    @Environment(\.client) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = false
    @State private var values: [String: String] = [:]
    @State private var removing = false
    @State private var alert: ServerAlert?

    private var name: String { plugin["name"]?.string ?? "" }

    var body: some View {
        Form {
            if let error = plugin["error"]?.string {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.yellow) }.settingsRow()
            }
            Section {
                Toggle("Activé", isOn: $enabled)
                if let author = plugin["author"]?.string { LabeledContent("Auteur", value: author) }
                if let capabilities = plugin["capabilities"]?.array, !capabilities.isEmpty {
                    LabeledContent("Capacités", value: capabilities.compactMap(\.string).joined(separator: ", "))
                }
            }
            .settingsRow()
            let fields = plugin["settings_fields"]?.array ?? []
            if !fields.isEmpty {
                Section("Réglages") {
                    ForEach(fields.indices, id: \.self) { index in
                        let field = fields[index]
                        let key = field["key"]?.string ?? ""
                        let binding = Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
                        VStack(alignment: .leading, spacing: 4) {
                            if field["secret"]?.bool == true {
                                SecureField(field["label"]?.string ?? key, text: binding)
                            } else {
                                TextField(field["label"]?.string ?? key, text: binding).textInputAutocapitalization(.never)
                            }
                            if let help = field["help"]?.string, !help.isEmpty {
                                Text(help).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .settingsRow()
            }
            Section {
                Button("Retirer ce plugin", role: .destructive) { removing = true }
            }
            .settingsRow()
        }
        .settingsStyle()
        .navigationTitle(plugin["display_name"]?.string ?? name)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Enregistrer") { save() } } }
        .confirmationDialog("Retirer ce plugin ?", isPresented: $removing, titleVisibility: .visible) {
            Button("Retirer", role: .destructive) { remove() }
        }
        .serverAlert($alert)
        .onAppear {
            enabled = plugin["enabled"]?.bool ?? false
            values = (plugin["settings_values"]?.object ?? [:]).compactMapValues(\.string)
        }
    }

    private func save() {
        Task {
            do {
                _ = try await client.json("PUT", "/plugins/\(name)", body: .object([
                    "enabled": .bool(enabled), "settings": .object(values.mapValues(JSON.string)),
                ]))
                await changed()
                alert = ServerAlert(title: "Enregistré", message: "Le plugin a pris en compte les changements.")
            } catch {
                alert = ServerAlert(title: "Enregistrement impossible", message: error.localizedDescription)
            }
        }
    }

    private func remove() {
        Task {
            do {
                _ = try await client.json("DELETE", "/plugins/\(name)")
                await changed()
                dismiss()
            } catch {
                alert = ServerAlert(title: "Impossible de retirer", message: error.localizedDescription)
            }
        }
    }
}

// MARK: Diagnostics

/// Les files de travail et les fournisseurs du serveur, tels qu'il les rapporte.
struct DiagnosticsView: View {
    @Environment(\.client) private var client
    @State private var queues: JSON?
    @State private var providers: JSON?

    var body: some View {
        List {
            if let queues { JSONRows(title: "Files de travail", value: queues) }
            if let providers { JSONRows(title: "Fournisseurs", value: providers) }
            if queues == nil, providers == nil { ProgressView().listRowBackground(Color.clear) }
        }
        .settingsStyle()
        .navigationTitle("Diagnostics")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        async let queues = try? client.json("GET", "/admin/queue-stats")
        async let providers = try? client.json("GET", "/admin/provider-stats")
        self.queues = await queues
        self.providers = await providers
    }
}

/// Un objet JSON en lignes lisibles, les objets imbriqués en sous-pages.
struct JSONRows: View {
    let title: String
    let value: JSON

    var body: some View {
        Section(title) {
            switch value {
            case let .object(fields):
                ForEach(fields.keys.sorted(), id: \.self) { key in row(key, fields[key] ?? .null) }
            case let .array(items):
                ForEach(items.indices, id: \.self) { index in row("\(index + 1)", items[index]) }
            default:
                Text(value.display)
            }
        }
        .settingsRow()
    }

    @ViewBuilder
    private func row(_ key: String, _ value: JSON) -> some View {
        let label = key.replacingOccurrences(of: "_", with: " ").capitalized
        switch value {
        case .object, .array:
            NavigationLink(label) { List { JSONRows(title: label, value: value) }.settingsStyle().navigationTitle(label) }
        default:
            LabeledContent(label, value: value.display)
        }
    }
}
