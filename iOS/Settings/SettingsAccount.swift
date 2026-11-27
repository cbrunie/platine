import SwiftUI

// MARK: Utilisateurs

/// Les comptes du serveur : créer, changer de rôle, quotas, code de récupération, supprimer, importer.
struct UsersView: View {
    @Environment(\.client) private var client
    @State private var users: [JSON] = []
    @State private var total = 0
    @State private var creating = false
    @State private var importing: String?
    @State private var alert: ServerAlert?

    var body: some View {
        List {
            Section {
                ForEach(users.indices, id: \.self) { index in
                    NavigationLink { UserView(user: users[index]) { await load() } } label: {
                        HStack(spacing: 12) {
                            Cover(path: users[index]["avatar_url"]?.string, size: 36, radius: 18)
                            VStack(alignment: .leading) {
                                Text(users[index]["display_name"]?.string ?? "")
                                Text("@\(users[index]["username"]?.string ?? "")").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(UserView.roleName(users[index]["role"]?.string ?? "")).font(.caption).foregroundStyle(Color.sky)
                        }
                    }
                }
            } header: {
                Text("^[\(total) compte](inflect: true)")
            }
            .settingsRow()
            Section {
                Button("Importer depuis Jellyfin", systemImage: "person.badge.plus") { importing = "jellyfin" }
                Button("Importer depuis Plex", systemImage: "person.badge.plus") { importing = "plex" }
            }
            .settingsRow()
        }
        .settingsStyle()
        .navigationTitle("Utilisateurs")
        .toolbar { Button("Nouveau", systemImage: "plus") { creating = true } }
        .sheet(isPresented: $creating) { NewUserView { await load() } }
        .sheet(item: Binding(get: { importing.map { IdentifiedJSON(value: .string($0)) } }, set: { importing = $0?.value.string })) {
            ImportUsersView(provider: $0.value.string ?? "") { await load() }
        }
        .serverAlert($alert)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            let page = try await client.json("GET", "/admin/users?limit=500&offset=0")
            users = page["users"]?.array ?? []
            total = page["total"]?.int ?? users.count
        } catch {
            alert = ServerAlert(title: "Utilisateurs", message: error.localizedDescription)
        }
    }
}

private struct UserView: View {
    let user: JSON
    let changed: () async -> Void

    @Environment(\.client) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var role = "user"
    @State private var quota: JSON?
    @State private var deleting = false
    @State private var alert: ServerAlert?

    private var id: String { user["id"]?.string ?? "" }

    static func roleName(_ role: String) -> String {
        switch role {
        case "admin": "Admin"
        case "trusted": "De confiance"
        default: "Auditeur"
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Nom", value: user["display_name"]?.string ?? "")
                LabeledContent("Identifiant", value: user["username"]?.string ?? "")
                if let email = user["email"]?.string { LabeledContent("E-mail", value: email) }
                Picker("Rôle", selection: Binding(get: { role }, set: setRole)) {
                    Text("Auditeur").tag("user")
                    Text("De confiance").tag("trusted")
                    Text("Admin").tag("admin")
                }
            }
            .settingsRow()

            if let quota {
                Section {
                    quotaField("Demandes max", "request_quota_count", effective: quota["effective_request_quota_count"])
                    quotaField("Sur (jours)", "request_quota_days", effective: quota["effective_request_quota_days"])
                    quotaField("Stockage max (Go)", "storage_quota_gb", effective: quota["effective_storage_quota_gb"])
                    LabeledContent("Demandes récentes", value: quota["requests_in_window"]?.display ?? "—")
                    Button("Enregistrer les quotas") { saveQuota() }
                } header: {
                    Text("Quotas")
                } footer: {
                    Text(quota["exempt"]?.bool == true ? "Ce compte n'a pas de quota." : "Vide : valeur par défaut du serveur. 0 : illimité.")
                }
                .settingsRow()
            }

            Section {
                Button("Créer un code de récupération", systemImage: "key") { recovery() }
                Button("Supprimer le compte", role: .destructive) { deleting = true }
            }
            .settingsRow()
        }
        .settingsStyle()
        .navigationTitle(user["display_name"]?.string ?? "")
        .confirmationDialog("Supprimer ce compte ?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) { delete() }
        }
        .serverAlert($alert)
        .task {
            role = user["role"]?.string ?? "user"
            quota = try? await client.json("GET", "/admin/users/\(id)/quota")
        }
    }

    private func quotaField(_ label: String, _ key: String, effective: JSON?) -> some View {
        LabeledContent(label) {
            TextField(effective?.display ?? "", text: Binding(
                get: { quota?["quota_override"]?[key]?.int.map(String.init) ?? "" },
                set: { quota?["quota_override.\(key)"] = Int($0).map { .number(Double($0)) } ?? .null }
            ))
            .multilineTextAlignment(.trailing)
            .keyboardType(.numberPad)
        }
    }

    private func setRole(_ newRole: String) {
        let old = role
        role = newRole
        Task {
            do {
                _ = try await client.json("PUT", "/admin/users/\(id)/role", body: .object(["role": .string(newRole)]))
                await changed()
            } catch {
                role = old
                alert = ServerAlert(title: "Rôle inchangé", message: error.localizedDescription)
            }
        }
    }

    private func saveQuota() {
        Task {
            do {
                quota = try await client.json("PUT", "/admin/users/\(id)/quota", body: quota?["quota_override"] ?? .object([:]))
                alert = ServerAlert(title: "Quotas enregistrés", message: "")
            } catch {
                alert = ServerAlert(title: "Quotas non enregistrés", message: error.localizedDescription)
            }
        }
    }

    private func recovery() {
        Task {
            do {
                let code = try await client.json("POST", "/admin/users/\(id)/recovery-code")
                UIPasteboard.general.string = code["recovery_code"]?.string
                alert = ServerAlert(title: "Code de récupération",
                                    message: "\(code["recovery_code"]?.string ?? "")\n\nCopié. Valable 15 minutes, une seule fois.")
            } catch {
                alert = ServerAlert(title: "Code impossible", message: error.localizedDescription)
            }
        }
    }

    private func delete() {
        Task {
            do {
                _ = try await client.json("DELETE", "/admin/users/\(id)")
                await changed()
                dismiss()
            } catch {
                alert = ServerAlert(title: "Suppression impossible", message: error.localizedDescription)
            }
        }
    }
}

private struct NewUserView: View {
    let created: () async -> Void

    @Environment(\.client) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var role = "user"
    @State private var alert: ServerAlert?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nom affiché", text: $name)
                    TextField("Identifiant", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("E-mail (facultatif)", text: $email).textInputAutocapitalization(.never).keyboardType(.emailAddress)
                    SecureField("Mot de passe (12 caractères min.)", text: $password)
                    Picker("Rôle", selection: $role) {
                        Text("Auditeur").tag("user")
                        Text("De confiance").tag("trusted")
                        Text("Admin").tag("admin")
                    }
                }
                .settingsRow()
            }
            .settingsStyle()
            .navigationTitle("Nouveau compte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Créer") { create() }.disabled(name.isEmpty || username.isEmpty || password.count < 12)
                }
            }
            .serverAlert($alert)
        }
    }

    private func create() {
        Task {
            do {
                _ = try await client.json("POST", "/admin/users", body: .object([
                    "display_name": .string(name), "username": .string(username), "password": .string(password),
                    "role": .string(role), "email": email.isEmpty ? .null : .string(email),
                ]))
                await created()
                dismiss()
            } catch {
                alert = ServerAlert(title: "Création impossible", message: error.localizedDescription)
            }
        }
    }
}

private struct ImportUsersView: View {
    let provider: String
    let imported: () async -> Void

    @Environment(\.client) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [JSON] = []
    @State private var selected: Set<String> = []
    @State private var alert: ServerAlert?

    var body: some View {
        NavigationStack {
            List(candidates.indices, id: \.self) { index in
                let candidate = candidates[index]
                let uid = candidate["provider_uid"]?.string ?? ""
                let done = candidate["already_imported"]?.bool == true
                Button {
                    if selected.contains(uid) { selected.remove(uid) } else { selected.insert(uid) }
                } label: {
                    HStack {
                        Text(candidate["display_name"]?.string ?? uid).foregroundStyle(done ? .secondary : .primary)
                        Spacer()
                        if done { Text("Déjà importé").font(.caption).foregroundStyle(.secondary) }
                        else if selected.contains(uid) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.sage) }
                    }
                }
                .disabled(done)
                .settingsRow()
            }
            .settingsStyle()
            .navigationTitle("Importer depuis \(Service.name(provider))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Importer") { run() }.disabled(selected.isEmpty) }
            }
            .serverAlert($alert)
            .task { candidates = (try? await client.json("GET", "/admin/import/\(provider)"))?["candidates"]?.array ?? [] }
        }
    }

    private func run() {
        Task {
            do {
                _ = try await client.json("POST", "/admin/import", body: .object([
                    "provider": .string(provider), "provider_uids": .array(selected.map(JSON.string)),
                ]))
                await imported()
                dismiss()
            } catch {
                alert = ServerAlert(title: "Import impossible", message: error.localizedDescription)
            }
        }
    }
}

extension JSON {
    /// Une date du serveur (secondes depuis 1970), en clair.
    var epochDate: String? {
        number.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted) }
    }
}

// MARK: Applis connectées

/// L'API Subsonic / Jellyfin du serveur et les mots de passe d'application
/// qui permettent aux autres applis de s'y brancher.
struct ConnectAppsView: View {
    @Environment(\.client) private var client
    @Environment(Session.self) private var session
    @State private var mine: [JSON] = []
    @State private var everyone: [JSON] = []
    /// Les playlists publiques des autres, montrées ou non dans mes applis.
    @State private var publicPlaylists: Bool?
    @State private var newName = ""
    @State private var naming = false
    @State private var alert: ServerAlert?

    var body: some View {
        List {
            Section {
                LabeledContent("Subsonic", value: session.server + "/subsonic")
                LabeledContent("Jellyfin", value: session.server + "/jellyfin")
                if session.isAdmin {
                    NavigationLink("Réglages de l'API") { FormPanel(title: "Applis connectées", spec: .connectApps) }
                }
            } header: {
                Text("Adresses à saisir dans les applis")
            }
            .settingsRow()

            if let publicPlaylists {
                Section {
                    Toggle("Playlists publiques des autres", isOn: Binding(get: { publicPlaylists }, set: setPublicPlaylists))
                } footer: {
                    Text("Sinon, les applis ne listent que tes propres playlists.")
                }
                .settingsRow()
            }

            Section {
                ForEach(mine.indices, id: \.self) { index in password(mine[index], owner: nil) }
                    .onDelete { revoke(mine, $0, admin: false) }
                Button("Créer un mot de passe", systemImage: "plus") { newName = ""; naming = true }
            } header: {
                Text("Mes mots de passe d'application")
            } footer: {
                Text("Chaque appli a le sien ; on le révoque sans toucher aux autres.")
            }
            .settingsRow()

            if session.isAdmin, !everyone.isEmpty {
                Section("Tous les comptes") {
                    ForEach(everyone.indices, id: \.self) { index in
                        password(everyone[index], owner: everyone[index]["owner_display_name"]?.string)
                    }
                    .onDelete { revoke(everyone, $0, admin: true) }
                }
                .settingsRow()
            }
        }
        .settingsStyle()
        .navigationTitle("Applis connectées")
        .alert("Nom de l'appli", isPresented: $naming) {
            TextField("Symfonium sur mon téléphone", text: $newName)
            Button("Annuler", role: .cancel) {}
            Button("Créer") { create() }
        }
        .serverAlert($alert)
        .task { await load() }
    }

    private func password(_ item: JSON, owner: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item["name"]?.string ?? "")
            Text([owner, item["last_client"]?.string, item["last_used_at"]?.epochDate.map { "utilisé le \($0)" }]
                .compactMap(\.self).joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func load() async {
        mine = (try? await client.json("GET", "/me/app-passwords"))?["app_passwords"]?.array ?? []
        publicPlaylists = (try? await client.json("GET", "/me/connect-apps"))?["include_public_playlists"]?.bool
        if session.isAdmin {
            everyone = (try? await client.json("GET", "/admin/app-passwords"))?["app_passwords"]?.array ?? []
        }
    }

    private func setPublicPlaylists(_ value: Bool) {
        let old = publicPlaylists
        publicPlaylists = value
        Task {
            do {
                _ = try await client.json("PUT", "/me/connect-apps", body: .object(["include_public_playlists": .bool(value)]))
            } catch {
                publicPlaylists = old
                alert = ServerAlert(title: "Non enregistré", message: error.localizedDescription)
            }
        }
    }

    private func create() {
        Task {
            do {
                let created = try await client.json("POST", "/me/app-passwords", body: .object(["name": .string(newName)]))
                UIPasteboard.general.string = created["secret"]?.string
                alert = ServerAlert(title: "Mot de passe créé",
                                    message: "\(created["secret"]?.string ?? "")\n\nCopié. Il ne sera plus jamais affiché.")
                await load()
            } catch {
                alert = ServerAlert(title: "Création impossible", message: error.localizedDescription)
            }
        }
    }

    private func revoke(_ items: [JSON], _ offsets: IndexSet, admin: Bool) {
        let ids = offsets.compactMap { items[$0]["id"]?.string }
        Task {
            for id in ids {
                _ = try? await client.json("DELETE", admin ? "/admin/app-passwords/\(id)" : "/me/app-passwords/\(id)")
            }
            await load()
        }
    }
}

// MARK: Sections de l'accueil et de Découvrir

/// Les rayons qu'on veut voir, enregistrés au fil des bascules.
struct SectionPrefsView: View {
    let page: String
    let title: String

    @Environment(\.client) private var client
    @State private var sections: [JSON] = []
    @State private var alert: ServerAlert?

    var body: some View {
        List {
            let zones = sections.reduce(into: [String]()) { zones, section in
                let zone = section["zone"]?.string ?? ""
                if !zones.contains(zone) { zones.append(zone) }
            }
            ForEach(zones, id: \.self) { zone in
                Section(zone.replacingOccurrences(of: "_", with: " ").capitalized) {
                    ForEach(sections.indices.filter { sections[$0]["zone"]?.string ?? "" == zone }, id: \.self) { index in
                        let section = sections[index]
                        let available = section["available"]?.bool != false
                        Toggle(isOn: Binding(get: { section["enabled"]?.bool ?? true }, set: { set(index, $0) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section["title"]?.string ?? "")
                                if !available, let requires = section["requires"]?.string {
                                    Text("Relie \(Service.name(requires)) pour l'afficher").font(.caption).foregroundStyle(.yellow)
                                } else if let description = section["description"]?.string {
                                    Text(description).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(!available)
                    }
                }
                .settingsRow()
            }
        }
        .settingsStyle()
        .navigationTitle(title)
        .serverAlert($alert)
        .task {
            sections = (try? await client.json("GET", "/me/section-prefs"))?["pages"]?[page]?.array ?? []
        }
    }

    private func set(_ index: Int, _ enabled: Bool) {
        sections[index]["enabled"] = .bool(enabled)
        let body = JSON.object([
            "page": .string(page),
            "sections": .array(sections.map { .object(["key": $0["key"] ?? .null, "enabled": $0["enabled"] ?? .bool(true)]) }),
        ])
        Task {
            do { _ = try await client.json("PUT", "/me/section-prefs", body: body) } catch {
                alert = ServerAlert(title: "Non enregistré", message: error.localizedDescription)
            }
        }
    }
}

// MARK: À propos

struct AboutView: View {
    @Environment(\.client) private var client
    @State private var version: JSON?
    @State private var update: JSON?
    @State private var releases: [JSON] = []

    var body: some View {
        List {
            Section {
                LabeledContent("DroppedNeedle", value: version?["version"]?.string ?? "…")
                if let date = version?["build_date"]?.string { LabeledContent("Pressé le", value: String(date.prefix(10))) }
                if let update {
                    if update["update_available"]?.bool == true {
                        Label("Nouvelle version : \(update["latest_version"]?.string ?? "")", systemImage: "sparkles")
                            .foregroundStyle(Color.sage)
                    } else {
                        Label("À jour", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    }
                }
                Button("Vérifier les mises à jour") { Task { update = try? await client.json("GET", "/version/check-update") } }
            }
            .settingsRow()
            Section("Versions") {
                ForEach(releases.prefix(10).indices, id: \.self) { index in
                    let release = releases[index]
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(release["name"]?.string ?? release["tag_name"]?.string ?? "").font(.headline)
                            if release["prerelease"]?.bool == true { Pill(text: "Préversion", color: .yellow) }
                        }
                        Text(String(release["published_at"]?.string?.prefix(10) ?? "")).font(.caption).foregroundStyle(.secondary)
                        if let body = release["body"]?.string {
                            Text((try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(body))
                                .font(.caption).lineLimit(6)
                        }
                    }
                }
            }
            .settingsRow()
        }
        .settingsStyle()
        .navigationTitle("À propos")
        .task {
            async let version = try? client.json("GET", "/version")
            async let update = try? client.json("GET", "/version/check-update")
            async let releases = try? client.json("GET", "/version/releases")
            self.version = await version
            self.update = await update
            self.releases = await releases?.array ?? []
        }
    }
}

// MARK: Mot de passe et sessions

/// Le mot de passe du compte, et les appareils qui y sont connectés.
struct AccountSecurityView: View {
    @Environment(\.client) private var client
    @Environment(Session.self) private var session
    @State private var hasPassword = true
    @State private var current = ""
    @State private var new = ""
    @State private var sessions: [JSON] = []
    @State private var alert: ServerAlert?

    var body: some View {
        Form {
            Section {
                if hasPassword { SecureField("Mot de passe actuel", text: $current) }
                SecureField("Nouveau mot de passe (12 caractères min.)", text: $new)
                Button(hasPassword ? "Changer le mot de passe" : "Définir un mot de passe") { changePassword() }
                    .disabled(new.count < 12 || (hasPassword && current.isEmpty))
            } header: {
                Text("Mot de passe")
            }
            .settingsRow()

            Section {
                ForEach(sessions.indices, id: \.self) { index in
                    let item = sessions[index]
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item["label"]?.string ?? "Appareil inconnu")
                            if item["current"]?.bool == true { Pill(text: "Cet appareil", color: .sage) }
                        }
                        Text("\(item["kind"]?.string == "companion" ? "Appli" : "Navigateur") · vu le \(item["last_seen_at"]?.epochDate ?? "—") · expire le \(item["expires_at"]?.epochDate ?? "—")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.compactMap { sessions[$0]["id"]?.string }
                    Task {
                        for id in ids { _ = try? await client.json("DELETE", "/auth/sessions/\(id)") }
                        await load()
                    }
                }
                Button("Déconnecter tous les appareils", role: .destructive) {
                    Task {
                        _ = try? await client.json("POST", "/auth/logout-all")
                        session.logout()
                    }
                }
            } header: {
                Text("Appareils connectés")
            } footer: {
                Text("Glisse une session pour la fermer.")
            }
            .settingsRow()
        }
        .settingsStyle()
        .navigationTitle("Mot de passe et sessions")
        .serverAlert($alert)
        .task { await load() }
    }

    private func load() async {
        let profile = try? await client.json("GET", "/me")
        hasPassword = (profile?["providers"]?.array ?? []).contains(.string("local"))
        sessions = (try? await client.json("GET", "/auth/sessions"))?["sessions"]?.array ?? []
    }

    private func changePassword() {
        Task {
            do {
                if hasPassword {
                    _ = try await client.json("POST", "/me/password", body: .object([
                        "current_password": .string(current), "new_password": .string(new),
                    ]))
                } else {
                    _ = try await client.json("POST", "/me/local-password", body: .object(["new_password": .string(new)]))
                }
                current = ""
                new = ""
                alert = ServerAlert(title: "Mot de passe changé", message: "")
                await load()
            } catch {
                alert = ServerAlert(title: "Mot de passe inchangé", message: error.localizedDescription)
            }
        }
    }
}

// MARK: Services connectés

/// Relier ou délier un service à son compte : jeton ListenBrainz, identifiants
/// Navidrome et Jellyfin, autorisation Last.fm, code Plex, connexion Spotify.
struct ConnectionView: View {
    let service: String

    @Environment(\.client) private var client
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var secret = ""
    @State private var lastfmToken: String?
    @State private var waiting = false
    @State private var alert: ServerAlert?

    var body: some View {
        Form {
            Section {
                switch service {
                case "listenbrainz":
                    TextField("Nom d'utilisateur (facultatif)", text: $username).textInputAutocapitalization(.never)
                    SecureField("Jeton utilisateur", text: $secret)
                    Button("Relier") { put(["user_token": .string(secret), "username": .string(username)]) }
                        .disabled(secret.isEmpty)
                case "navidrome", "jellyfin":
                    TextField("Utilisateur", text: $username).textInputAutocapitalization(.never)
                    SecureField("Mot de passe", text: $secret)
                    Button("Relier") { put(["username": .string(username), "password": .string(secret)]) }
                        .disabled(username.isEmpty || secret.isEmpty)
                case "lastfm":
                    if let lastfmToken {
                        Text("Autorise Platine sur Last.fm, puis reviens ici.")
                        Button("J'ai autorisé, terminer") { finishLastfm(lastfmToken) }
                    } else {
                        Button("Autoriser sur Last.fm") { startLastfm() }
                    }
                case "plex":
                    Button(waiting ? "En attente de Plex…" : "Se connecter avec Plex") { linkPlex() }.disabled(waiting)
                case "spotify":
                    Button("Se connecter avec Spotify") { linkSpotify() }
                    Text("Spotify s'ouvre dans Safari ; reviens ici une fois connecté.").font(.caption).foregroundStyle(.secondary)
                default:
                    Text("Ce service se relie depuis son propre serveur.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Relier \(Service.name(service))")
            }
            .settingsRow()

            Section {
                Button("Délier \(Service.name(service))", role: .destructive) { disconnect() }
            }
            .settingsRow()
        }
        .settingsStyle()
        .navigationTitle(Service.name(service))
        .serverAlert($alert)
    }

    /// Les serveurs multimédias se relient par leur propre route ; les services d'écoute par le compte.
    private var path: String {
        ["navidrome", "jellyfin", "plex"].contains(service) ? "/remotes/\(service)/connection" : "/me/connections/\(service)"
    }

    private func put(_ body: [String: JSON]) {
        Task {
            do {
                _ = try await client.json("PUT", path, body: .object(body))
                dismiss()
            } catch {
                alert = ServerAlert(title: "Liaison impossible", message: error.localizedDescription)
            }
        }
    }

    private func startLastfm() {
        Task {
            do {
                let start = try await client.json("POST", "/me/connections/lastfm/token")
                lastfmToken = start["token"]?.string
                if let url = start["auth_url"]?.string.flatMap(URL.init(string:)) { openURL(url) }
            } catch {
                alert = ServerAlert(title: "Last.fm", message: error.localizedDescription)
            }
        }
    }

    private func finishLastfm(_ token: String) {
        Task {
            do {
                let result = try await client.json("POST", "/me/connections/lastfm/session", body: .object(["token": .string(token)]))
                if result["linked"]?.bool == true { dismiss() } else {
                    alert = ServerAlert(title: "Last.fm", message: FormPanel.summary(of: result))
                }
            } catch {
                alert = ServerAlert(title: "Last.fm", message: error.localizedDescription)
            }
        }
    }

    /// Le code Plex : on ouvre la page d'autorisation, puis on attend sa réponse.
    private func linkPlex() {
        waiting = true
        Task {
            defer { waiting = false }
            do {
                let pin = try await client.json("POST", "/auth/plex/start/link")
                guard let id = pin["pin_id"], let secret = pin["pin_secret"] else { return }
                if let url = pin["authorize_url"]?.string.flatMap(URL.init(string:)) { openURL(url) }
                for _ in 0 ..< 60 {
                    try await Task.sleep(for: .seconds(3))
                    // Plex freine parfois : un refus passager compte comme « pas encore ».
                    guard let poll = try? await client.json("POST", "/auth/plex/poll/link",
                                                            body: .object(["pin_id": id, "pin_secret": secret])) else { continue }
                    if poll["completed"]?.bool == true { return dismiss() }
                }
                alert = ServerAlert(title: "Plex", message: "Le délai d'autorisation est dépassé.")
            } catch {
                alert = ServerAlert(title: "Plex", message: error.localizedDescription)
            }
        }
    }

    /// Spotify revient sur la page profil du serveur, qui enregistre la liaison ;
    /// le compte la voit au retour dans l'app.
    private func linkSpotify() {
        Task {
            do {
                let start = try await client.json("GET", "/acquire/spotify/auth/url")
                if let url = start["auth_url"]?.string.flatMap(URL.init(string:)) { openURL(url) }
            } catch {
                alert = ServerAlert(title: "Spotify", message: error.localizedDescription)
            }
        }
    }

    private func disconnect() {
        Task {
            do {
                _ = try await client.json("DELETE", path)
                dismiss()
            } catch {
                alert = ServerAlert(title: "Impossible de délier", message: error.localizedDescription)
            }
        }
    }
}
