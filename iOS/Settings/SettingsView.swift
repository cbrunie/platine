import PhotosUI
import SwiftUI

/// Le compte et les réglages, derrière l'avatar comme dans Musique, rangés
/// comme l'app Réglages : un en-tête, puis des cartes à pastilles colorées.
/// Tous les onglets des réglages du web y sont, en natif.
struct SettingsView: View {
    @Environment(\.client) private var client
    @Environment(Session.self) private var session
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented

    @State private var profile: Profile?
    @State private var connections: [Connection] = []
    @State private var preferences: ListeningPreferences?
    @State private var version: String?
    @State private var photo: PhotosPickerItem?
    /// Change après un envoi, pour ne pas montrer l'ancienne photo en cache.
    @State private var avatarVersion = 0
    @State private var uploading = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                header
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())

                Section("Mon compte") {
                    Button { newName = profile?.displayName ?? ""; renaming = true } label: {
                        row("Nom affiché", symbol: "person.text.rectangle", color: .sky.mix(with: .blue, by: 0.4)) {
                            Text(profile?.displayName ?? "…").foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                    if let email = profile?.email {
                        row("E-mail", symbol: "envelope.fill", color: .blue) {
                            Text(email).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    NavigationLink { AccountSecurityView() } label: {
                        row("Mot de passe et sessions", symbol: "key.fill", color: .gray) { EmptyView() }
                    }
                }
                .settingsRow()

                if !connections.isEmpty {
                    Section("Services connectés") {
                        ForEach(connections) { connection in
                            NavigationLink { ConnectionView(service: connection.service) } label: {
                                row(Service.name(connection.service), symbol: Service.symbol(connection.service),
                                    color: Service.color(connection.service), brand: connection.service) {
                                    if connection.enabled {
                                        HStack(spacing: 6) {
                                            Text(connection.username ?? "").foregroundStyle(.secondary)
                                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.sage)
                                        }
                                    } else {
                                        Text("Connecter").foregroundStyle(Color.sage)
                                    }
                                }
                            }
                        }
                    }
                    .settingsRow()
                }

                if preferences != nil { listening }

                ForEach(SettingsTab.Tier.allCases, id: \.self) { tier in
                    let tabs = SettingsTab.all.filter { $0.tier == tier && (session.isAdmin || !$0.adminOnly) }
                    Section(tier.title) {
                        ForEach(tabs) { tab in
                            NavigationLink { tab.destination } label: {
                                row(tab.title, symbol: tab.symbol, color: tab.color, brand: tab.brand) {
                                    if tab.adminOnly { Text("Admin").font(.caption).foregroundStyle(Color.sky) }
                                }
                            }
                        }
                    }
                    .settingsRow()
                }

                Section {
                    Button(role: .destructive) {
                        player.stop()
                        session.logout()
                        dismiss()
                    } label: {
                        Text("Se déconnecter").frame(maxWidth: .infinity)
                    }
                } footer: {
                    Text("Platine \(Bundle.main.marketingVersion) · pressé pour DroppedNeedle \(version ?? "…")\n\(session.server)")
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }
                .settingsRow()
            }
            .listStyle(.insetGrouped)
            .settingsStyle()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Sur Mac et iPad, le compte est une page de la fenêtre : rien à fermer.
                if isPresented {
                    ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
                }
            }
            .alert("Nom affiché", isPresented: $renaming) {
                TextField("Nom affiché", text: $newName)
                Button("Annuler", role: .cancel) {}
                Button("Enregistrer") { rename() }
            }
            .alert("Réglage non enregistré", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
            // Recharger au retour d'un service relié ou d'un nom changé.
            .onAppear { Task { await load() } }
            .refreshable { await load() }
        }
    }

    // MARK: En-tête

    /// Comme la feuille Compte de Musique : l'avatar, le nom, le rôle.
    private var header: some View {
        VStack(spacing: 10) {
            // Le contenu du sélecteur est construit hors de l'acteur principal : on lui passe
            // une vue déjà remplie plutôt que l'état de cette page.
            let badge = AvatarBadge(initials: initials,
                                    avatar: profile?.avatarUrl.flatMap { $0.isEmpty ? nil : $0 },
                                    version: avatarVersion, uploading: uploading)
            PhotosPicker(selection: $photo, matching: .images) { badge }
            .buttonStyle(.plain)
            .accessibilityLabel("Changer la photo de profil")
            .onChange(of: photo) { _, item in if let item { upload(item) } }

            Text(profile?.displayName ?? session.user?.displayName ?? " ")
                .font(.display(26, relativeTo: .title))
            HStack(spacing: 8) {
                if let username = profile?.username { Text("@\(username)").foregroundStyle(.secondary) }
                if let role = session.user?.role {
                    Pill(text: Self.role(role), color: role == "admin" ? .sky : .sage)
                }
            }
            .font(.subheadline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var initials: String {
        let name = profile?.displayName ?? session.user?.displayName ?? "?"
        return String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }

    private static func role(_ role: String) -> String {
        switch role {
        case "admin": "Admin"
        case "trusted": "De confiance"
        default: "Auditeur"
        }
    }

    // MARK: Écoute

    private var listening: some View {
        Section {
            Toggle(isOn: binding(\.scrobbleToListenbrainz)) {
                row("Scrobbler vers ListenBrainz", symbol: "waveform", color: .orange, brand: "listenbrainz") { EmptyView() }
            }
            Toggle(isOn: binding(\.scrobbleToLastfm)) {
                row("Scrobbler vers Last.fm", symbol: "dot.radiowaves.left.and.right", color: .red, brand: "lastfm") { EmptyView() }
            }
            Picker(selection: binding(\.primaryMusicSource)) {
                Text("ListenBrainz").tag("listenbrainz")
                Text("Last.fm").tag("lastfm")
            } label: {
                row("Recommandations", symbol: "sparkles", color: .purple) { EmptyView() }
            }
            Picker(selection: binding(\.nowPlayingVisibility)) {
                Text("Tout").tag("full")
                Text("L'album seul").tag("track_hidden")
                Text("Rien").tag("offline")
            } label: {
                row("Ce que les autres voient", symbol: "eye.fill", color: .teal) { EmptyView() }
            }
        } header: {
            Text("Écoute")
        } footer: {
            Text("Ce que tu poses sur la platine s'affiche aussi sur le web, parmi les sessions en cours.")
        }
        .settingsRow()
        .onChange(of: preferences) { old, new in
            guard let old, let new, old != new else { return }
            Task {
                do { preferences = try await client.update(new) } catch {
                    preferences = old
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func binding<Value>(_ key: WritableKeyPath<ListeningPreferences, Value>) -> Binding<Value> {
        Binding(get: { preferences![keyPath: key] }, set: { preferences?[keyPath: key] = $0 })
    }

    // MARK: Ligne

    /// Une ligne à pastille ; `brand` met le vrai logo du service quand on l'a.
    private func row(_ title: String, symbol: String, color: Color, brand: String? = nil,
                     @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 12) {
            if let brand, let logo = Service.logo(brand) {
                IconTile(logo, color: Service.color(brand))
            } else {
                IconTile(symbol: symbol, color: color)
            }
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 8)
            trailing()
        }
    }

    // MARK: Chargement

    /// La photo est réduite à 512 px en JPEG : le serveur refuse au-delà de 5 Mo.
    private func upload(_ item: PhotosPickerItem) {
        uploading = true
        Task {
            defer { uploading = false; photo = nil }
            do {
                guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
                let side: CGFloat = 512
                let scale = side / max(image.size.width, image.size.height, side)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let jpeg = UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.85) { _ in
                    image.draw(in: CGRect(origin: .zero, size: size))
                }
                // v3 attend l'image en base64 dans un corps JSON, plus en multipart.
                _ = try await client.json("POST", "/me/avatar", body: .object([
                    "content_type": .string("image/jpeg"), "image_base64": .string(jpeg.base64EncodedString()),
                ]))
                profile = try? await client.profile()
                avatarVersion += 1
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func rename() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != profile?.displayName else { return }
        Task {
            do {
                _ = try await client.rename(to: name)
                profile = try? await client.profile()
                await session.refreshUser()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func load() async {
        async let profile = try? client.profile()
        async let connections = try? client.connections()
        async let preferences = try? client.listeningPreferences()
        async let version = try? client.version()
        self.profile = await profile
        self.connections = await connections?.connections ?? []
        self.preferences = await preferences
        self.version = await version?.version
    }
}

/// Les services qu'on relie à son compte, avec leurs couleurs.
enum Service {
    static func name(_ id: String) -> String {
        switch id {
        case "lastfm": "Last.fm"
        case "listenbrainz": "ListenBrainz"
        case "youtube": "YouTube"
        default: id.capitalized
        }
    }

    static func symbol(_ id: String) -> String {
        switch id {
        case "lastfm": "dot.radiowaves.left.and.right"
        case "listenbrainz": "waveform"
        case "spotify": "music.note.list"
        case "plex": "play.fill"
        default: "server.rack"
        }
    }

    /// Le vrai logo du service, s'il est dans le catalogue d'images.
    static func logo(_ id: String) -> IconTile.Glyph? {
        switch id {
        case "jellyfin", "navidrome", "plex", "spotify", "youtube", "listenbrainz", "lidarr", "prowlarr", "sabnzbd", "slskd":
            .logo("logo-\(id)")
        case "lastfm", "musicbrainz":
            .mark("logo-\(id)")
        default:
            nil
        }
    }

    static func color(_ id: String) -> Color {
        switch id {
        case "lastfm": Color(hex: 0xD51007)
        case "musicbrainz": Color(hex: 0xBA478F)
        case "listenbrainz": .orange
        case "spotify": .green
        case "plex": .yellow.mix(with: .orange, by: 0.4)
        case "jellyfin": .purple
        case "navidrome": .blue
        default: .gray
        }
    }
}

/// Les onglets des réglages du web (`frontend/src/routes/settings/+page.svelte`),
/// avec ceux que seuls les admins voient (`settingsTabs.ts`).
struct SettingsTab: Identifiable {
    enum Tier: CaseIterable {
        case setup, personalize, system

        var title: String {
            switch self {
            case .setup: "Configuration"
            case .personalize: "Personnalisation"
            case .system: "Système"
            }
        }
    }

    let id: String
    let title: String
    let symbol: String
    let color: Color
    let tier: Tier
    var adminOnly = false

    /// Le service dont l'onglet porte le logo, s'il y en a un.
    var brand: String? {
        switch id {
        case "jellyfin", "navidrome", "plex", "youtube", "lastfm", "spotify", "musicbrainz": id
        case "lidarr-import": "lidarr"
        case "indexers": "prowlarr"
        default: nil
        }
    }

    static let all: [SettingsTab] = [
        SettingsTab(id: "library", title: "Discothèque", symbol: "music.note.house.fill", color: .sage.mix(with: .green, by: 0.4), tier: .setup),
        SettingsTab(id: "download-client", title: "Client de téléchargement", symbol: "arrow.down.circle.fill", color: .blue, tier: .setup, adminOnly: true),
        SettingsTab(id: "indexers", title: "Indexeurs / Prowlarr", symbol: "magnifyingglass", color: .indigo, tier: .setup, adminOnly: true),
        SettingsTab(id: "lidarr-import", title: "Import Lidarr", symbol: "icloud.and.arrow.down.fill", color: .green, tier: .setup, adminOnly: true),
        SettingsTab(id: "connect-apps", title: "Applis connectées", symbol: "point.3.connected.trianglepath.dotted", color: .mint, tier: .setup),
        SettingsTab(id: "jellyfin", title: "Jellyfin", symbol: "server.rack", color: .purple, tier: .setup),
        SettingsTab(id: "navidrome", title: "Navidrome", symbol: "server.rack", color: .blue, tier: .setup),
        SettingsTab(id: "plex", title: "Plex", symbol: "play.fill", color: .yellow.mix(with: .orange, by: 0.4), tier: .setup),
        SettingsTab(id: "youtube", title: "YouTube", symbol: "play.rectangle.fill", color: .red, tier: .setup),
        SettingsTab(id: "lastfm", title: "Last.fm", symbol: "dot.radiowaves.left.and.right", color: .red, tier: .setup, adminOnly: true),
        SettingsTab(id: "spotify", title: "Spotify", symbol: "music.note.list", color: .green, tier: .setup, adminOnly: true),
        SettingsTab(id: "events", title: "Concerts", symbol: "ticket.fill", color: .pink, tier: .setup, adminOnly: true),
        SettingsTab(id: "get-it", title: "Acheter", symbol: "bag.fill", color: .orange, tier: .setup, adminOnly: true),
        SettingsTab(id: "settings", title: "Types de sorties", symbol: "slider.horizontal.3", color: .gray, tier: .personalize),
        SettingsTab(id: "home", title: "Accueil", symbol: "house.fill", color: .sky.mix(with: .blue, by: 0.4), tier: .personalize),
        SettingsTab(id: "discover", title: "Découvrir", symbol: "safari.fill", color: .blue, tier: .personalize),
        SettingsTab(id: "music-source", title: "Source musicale", symbol: "chart.bar.fill", color: .purple, tier: .personalize),
        SettingsTab(id: "cache", title: "Cache", symbol: "internaldrive.fill", color: .gray, tier: .system),
        SettingsTab(id: "musicbrainz", title: "MusicBrainz", symbol: "globe", color: .brown, tier: .system, adminOnly: true),
        SettingsTab(id: "users", title: "Utilisateurs", symbol: "person.2.fill", color: .blue, tier: .system, adminOnly: true),
        SettingsTab(id: "security", title: "Sécurité", symbol: "checkmark.shield.fill", color: .green, tier: .system, adminOnly: true),
        SettingsTab(id: "plugins", title: "Plugins", symbol: "puzzlepiece.extension.fill", color: .orange, tier: .system, adminOnly: true),
        SettingsTab(id: "wrapped", title: "API Wrapped", symbol: "gift.fill", color: .pink, tier: .system, adminOnly: true),
        SettingsTab(id: "diagnostics", title: "Diagnostics", symbol: "waveform.path.ecg", color: .red, tier: .system, adminOnly: true),
        SettingsTab(id: "advanced", title: "Avancé", symbol: "gearshape.2.fill", color: .gray, tier: .system),
    ]
}

private extension Bundle {
    var marketingVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
}

/// L'avatar de la page Compte : la photo, ou les initiales sur un dégradé sauge.
private nonisolated struct AvatarBadge: View {
    let initials: String
    let avatar: String?
    let version: Int
    let uploading: Bool

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [.sage, .sage.mix(with: .base100, by: 0.6)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(initials).font(.display(34, relativeTo: .largeTitle)).foregroundStyle(Color.base100)
            if let avatar {
                Cover(path: version == 0 ? avatar : "\(avatar)?v=\(version)", size: 96, radius: 48)
            }
            if uploading { ProgressView().tint(.white) }
        }
        .frame(width: 96, height: 96)
        .overlay(Circle().strokeBorder(Color.sage.opacity(0.6), lineWidth: 2).padding(-4))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "camera.fill")
                .font(.caption)
                .padding(7)
                .background(Color.base300, in: .circle)
                .overlay(Circle().strokeBorder(.white.opacity(0.15)))
                .foregroundStyle(Color.sage)
        }
    }
}
