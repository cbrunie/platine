import SwiftUI

/// L'automatisation du rangement : les profils, ce que chaque dossier fait
/// tout seul, les scripts, la rétention. On modifie un brouillon ; l'enregistrement
/// passe par la validation, l'impact, et si besoin l'assistant d'activation.
struct AutomationPane: View {
    @Environment(\.client) private var client
    @State private var draft: JSON?
    @State private var original: JSON?
    @State private var library: JSON?
    @State private var health: JSON?
    @State private var saving = false
    @State private var wizard: ActivationRequest?
    @State private var copying: JSON?
    @State private var copyName = ""
    @State private var deleting: JSON?
    @State private var importing = false
    @State private var purging: JSON?
    @State private var purgeText = ""
    @State private var alert: ServerAlert?

    var body: some View {
        List {
            if let draft {
                profiles(draft)
                rootsSection(draft)
                Section("Scripts") {
                    NavigationLink("Scripts de nommage") { ScriptsEditor(scripts: scripts("naming_scripts"), kind: .naming) }
                    NavigationLink("Scripts d'étiquetage") { ScriptsEditor(scripts: scripts("tagging_scripts"), kind: .tagging) }
                }
                .settingsRow()
                advanced
            } else {
                ProgressView().listRowBackground(Color.clear)
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else {
                    Button("Enregistrer") { save() }.disabled(draft == original)
                }
            }
        }
        .alert("Copier le profil", isPresented: .constant(copying != nil)) {
            TextField("Nom", text: $copyName)
            Button("Annuler", role: .cancel) { copying = nil }
            Button("Créer la copie") { if let copying { copy(copying) }; copying = nil }
        }
        .confirmationDialog("Supprimer « \(deleting?["name"]?.string ?? "") » ?", isPresented: .constant(deleting != nil),
                            titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) { if let deleting { delete(deleting) }; deleting = nil }
            Button("Annuler", role: .cancel) { deleting = nil }
        } message: {
            Text("Seul le profil disparaît. Un profil attribué ne peut pas être supprimé, et aucun fichier n'est touché.")
        }
        .alert("Purger les états d'origine ?", isPresented: .constant(purging != nil)) {
            TextField(confirmationPhrase, text: $purgeText).textInputAutocapitalization(.characters)
            Button("Annuler", role: .cancel) { purging = nil; purgeText = "" }
            Button("Purger", role: .destructive) { purge() }
        } message: {
            Text("\(purging?["baseline_count"]?.int ?? 0) état(s) d'origine seront définitivement supprimés. Tape \(confirmationPhrase).")
        }
        .sheet(item: $wizard) { request in
            ActivationWizard(request: request) { await load() }
        }
        .sheet(isPresented: $importing) { ProfileImportSheet(revision: original?["settings_revision"] ?? .null) { await load() } }
        .serverAlert($alert)
        .task { await load() }
    }

    // MARK: Sections

    private func profiles(_ draft: JSON) -> some View {
        let list = draft["profiles"]?.array ?? []
        let assigned = Set((draft["root_assignments"]?.array ?? []).compactMap { $0["profile_id"]?.string })
        return Section {
            ForEach(list.indices, id: \.self) { index in
                let profile = list[index]
                let id = profile["id"]?.string ?? ""
                let isDefault = draft["default_profile_id"]?.string == id
                NavigationLink {
                    ProfileEditor(profile: profileBinding(index), namingScripts: draft["naming_scripts"]?.array ?? [])
                } label: {
                    HStack {
                        Image(systemName: isDefault ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(Color.sage)
                            .onTapGesture { self.draft?["default_profile_id"] = .string(id) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile["name"]?.string ?? "")
                            Text(profile["preset_origin"] == nil || profile["preset_origin"] == .null ? "Sur mesure" : "Préréglage")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .contextMenu {
                    Button("Créer une copie", systemImage: "plus.square.on.square") {
                        copyName = "\(profile["name"]?.string ?? "") (copie)"
                        copying = profile
                    }
                    Button("Partager le code", systemImage: "square.and.arrow.up") { share(profile) }
                    if profile["preset_origin"] == nil || profile["preset_origin"] == .null, !isDefault, !assigned.contains(id), list.count > 1 {
                        Button("Supprimer", systemImage: "trash", role: .destructive) { deleting = profile }
                    }
                }
            }
            Button("Importer un profil…", systemImage: "square.and.arrow.down") { importing = true }
                .disabled(self.draft != original)
        } header: {
            Text("Profils")
        } footer: {
            Text("Le rond choisit le profil par défaut. Appui long pour copier, partager ou supprimer.")
        }
        .settingsRow()
    }

    private func rootsSection(_ draft: JSON) -> some View {
        let assignments = draft["root_assignments"]?.array ?? []
        let stale = Set((health?["stale_root_ids"]?.array ?? []).compactMap(\.string))
        let blocked = Set((health?["blocked_root_ids"]?.array ?? []).compactMap(\.string))
        return Section {
            ForEach(assignments.indices, id: \.self) { index in
                let assignment = assignments[index]
                let rootID = assignment["root_id"]?.string ?? ""
                let on = assignment["enabled"]?.bool == true
                let automatic = ["automatic_acquisitions", "automatic_drop_imports", "automatic_scan_discovered"]
                    .contains { assignment[$0]?.bool == true }
                DisclosureGroup {
                    Picker("Profil", selection: assignmentText(index, "profile_id")) {
                        Text("Profil par défaut").tag("")
                        ForEach((draft["profiles"]?.array ?? []).indices, id: \.self) { profile in
                            Text(draft["profiles"]?.array?[profile]["name"]?.string ?? "")
                                .tag(draft["profiles"]?.array?[profile]["id"]?.string ?? "")
                        }
                    }
                    Toggle("Ranger les fichiers de ce dossier", isOn: assignmentBool(index, "enabled"))
                    Toggle("Après un téléchargement", isOn: assignmentBool(index, "automatic_acquisitions"))
                    Toggle("Après un dépôt", isOn: assignmentBool(index, "automatic_drop_imports"))
                    Toggle("Quand l'analyse en trouve", isOn: assignmentBool(index, "automatic_scan_discovered"))
                    Toggle("Y compris les éditions sur mesure", isOn: assignmentBool(index, "automatic_custom_editions"))
                } label: {
                    HStack(spacing: 12) {
                        IconTile(symbol: "folder.fill", color: on ? .sage : .gray)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rootLabel(rootID))
                            Text(on ? (automatic ? "Automatique · \(profileName(assignment))" : "Configuré · déclencheurs coupés") : "Désactivé")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if blocked.contains(rootID) { Pill(text: "En pause", color: .red) }
                        else if stale.contains(rootID) { Pill(text: "Essai à refaire", color: .yellow) }
                    }
                }
            }
        } header: {
            Text("Rangement automatique par dossier")
        } footer: {
            if let reason = health?["blocked_reason"]?.string { Text(reason) }
        }
        .settingsRow()
    }

    private var advanced: some View {
        Section {
            LabeledContent("Annulation possible (jours)") {
                TextField("", value: number("undo_retention_days"), format: .number).multilineTextAlignment(.trailing).keyboardType(.numberPad)
            }
            LabeledContent("Durée d'un aperçu (heures)") {
                TextField("", value: number("preview_retention_hours"), format: .number).multilineTextAlignment(.trailing).keyboardType(.numberPad)
            }
            TextField("Corbeille (dossier)", text: text("recycle_bin_path")).textInputAutocapitalization(.never)
            LabeledContent("Garder dans la corbeille (jours)") {
                TextField("", value: number("recycle_retention_days"), format: .number).multilineTextAlignment(.trailing).keyboardType(.numberPad)
            }
            Toggle("Prévenir les serveurs après écriture", isOn: bool("external_refresh.enabled"))
            Toggle("Plex", isOn: bool("external_refresh.plex_enabled"))
            Toggle("Jellyfin", isOn: bool("external_refresh.jellyfin_enabled"))
            Toggle("Navidrome", isOn: bool("external_refresh.navidrome_enabled"))
            Button("Purger les états d'origine…", role: .destructive) { purgeImpact() }
        } header: {
            Text("Rétention, corbeille et rafraîchissement")
        }
        // Les champs gardent la taille de texte des autres lignes, sur Mac aussi.
        .font(.body)
        .settingsRow()
    }

    // MARK: Liaisons

    private func profileName(_ assignment: JSON) -> String {
        let id = assignment["profile_id"]?.string ?? draft?["default_profile_id"]?.string
        return (draft?["profiles"]?.array ?? []).first { $0["id"]?.string == id }?["name"]?.string ?? "profil par défaut"
    }

    private func rootLabel(_ id: String) -> String {
        let root = (library?["library_roots"]?.array ?? []).first { $0["id"]?.string == id }
        return root?["label"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? root?["path"]?.string ?? id
    }

    private func bool(_ path: String) -> Binding<Bool> {
        Binding(get: { draft?[path]?.bool ?? false }, set: { draft?[path] = .bool($0) })
    }

    private func text(_ path: String) -> Binding<String> {
        Binding(get: { draft?[path]?.string ?? "" }, set: { draft?[path] = .string($0) })
    }

    private func number(_ path: String) -> Binding<Double> {
        Binding(get: { draft?[path]?.number ?? 0 }, set: { draft?[path] = .number($0) })
    }

    private func element(_ list: String, _ index: Int, _ update: (inout JSON) -> Void) {
        guard var items = draft?[list]?.array, items.indices.contains(index) else { return }
        update(&items[index])
        draft?[list] = .array(items)
    }

    private func assignmentBool(_ index: Int, _ key: String) -> Binding<Bool> {
        Binding(get: { draft?["root_assignments"]?.array?[index][key]?.bool ?? false },
                set: { value in element("root_assignments", index) { $0[key] = .bool(value) } })
    }

    private func assignmentText(_ index: Int, _ key: String) -> Binding<String> {
        Binding(get: { draft?["root_assignments"]?.array?[index][key]?.string ?? "" },
                set: { value in element("root_assignments", index) { $0[key] = value.isEmpty ? .null : .string(value) } })
    }

    private func profileBinding(_ index: Int) -> Binding<JSON> {
        Binding(get: { draft?["profiles"]?.array?[index] ?? .null },
                set: { value in element("profiles", index) { $0 = value } })
    }

    private func scripts(_ key: String) -> Binding<[JSON]> {
        Binding(get: { draft?[key]?.array ?? [] }, set: { draft?[key] = .array($0) })
    }

    // MARK: Enregistrement

    /// Le document tel que le serveur l'attend en retour, sans sa révision ni les champs en lecture seule.
    private var settings: JSON {
        var document = draft ?? .null
        if case var .object(fields) = document {
            for key in ["settings_revision", "managed_fields", "recycle_bin_warning", "settings_unreadable"] { fields[key] = nil }
            document = .object(fields)
        }
        return document
    }

    private func load() async {
        draft = try? await client.json("GET", "/settings/library-management")
        library = try? await client.json("GET", "/settings/library")
        // Chaque dossier de la discothèque a sa ligne, même sans réglage enregistré.
        var assignments = draft?["root_assignments"]?.array ?? []
        let known = Set(assignments.compactMap { $0["root_id"]?.string })
        for root in library?["library_roots"]?.array ?? [] {
            guard let id = root["id"]?.string, !known.contains(id) else { continue }
            assignments.append(.object([
                "root_id": .string(id), "profile_id": .null, "overrides": .null, "enabled": .bool(false),
                "automatic_acquisitions": .bool(false), "automatic_drop_imports": .bool(false),
                "automatic_scan_discovered": .bool(false), "automatic_custom_editions": .bool(false),
            ]))
        }
        if draft != nil { draft?["root_assignments"] = .array(assignments) }
        original = draft
        health = try? await client.json("GET", "/settings/library-management/activation-health")
    }

    private func save() {
        saving = true
        let revision = original?["settings_revision"] ?? .null
        let body = JSON.object(["settings": settings, "expected_settings_revision": revision])
        Task {
            defer { saving = false }
            do {
                _ = try await client.json("POST", "/settings/library-management/validate", body: body)
                let impact = try await client.json("POST", "/settings/library-management/impact", body: body)
                if impact["stale"]?.bool == true {
                    alert = ServerAlert(title: "Réglages modifiés ailleurs", message: "Recharge et recommence.")
                    return await load()
                }
                let affected = (impact["affected_root_ids"]?.array ?? []).compactMap(\.string)
                let active = Set((draft?["root_assignments"]?.array ?? []).filter {
                    $0["enabled"]?.bool == true && ($0["automatic_acquisitions"]?.bool == true || $0["automatic_drop_imports"]?.bool == true
                        || $0["automatic_scan_discovered"]?.bool == true)
                }.compactMap { $0["root_id"]?.string })
                let needs = affected.filter(active.contains)
                if impact["preview_required"]?.bool == true, !needs.isEmpty {
                    wizard = ActivationRequest(settings: settings, revision: revision,
                                               policy: library?["policy_revision"] ?? .null,
                                               roots: needs.map { ($0, rootLabel($0)) })
                } else {
                    _ = try await client.json("PUT", "/settings/library-management", body: body)
                    alert = ServerAlert(title: "Configuration enregistrée", message: "")
                    await load()
                }
            } catch {
                alert = ServerAlert(title: "Configuration refusée", message: error.localizedDescription)
            }
        }
    }

    private func copy(_ profile: JSON) {
        guard let id = profile["id"]?.string else { return }
        Task {
            do {
                _ = try await client.json("POST", "/settings/library-management/profiles/\(id)/copy", body: .object([
                    "name": .string(copyName), "expected_settings_revision": original?["settings_revision"] ?? .null,
                ]))
                await load()
            } catch {
                alert = ServerAlert(title: "Copie impossible", message: error.localizedDescription)
            }
        }
    }

    private func delete(_ profile: JSON) {
        guard let id = profile["id"]?.string else { return }
        Task {
            do {
                _ = try await client.json("DELETE", "/settings/library-management/profiles/\(id)",
                                          body: .object(["expected_settings_revision": original?["settings_revision"] ?? .null]))
                await load()
            } catch {
                alert = ServerAlert(title: "Suppression impossible", message: error.localizedDescription)
            }
        }
    }

    private func share(_ profile: JSON) {
        guard let id = profile["id"]?.string else { return }
        Task {
            do {
                let export = try await client.json("POST", "/settings/library-management/profiles/\(id)/export",
                                                   body: .object(["expected_settings_revision": original?["settings_revision"] ?? .null]))
                UIPasteboard.general.string = export["share_code"]?.string
                alert = ServerAlert(title: "Code copié",
                                    message: "Colle-le dans « Importer un profil » sur un autre serveur.\nEmpreinte : \(export["bundle_hash"]?.string?.prefix(16) ?? "")…")
            } catch {
                alert = ServerAlert(title: "Partage impossible", message: error.localizedDescription)
            }
        }
    }

    private func purgeImpact() {
        Task {
            do {
                let impact = try await client.json("POST", "/library/management/baselines/purge-impact")
                if (impact["blocked_journal_count"]?.int ?? 0) + (impact["active_restore_count"]?.int ?? 0) > 0 {
                    alert = ServerAlert(title: "Purge bloquée", message: "Une récupération ou une restauration est en cours.")
                } else {
                    purgeText = ""
                    purging = impact
                }
            } catch {
                alert = ServerAlert(title: "Purge impossible", message: error.localizedDescription)
            }
        }
    }

    private func purge() {
        guard let impact = purging, purgeText == confirmationPhrase else {
            purging = nil
            alert = ServerAlert(title: "Rien n'a été purgé", message: "Tape exactement \(confirmationPhrase).")
            return
        }
        purging = nil
        Task {
            do {
                let result = try await client.json("POST", "/library/management/baselines/purge", body: .object([
                    "impact_token": impact["impact_token"] ?? .null,
                    "typed_confirmation": .string(confirmationPhrase), "idempotency_key": .string(UUID().uuidString.lowercased()),
                ]))
                alert = ServerAlert(title: "États d'origine purgés", message: "\(result["purged_baseline_count"]?.int ?? 0) supprimé(s).")
            } catch {
                alert = ServerAlert(title: "Purge refusée", message: error.localizedDescription)
            }
        }
    }
}

// MARK: Profil

/// Les réglages principaux d'un profil ; le reste du document est conservé tel quel.
private struct ProfileEditor: View {
    @Binding var profile: JSON
    let namingScripts: [JSON]

    var body: some View {
        Form {
            Section {
                TextField("Nom", text: text("name"))
                TextField("Description", text: text("description"), axis: .vertical)
            }
            .settingsRow()
            Section("Étiquettes") {
                Toggle("Écrire les métadonnées", isOn: bool("metadata.enabled"))
                Toggle("Effacer les étiquettes non gérées", isOn: bool("metadata.scrub_unmanaged_tags"))
                Picker("Crédits d'artiste", selection: text("metadata.artist_credits.standardization")) {
                    Text("Tels que crédités").tag("credited")
                    Text("Nom canonique").tag("canonical")
                }
            }
            .settingsRow()
            Section("Genres") {
                Toggle("Écrire les genres", isOn: bool("genres.enabled"))
                Picker("Mode", selection: text("genres.mode")) {
                    Text("Remplacer").tag("replace")
                    Text("Fusionner").tag("merge")
                    Text("Compléter").tag("fill_missing")
                }
                Stepper("Au plus \(Int(number("genres.maximum_count").wrappedValue)) genres", value: number("genres.maximum_count"), in: 1 ... 20)
            }
            .settingsRow()
            Section("Pochettes") {
                Toggle("Pochette intégrée", isOn: bool("artwork.embedded_enabled"))
                Toggle("Pochette externe (fichier)", isOn: bool("artwork.external_enabled"))
                Toggle("Pochette de l'édition choisie", isOn: bool("artwork.use_edition_cover"))
                Toggle("Jamais remplacer par une plus petite", isOn: bool("artwork.never_replace_with_smaller"))
            }
            .settingsRow()
            Section("Rangement") {
                Toggle("Renommer les fichiers", isOn: bool("organization.rename_enabled"))
                Toggle("Déplacer dans le dossier", isOn: bool("organization.move_enabled"))
                Picker("Script de nommage", selection: text("organization.naming_script_id")) {
                    ForEach(namingScripts.indices, id: \.self) { index in
                        Text(namingScripts[index]["name"]?.string ?? "").tag(namingScripts[index]["id"]?.string ?? "")
                    }
                }
                Toggle("Déplacer les fichiers annexes", isOn: bool("organization.move_sidecars"))
            }
            .settingsRow()
            Section("Enrichissement") {
                Toggle("Paroles (LRCLIB)", isOn: bool("enrichment.lyrics.enabled"))
                Toggle("ReplayGain", isOn: bool("enrichment.replaygain.enabled"))
                Toggle("Accepter seul les éditions sûres", isOn: bool("identity.automatic_edition_acceptance_enabled"))
                Toggle("Prévenir les serveurs externes", isOn: bool("notification.refresh_external_servers"))
            }
            .settingsRow()
        }
        .settingsStyle()
        .navigationTitle(profile["name"]?.string ?? "Profil")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func bool(_ path: String) -> Binding<Bool> {
        Binding(get: { profile[path]?.bool ?? false }, set: { profile[path] = .bool($0) })
    }

    private func text(_ path: String) -> Binding<String> {
        Binding(get: { profile[path]?.string ?? "" }, set: { profile[path] = .string($0) })
    }

    private func number(_ path: String) -> Binding<Double> {
        Binding(get: { profile[path]?.number ?? 0 }, set: { profile[path] = .number($0) })
    }
}

// MARK: Scripts

/// Les scripts de nommage (une ligne) ou d'étiquetage (plusieurs), validés par
/// le serveur à l'enregistrement.
private struct ScriptsEditor: View {
    enum Kind { case naming, tagging }

    @Binding var scripts: [JSON]
    let kind: Kind

    var body: some View {
        List {
            ForEach(scripts.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Nom", text: field(index, "name")).font(.headline)
                    TextEditor(text: field(index, "source"))
                        .font(.callout.monospaced())
                        .frame(minHeight: kind == .naming ? 60 : 120)
                        .scrollContentBackground(.hidden)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if kind == .naming, !balanced(scripts[index]["source"]?.string ?? "") {
                        Text("Accolades déséquilibrées").font(.caption).foregroundStyle(.yellow)
                    }
                }
                .settingsRow()
            }
            .onDelete { scripts.remove(atOffsets: $0) }
            Button("Nouveau script", systemImage: "plus") {
                scripts.append(.object([
                    "id": .string(UUID().uuidString.lowercased()), "name": .string("Nouveau script"), "revision": .string(""),
                    "source": .string(kind == .naming
                        ? #"{albumartist}/{album}{conditional(is_empty(year), "", concat(" (", year, ")"))}/{track:02d} - {title}.{ext}"#
                        : "set title = title(title)"),
                ]))
            }
            .settingsRow()
        }
        .settingsStyle()
        .navigationTitle(kind == .naming ? "Nommage" : "Étiquetage")
    }

    private func field(_ index: Int, _ key: String) -> Binding<String> {
        Binding(get: { scripts[index][key]?.string ?? "" }, set: { scripts[index][key] = .string($0) })
    }

    private func balanced(_ source: String) -> Bool {
        var depth = 0
        for character in source {
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            if depth < 0 { return false }
        }
        return depth == 0
    }
}

// MARK: Import

private struct ProfileImportSheet: View {
    let revision: JSON
    let done: () async -> Void

    @Environment(\.client) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var preview: JSON?
    @State private var name = ""
    @State private var alert: ServerAlert?

    var body: some View {
        NavigationStack {
            Form {
                Section("Code du profil") {
                    TextEditor(text: $code).font(.callout.monospaced()).frame(minHeight: 100)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Coller", systemImage: "doc.on.clipboard") { code = UIPasteboard.general.string ?? code }
                    Button("Relire", systemImage: "eye") { review() }.disabled(code.isEmpty)
                }
                .settingsRow()
                if let preview {
                    Section("Profil importé") {
                        TextField("Nom", text: $name)
                        ForEach((preview["warnings"]?.array ?? []).indices, id: \.self) { index in
                            let warning = preview["warnings"]?.array?[index]
                            Label(warning?["message"]?.string ?? "", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(warning?["severity"]?.string == "danger" ? Color.red : .yellow)
                        }
                    }
                    .settingsRow()
                }
            }
            .settingsStyle()
            .navigationTitle("Importer un profil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Importer") { confirm() }.disabled(preview == nil || name.isEmpty) }
            }
            .serverAlert($alert)
        }
    }

    private func review() {
        Task {
            do {
                preview = try await client.json("POST", "/settings/library-management/profile-imports/preview",
                                                body: .object(["content": .string(code), "expected_settings_revision": revision]))
                name = preview?["profile"]?["name"]?.string ?? ""
            } catch {
                alert = ServerAlert(title: "Code invalide", message: error.localizedDescription)
            }
        }
    }

    private func confirm() {
        Task {
            do {
                _ = try await client.json("POST", "/settings/library-management/profile-imports", body: .object([
                    "content": .string(code), "reviewed_bundle_hash": preview?["bundle_hash"] ?? .null, "name": .string(name),
                    "expected_settings_revision": preview?["settings_revision"] ?? revision,
                ]))
                await done()
                dismiss()
            } catch {
                alert = ServerAlert(title: "Import refusé", message: error.localizedDescription)
            }
        }
    }
}

// MARK: Activation

struct ActivationRequest: Identifiable {
    let settings: JSON
    let revision: JSON
    let policy: JSON
    let roots: [(id: String, label: String)]
    let id = UUID()
}

/// L'assistant d'activation : un essai à blanc à jour pour chaque dossier
/// concerné, puis la phrase exacte. Rien n'est activé avant.
private struct ActivationWizard: View {
    let request: ActivationRequest
    let done: () async -> Void

    @Environment(\.client) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var runs: [String: JSON] = [:]
    @State private var tokens: [String: String] = [:]
    @State private var proofs: [String: JSON] = [:]
    @State private var typed = ""
    @State private var alert: ServerAlert?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Rien n'est activé tant qu'un essai à blanc à jour n'existe pas pour chaque dossier concerné et que tu n'as pas tapé la phrase exacte.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .settingsRow()
                ForEach(request.roots, id: \.id) { root in
                    Section(root.label) { step(root.id) }.settingsRow()
                }
                Section {
                    Text("Le rangement automatique écrira les étiquettes et pourra déplacer des fichiers selon les profils prévisualisés.")
                        .font(.callout).foregroundStyle(.yellow)
                    TextField("Tape \(confirmationPhrase)", text: $typed).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Button("Activer le rangement") { activate() }
                        .disabled(typed != confirmationPhrase || proofs.count != request.roots.count)
                }
                .settingsRow()
            }
            .settingsStyle()
            .navigationTitle("Activer le rangement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } } }
            .serverAlert($alert)
            .task {
                while !Task.isCancelled {
                    for (root, run) in runs where proofs[root] == nil {
                        if let id = run["job_id"]?.string ?? run["id"]?.string,
                           let fresh = try? await client.json("GET", "/settings/library-management/activation-previews/\(id)") {
                            runs[root] = fresh
                        }
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    @ViewBuilder
    private func step(_ root: String) -> some View {
        if proofs[root] != nil {
            Label("Essai à blanc retenu", systemImage: "checkmark.seal.fill").foregroundStyle(Color.sage)
        } else if let run = runs[root] {
            let summary = run["summary"]
            if run["ready_for_confirmation"]?.bool == true {
                LabeledContent("Prêts", value: summary?["eligible_count"]?.display ?? "0")
                LabeledContent("Avertis", value: summary?["warning_count"]?.display ?? "0")
                LabeledContent("Bloqués", value: summary?["blocked_count"]?.display ?? "0")
                LabeledContent("Déplacements", value: summary?["path_change_count"]?.display ?? "0")
                Button("Retenir cet essai") { prove(root, run) }
            } else {
                Label(run["worker_stalled"]?.bool == true ? "Essai interrompu" : "Essai à blanc en cours…", systemImage: "hourglass")
                Button("Arrêter l'essai", role: .destructive) {
                    if let id = run["job_id"]?.string {
                        Task { _ = try? await client.json("POST", "/library/operations/\(id)/stop",
                                                          body: .object(["expected_row_revision": run["operation_row_revision"] ?? .null])) }
                    }
                }
            }
        } else {
            Button("Lancer l'essai à blanc") { start(root) }
        }
    }

    private func start(_ root: String) {
        Task {
            do {
                let created = try await client.json("POST", "/settings/library-management/activation-previews", body: .object([
                    "root_id": .string(root), "settings": request.settings, "expected_settings_revision": request.revision,
                    "expected_policy_revision": request.policy, "idempotency_key": .string(UUID().uuidString.lowercased()),
                ]))
                tokens[root] = created["preview_token"]?.string
                runs[root] = created
            } catch {
                alert = ServerAlert(title: "Essai impossible", message: error.localizedDescription)
            }
        }
    }

    private func prove(_ root: String, _ run: JSON) {
        guard let id = run["job_id"]?.string, let token = tokens[root],
              run["stale"]?.bool != true, run["expired"]?.bool != true else {
            alert = ServerAlert(title: "Essai périmé", message: "Relance un essai à blanc.")
            runs[root] = nil
            return
        }
        proofs[root] = .object(["root_id": .string(root), "job_id": .string(id), "preview_token": .string(token)])
    }

    private func activate() {
        Task {
            do {
                _ = try await client.json("POST", "/settings/library-management/activation-confirmations", body: .object([
                    "settings": request.settings, "proofs": .array(Array(proofs.values)),
                    "expected_settings_revision": request.revision, "confirmation": .bool(true),
                ]))
                await done()
                dismiss()
            } catch {
                alert = ServerAlert(title: "Activation refusée", message: error.localizedDescription)
            }
        }
    }
}
