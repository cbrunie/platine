import SwiftUI

/// Chaque onglet des réglages du web, en natif. Les formulaires simples sont
/// décrits ici ; les écrans sur mesure (utilisateurs, indexeurs, cache…)
/// vivent dans leurs propres fichiers.
extension SettingsTab {
    @ViewBuilder
    var destination: some View {
        switch id {
        case "library": LibrarySettingsView()
        case "download-client": DownloadClientsView()
        case "indexers": IndexersView()
        case "lidarr-import": LidarrImportView()
        case "connect-apps": ConnectAppsView()
        case "jellyfin": FormPanel(title: title, spec: .jellyfin)
        case "navidrome": FormPanel(title: title, spec: .navidrome)
        case "plex": FormPanel(title: title, spec: .plex)
        case "youtube": FormPanel(title: title, spec: .youtube)
        case "lastfm": FormPanel(title: title, spec: .lastfm)
        case "spotify": FormPanel(title: title, spec: .spotify)
        case "events": FormPanel(title: title, spec: .events)
        case "get-it": FormPanel(title: title, spec: .getIt)
        case "settings": FormPanel(title: title, spec: .releaseTypes)
        case "home": SectionPrefsView(page: "home", title: title)
        case "discover": SectionPrefsView(page: "discover", title: title)
        case "music-source": MusicSourceView()
        case "cache": CacheView()
        case "musicbrainz": MusicBrainzView()
        case "users": UsersView()
        case "security": SecurityView()
        case "plugins": PluginsView()
        case "wrapped": FormPanel(title: title, spec: .wrapped)
        case "diagnostics": DiagnosticsView()
        case "advanced": FormPanel(title: title, spec: .advanced)
        default: AboutView()
        }
    }
}

// MARK: Formulaires simples

extension FormSpec {
    static let jellyfin = FormSpec(
        load: "/settings/jellyfin", save: "/settings/jellyfin",
        sections: [
            FormSection(title: "Connexion", fields: [
                Field(key: "jellyfin_url", label: "Adresse", kind: .url, help: "Par exemple http://jellyfin:8096"),
                Field(key: "api_key", label: "Clé d'API", kind: .secret, help: "Tableau de bord › Clés d'API › Créer"),
                Field(key: "user_id", label: "Identifiant utilisateur", help: "Rempli par la vérification si vide."),
            ]),
            FormSection(fields: [
                Field(key: "enabled", label: "Activer Jellyfin", kind: .toggle),
                Field(key: "login_enabled", label: "Se connecter avec Jellyfin", kind: .toggle),
            ], footer: "Vérifie la connexion avant d'activer."),
        ],
        actions: [FormAction(title: "Vérifier la connexion", symbol: "checkmark.seal", method: "POST",
                             path: "/settings/jellyfin/verify", sendsForm: true)]
    )

    static let navidrome = FormSpec(
        load: "/settings/navidrome", save: "/settings/navidrome",
        sections: [
            FormSection(title: "Connexion", fields: [
                Field(key: "navidrome_url", label: "Adresse", kind: .url),
                Field(key: "username", label: "Utilisateur"),
                Field(key: "password", label: "Mot de passe", kind: .secret),
                Field(key: "enabled", label: "Activer Navidrome", kind: .toggle),
            ]),
            FormSection(title: "Playlists", fields: [
                Field(key: "playlist_sync_enabled", label: "Exporter les playlists vers Navidrome", kind: .toggle),
                Field(key: "playlist_sync_path", label: "Dossier des playlists",
                      help: "Chemin absolu dans le conteneur, dans l'arborescence que Navidrome analyse."),
                Field(key: "playlist_sync_scope", label: "Lesquelles",
                      kind: .choice([("public", "Publiques seulement"), ("all", "Toutes")])),
                Field(key: "playlist_sync_remove_deleted", label: "Retirer celles qu'on supprime", kind: .toggle),
            ], footer: "Les playlists exportées sont visibles par tous les utilisateurs de Navidrome. Enregistre avant de synchroniser."),
        ],
        actions: [
            FormAction(title: "Vérifier la connexion", symbol: "checkmark.seal", method: "POST",
                       path: "/settings/navidrome/verify", sendsForm: true),
            FormAction(title: "Synchroniser les playlists", symbol: "arrow.triangle.2.circlepath", method: "POST",
                       path: "/settings/navidrome/playlist-sync"),
        ]
    )

    static let plex = FormSpec(
        load: "/settings/plex", save: "/settings/plex",
        sections: [
            FormSection(title: "Connexion", fields: [
                Field(key: "plex_url", label: "Adresse", kind: .url, help: "Par exemple http://plex-server:32400"),
                Field(key: "plex_token", label: "Jeton Plex", kind: .secret),
                Field(key: "music_library_ids", label: "Bibliothèques musicales (une clé par ligne)", kind: .lines,
                      help: "La vérification liste les bibliothèques disponibles et leurs clés."),
            ]),
            FormSection(fields: [
                Field(key: "enabled", label: "Activer Plex", kind: .toggle),
                Field(key: "login_enabled", label: "Se connecter avec Plex", kind: .toggle),
            ], footer: "Plex demande une vérification réussie et au moins une bibliothèque."),
        ],
        actions: [
            FormAction(title: "Vérifier la connexion", symbol: "checkmark.seal", method: "POST",
                       path: "/settings/plex/verify", sendsForm: true),
            FormAction(title: "Lister les bibliothèques", symbol: "books.vertical", method: "GET", path: "/settings/plex/libraries"),
        ]
    )

    static let youtube = FormSpec(
        load: "/settings/youtube", save: "/settings/youtube",
        sections: [
            FormSection(fields: [Field(key: "enabled", label: "Activer YouTube", kind: .toggle)]),
            FormSection(title: "API YouTube (facultative)", fields: [
                Field(key: "api_key", label: "Clé d'API", kind: .secret),
                Field(key: "api_enabled", label: "Activer l'API", kind: .toggle),
                Field(key: "daily_quota_limit", label: "Quota quotidien", kind: .number,
                      help: "Recherches de vidéos par jour au maximum (80 par défaut)."),
            ]),
        ],
        actions: [FormAction(title: "Vérifier la clé", symbol: "checkmark.seal", method: "POST",
                             path: "/settings/youtube/verify", sendsForm: true)]
    )

    static let lastfm = FormSpec(
        load: "/settings/lastfm", save: "/settings/lastfm",
        sections: [FormSection(title: "Application Last.fm", fields: [
            Field(key: "enabled", label: "Activer Last.fm", kind: .toggle),
            Field(key: "api_key", label: "Clé d'API"),
            Field(key: "shared_secret", label: "Secret partagé", kind: .secret),
        ], footer: "Chacun relie ensuite son propre compte Last.fm depuis son compte.")],
        actions: [FormAction(title: "Vérifier", symbol: "checkmark.seal", method: "POST",
                             path: "/settings/lastfm/verify", sendsForm: true)]
    )

    static let spotify = FormSpec(
        load: "/acquire/spotify/settings", save: "/acquire/spotify/settings",
        sections: [
            FormSection(title: "Application Spotify", fields: [
                Field(key: "client_id", label: "Client ID"),
                Field(key: "client_secret", label: "Client secret", kind: .secret),
                Field(key: "spotify_redirect_origin", label: "Origine de redirection", kind: .url,
                      help: "Origine sans chemin, à renseigner quand un proxy fait pointer l'adresse vers localhost."),
            ]),
            FormSection(fields: [Field(key: "enabled", label: "Activer Spotify", kind: .toggle)],
                        footer: "En mode développement, Spotify limite l'accès à 5 utilisateurs."),
        ],
        actions: [FormAction(title: "Afficher l'URI de redirection", symbol: "link", method: "GET",
                             path: "/acquire/spotify/redirect-uri")]
    )

    static let events = FormSpec(
        load: "/settings/events", save: "/settings/events",
        sections: [
            FormSection(fields: [
                Field(key: "enabled", label: "Activer les concerts", kind: .toggle),
                Field(key: "sweep_scope", label: "Chercher les concerts de",
                      kind: .choice([("followed", "Artistes suivis"), ("library", "Toute la discothèque")])),
                Field(key: "poll_time", label: "Vérifier chaque jour à", help: "HH:MM, à l'heure du serveur."),
            ]),
            FormSection(title: "Ticketmaster", fields: [
                Field(key: "ticketmaster_enabled", label: "Activer", kind: .toggle),
                Field(key: "ticketmaster_api_key", label: "Clé d'API", kind: .secret),
            ]),
            FormSection(title: "Skiddle", fields: [
                Field(key: "skiddle_enabled", label: "Activer", kind: .toggle),
                Field(key: "skiddle_api_key", label: "Clé d'API", kind: .secret),
            ]),
        ],
        actions: [
            FormAction(title: "Tester Ticketmaster", symbol: "ticket", method: "POST",
                       path: "/settings/events/test-ticketmaster", sendsForm: true),
            FormAction(title: "Tester Skiddle", symbol: "ticket", method: "POST",
                       path: "/settings/events/test-skiddle", sendsForm: true),
        ]
    )

    static let getIt = FormSpec(
        load: "/settings/get-it", save: "/settings/get-it",
        sections: [FormSection(fields: [
            Field(key: "store_region", label: "Région de la boutique", kind: .choice([
                ("US", "États-Unis"), ("GB", "Royaume-Uni"), ("DE", "Allemagne"), ("FR", "France"),
                ("NL", "Pays-Bas"), ("SE", "Suède"), ("AU", "Australie"), ("CA", "Canada"),
                ("JP", "Japon"), ("BR", "Brésil"),
            ]), help: "La boutique iTunes vers laquelle pointent les liens d'achat."),
        ])]
    )

    static let releaseTypes = FormSpec(
        load: "/settings/preferences", save: "/settings/preferences",
        sections: [
            FormSection(title: "Types principaux", fields: [
                Field(key: "primary_types", label: "Ce qu'on montre des discographies", kind: .multi([
                    ("album", "Albums"), ("ep", "EP"), ("single", "Singles"),
                    ("broadcast", "Émissions"), ("other", "Autres"),
                ])),
            ]),
            FormSection(title: "Types secondaires", fields: [
                Field(key: "secondary_types", label: "Et parmi eux", kind: .multi([
                    ("studio", "Studio"), ("compilation", "Compilations"), ("soundtrack", "Bandes originales"),
                    ("spokenword", "Textes lus"), ("interview", "Interviews"), ("audio drama", "Fictions audio"),
                    ("live", "Live"), ("remix", "Remix"), ("dj-mix", "DJ mix"), ("mixtape/street", "Mixtapes"),
                    ("demo", "Démos"),
                ])),
            ], footer: "D'après la façon dont MusicBrainz classe chaque groupe de sorties."),
        ]
    )

    static let wrapped = FormSpec(
        load: "/settings/wrapped", save: "/settings/wrapped",
        sections: [FormSection(fields: [
            Field(key: "api_key", label: "Clé d'API Wrapped", kind: .secret,
                  help: "Envoyée dans l'en-tête X-Wrapped-Api-Key par les applis qui lisent ton bilan."),
        ])]
    )

    static let security = FormSpec(
        load: "/settings/security", save: "/settings/security",
        sections: [
            FormSection(title: "Mots de passe", fields: [
                Field(key: "hibp_check", label: "Refuser les mots de passe ayant fuité", kind: .toggle),
                Field(key: "hibp_local_path", label: "Base HIBP locale", help: "Facultatif : un fichier local au lieu de l'API."),
            ]),
            FormSection(title: "HSTS", fields: [
                Field(key: "hsts_max_age", label: "Durée", kind: .numberChoice([
                    (0, "Désactivé"), (2_592_000, "1 mois"), (15_552_000, "6 mois"), (31_536_000, "1 an"),
                ])),
                Field(key: "hsts_include_subdomains", label: "Inclure les sous-domaines", kind: .toggle),
                Field(key: "hsts_preload", label: "Préchargement", kind: .toggle,
                      help: "Demande d'inclure les sous-domaines."),
            ]),
            FormSection(title: "Politique de sécurité du contenu", fields: [
                Field(key: "content_security_policy", label: "Mode", kind: .choice([
                    ("enforce", "Appliquée"), ("report_only", "Signalée seulement"), ("off", "Désactivée"),
                ])),
                Field(key: "frame_ancestors", label: "Autorisés à afficher DroppedNeedle dans un cadre (une adresse par ligne)",
                      kind: .lines, help: "Par exemple le tableau de bord Homarr ou Organizr."),
            ]),
            FormSection(title: "Discothèque", fields: [
                Field(key: "library_download_access", label: "Qui peut télécharger des fichiers",
                      kind: .choice([("everyone", "Tout le monde"), ("trusted", "Comptes de confiance"), ("admin", "Admins")])),
            ]),
        ],
        actions: [FormAction(title: "Vérifier HIBP", symbol: "checkmark.seal", method: "POST",
                             path: "/settings/security/verify-hibp", sendsForm: true)]
    )

    static let oidc = FormSpec(
        load: "/settings/oidc", save: "/settings/oidc",
        sections: [
            FormSection(fields: [
                Field(key: "issuer", label: "Émetteur", kind: .url),
                Field(key: "client_id", label: "Client ID"),
                Field(key: "client_secret", label: "Client secret", kind: .secret, help: "Facultatif avec PKCE."),
                Field(key: "scopes", label: "Portées"),
                Field(key: "redirect_uri", label: "URI de redirection", kind: .url,
                      help: "Doit finir par /api/v3/auth/oidc/callback."),
            ]),
            FormSection(fields: [
                Field(key: "enabled", label: "Activer la connexion OIDC", kind: .toggle),
                Field(key: "auto_redirect", label: "Rediriger directement vers le fournisseur", kind: .toggle),
            ],
                        footer: "Demande un client ID, une URI de redirection et une vérification réussie."),
        ],
        actions: [FormAction(title: "Vérifier", symbol: "checkmark.seal", method: "POST",
                             path: "/settings/oidc/verify", sendsForm: true)]
    )

    /// L'adresse publique : celle d'où le serveur accepte les changements, quand le proxy la cache.
    static let publicAddress = FormSpec(
        load: "/settings/public-address", save: "/settings/public-address",
        sections: [FormSection(fields: [
            Field(key: "origins", label: "Adresses (une par ligne)", kind: .lines,
                  help: "Par exemple https://musique.exemple.fr, port compris s'il y en a un."),
        ], footer: "À renseigner si le serveur répond « 403 Origin not allowed » derrière un proxy qui ne transmet pas l'en-tête Host.")]
    )

    static let connectApps = FormSpec(
        load: "/settings/connect-apps", save: "/settings/connect-apps",
        sections: [
            FormSection(title: "API", fields: [
                Field(key: "subsonic_enabled", label: "API OpenSubsonic", kind: .toggle,
                      help: "Pour Symfonium, Feishin, Amperfy…"),
                Field(key: "jellyfin_enabled", label: "API compatible Jellyfin", kind: .toggle, help: "Pour Finamp, Jellify…"),
            ]),
            FormSection(title: "Transcodage", fields: [
                Field(key: "transcoding_enabled", label: "Transcoder à la volée", kind: .toggle),
                Field(key: "transcode_default_format", label: "Format", kind: .choice([("mp3", "MP3"), ("opus", "Opus")])),
                Field(key: "transcode_max_bitrate_kbps", label: "Débit max (kbit/s)", kind: .number),
            ]),
        ]
    )

    // MARK: Téléchargement

    static let slskd = FormSpec(
        load: "/settings/download-client/config", save: "/settings/download-client/config",
        sections: [
            FormSection(fields: [
                Field(key: "enabled", label: "Activer slskd", kind: .toggle),
                Field(key: "url", label: "Adresse", kind: .url, help: "Par exemple http://slskd:5030"),
                Field(key: "api_key", label: "Clé d'API", kind: .secret),
            ]),
            FormSection(title: "Dossiers", fields: [
                Field(key: "downloads_subpath", label: "Sous-dossier des téléchargements", help: "Relatif au point de montage."),
                Field(key: "slskd_incomplete_mount", label: "Dossier incomplet", help: "Facultatif, chemin absolu."),
            ]),
        ],
        actions: [
            FormAction(title: "Tester la connexion", symbol: "checkmark.seal", method: "POST",
                       path: "/settings/download-client/test", sendsForm: true),
            FormAction(title: "État du client et du montage", symbol: "stethoscope", method: "GET",
                       path: "/acquire/slskd/status"),
        ]
    )

    static let sabnzbd = FormSpec(
        load: "/settings/download-clients/sabnzbd", save: "/settings/download-clients/sabnzbd",
        sections: [FormSection(fields: [
            Field(key: "enabled", label: "Activer SABnzbd", kind: .toggle),
            Field(key: "url", label: "Adresse", kind: .url, help: "Par exemple http://sabnzbd:8080"),
            Field(key: "api_key", label: "Clé d'API (complète)", kind: .secret),
            Field(key: "category", label: "Catégorie", help: "Le test liste les catégories disponibles."),
            Field(key: "downloads_mount", label: "Montage des téléchargements"),
        ])],
        actions: [
            FormAction(title: "Tester la connexion", symbol: "checkmark.seal", method: "POST",
                       path: "/settings/download-clients/sabnzbd/test", sendsForm: true),
            FormAction(title: "État", symbol: "stethoscope", method: "GET", path: "/acquire/sabnzbd/status"),
        ]
    )

    static let wanted = FormSpec(
        load: "/settings/download-clients/wanted", save: "/settings/download-clients/wanted",
        sections: [FormSection(fields: [
            Field(key: "enabled", label: "Surveiller les demandes échouées", kind: .toggle),
            Field(key: "auto_download_on_find", label: "Télécharger dès qu'une copie vérifiée apparaît", kind: .toggle),
            Field(key: "watch_partial_albums", label: "Surveiller aussi les albums incomplets", kind: .toggle),
            Field(key: "max_checks_per_sweep", label: "Albums vérifiés par passage", kind: .number),
        ], footer: "Une surveillance continue jusqu'à l'arrivée de l'album, ou jusqu'à ce qu'on l'arrête.")]
    )

    private static let qualityTiers: [(value: String, label: String)] = [
        ("low", "Lossy sous 192 kbit/s"), ("mp3_192", "192–255 kbit/s"), ("mp3_256", "256–319 kbit/s"),
        ("mp3_320", "320 kbit/s"), ("lossless", "Sans perte"),
    ]

    /// La politique d'acquisition ; la recette de qualité, plus fine, garde
    /// sa valeur (le formulaire renvoie l'objet entier).
    static let policy = FormSpec(
        load: "/settings/download-clients/policy", save: "/settings/download-clients/policy",
        sections: [
            FormSection(title: "Mises à niveau", fields: [
                Field(key: "upgrade_allowed", label: "Améliorer automatiquement", kind: .toggle),
                Field(key: "background_upgrade_scan_enabled", label: "Chercher en arrière-plan", kind: .toggle),
                Field(key: "quality_cutoff", label: "Jusqu'à atteindre", kind: .choice(qualityTiers)),
            ]),
            FormSection(title: "Choisir un pressage", fields: [
                Field(key: "search_review", label: "Me laisser choisir", kind: .choice([
                    ("when_unsure", "Quand aucune copie ne semble juste"), ("always", "Toujours"), ("off", "Jamais"),
                ])),
            ], footer: "Quand un album attend dans la file que tu choisisses la copie à télécharger."),
            FormSection(title: "Téléchargement (avancé)", fields: [
                Field(key: "auto_retry_enabled", label: "Réessayer les échecs", kind: .toggle),
                Field(key: "auto_retry_max_attempts", label: "Nouveaux essais", kind: .number),
                Field(key: "preflight_score_auto_accept", label: "Score d'acceptation auto", kind: .number),
                Field(key: "preflight_score_manual_min", label: "Score de revue manuelle", kind: .number),
                Field(key: "preferred_quality_wait_minutes", label: "Attente de la qualité préférée (min)", kind: .number),
                Field(key: "max_concurrent_downloads", label: "Téléchargements simultanés", kind: .number),
                Field(key: "max_failover_attempts", label: "Bascules max", kind: .number),
            ]),
            FormSection(title: "Rétention", fields: [
                Field(key: "usenet_retention_days", label: "Rétention Usenet (jours)", kind: .number,
                      help: "Ignore les sorties Usenet plus anciennes ; 0 coupe la vérification."),
            ]),
        ]
    )

    static let prowlarr = FormSpec(
        load: "/settings/prowlarr/config", save: "/settings/prowlarr/config",
        sections: [FormSection(fields: [
            Field(key: "enabled", label: "Activer Prowlarr", kind: .toggle),
            Field(key: "url", label: "Adresse", kind: .url),
            Field(key: "api_key", label: "Clé d'API", kind: .secret),
        ])],
        actions: [FormAction(title: "Tester la connexion", symbol: "checkmark.seal", method: "POST",
                             path: "/settings/prowlarr/test", sendsForm: true)]
    )

    static let lidarr = FormSpec(
        load: "/acquire/lidarr-import/config", save: "/acquire/lidarr-import/config",
        sections: [FormSection(title: "Connexion à Lidarr", fields: [
            Field(key: "url", label: "Adresse", kind: .url),
            Field(key: "api_key", label: "Clé d'API", kind: .secret),
        ])],
        actions: [FormAction(title: "Tester la connexion", symbol: "checkmark.seal", method: "POST",
                             path: "/acquire/lidarr-import/test", sendsForm: true)]
    )

    static let librarySchedule = FormSpec(
        load: "/settings/library/schedule", save: "/settings/library/schedule",
        sections: [FormSection(title: "Analyse automatique", fields: [
            Field(key: "scan_frequency", label: "Fréquence", kind: .choice([
                ("manual", "Manuelle seulement"), ("daily", "Chaque jour à heure fixe"), ("30min", "Toutes les 30 min"),
                ("1hr", "Toutes les heures"), ("6hr", "Toutes les 6 h"), ("12hr", "Toutes les 12 h"),
                ("24hr", "Toutes les 24 h"), ("3d", "Tous les 3 jours"), ("7d", "Chaque semaine"),
            ])),
            Field(key: "daily_scan_time", label: "Heure (quotidienne)", help: "HH:MM, à l'heure du serveur."),
        ])]
    )

    // MARK: Avancé

    /// v3 ne garde que la file Découvrir, TheAudioDB et la rétention : les durées
    /// de cache, le réseau et le traitement par lots ont des valeurs fixes.
    static let advanced = FormSpec(
        load: "/settings/advanced", save: "/settings/advanced",
        sections: [
            FormSection(title: "File Découvrir", fields: [
                Field(key: "discover_queue_size", label: "Taille", kind: .number, help: "Albums par file (10 par défaut)."),
                Field(key: "discover_queue_auto_generate", label: "Générer à la visite", kind: .toggle),
                Field(key: "discover_queue_warm_cycle_build", label: "Préparer pendant le préchauffage", kind: .toggle),
                Field(key: "discover_queue_seed_artists", label: "Artistes de départ", kind: .number),
                Field(key: "discover_queue_wildcard_slots", label: "Places surprises", kind: .number),
                Field(key: "discover_queue_similar_artists_limit", label: "Artistes similaires", kind: .number),
                Field(key: "discover_queue_albums_per_similar", label: "Albums par artiste similaire", kind: .number),
                Field(key: "discover_queue_lastfm_mbid_max_lookups", label: "Recherches Last.fm max", kind: .number),
                Field(key: "discover_picks_count", label: "Sélections", kind: .number),
                Field(key: "discover_picks_genre_affinity_weight", label: "Poids des genres (0 à 1)", kind: .number),
                Field(key: "discover_blend_listening_services", label: "Mêler Last.fm et ListenBrainz", kind: .toggle),
            ]),
            FormSection(title: "TheAudioDB", fields: [
                Field(key: "audiodb_enabled", label: "Activer", kind: .toggle),
                Field(key: "audiodb_api_key", label: "Clé d'API", kind: .secret, help: "123 par défaut (gratuite, 30 requêtes/min)."),
                Field(key: "audiodb_name_search_fallback", label: "Chercher par nom en dernier recours", kind: .toggle),
                Field(key: "direct_remote_images_enabled", label: "Images distantes directes", kind: .toggle),
                Field(key: "prefer_local_cover_art", label: "Préférer les pochettes locales", kind: .toggle),
            ]),
            FormSection(title: "Rétention", fields: [
                Field(key: "request_history_retention_days", label: "Historique des demandes (jours)", kind: .number,
                      help: "Les demandes terminées plus anciennes sont effacées (180 par défaut)."),
                Field(key: "ignored_releases_retention_days", label: "Albums ignorés (jours)", kind: .number,
                      help: "Durée pendant laquelle un album ignoré reste hors de la file Découvrir (365 par défaut)."),
                Field(key: "store_prune_interval_hours", label: "Nettoyage toutes les (heures)", kind: .number),
            ], footer: "Les valeurs hors limites sont refusées par le serveur."),
        ]
    )
}

// MARK: Écrans composés

/// Sécurité : protection des comptes, HSTS et CSP, la connexion OIDC, l'adresse publique.
struct SecurityView: View {
    var body: some View {
        List {
            NavigationLink("Mots de passe, HSTS et accès") { FormPanel(title: "Sécurité", spec: .security) }
            NavigationLink("Connexion OIDC") { FormPanel(title: "OIDC", spec: .oidc) }
            NavigationLink("Adresse publique") { FormPanel(title: "Adresse publique", spec: .publicAddress) }
        }
        .settingsStyle()
        .navigationTitle("Sécurité")
    }
}

/// Clients de téléchargement : slskd, SABnzbd, ordre des sources, politique, Wanted.
struct DownloadClientsView: View {
    var body: some View {
        List {
            Section("Clients") {
                NavigationLink { FormPanel(title: "slskd", spec: .slskd) } label: {
                    Label { Text("slskd (Soulseek)") } icon: { IconTile(.logo("logo-slskd")) }
                }
                NavigationLink { FormPanel(title: "SABnzbd", spec: .sabnzbd) } label: {
                    Label { Text("SABnzbd (Usenet)") } icon: { IconTile(.logo("logo-sabnzbd")) }
                }
            }
            .settingsRow()
            Section("Acquisition") {
                NavigationLink { SourcePriorityView() } label: { Label("Ordre des sources", systemImage: "list.number") }
                NavigationLink { QualityRecipeView() } label: {
                    Label("Recette de qualité", systemImage: "list.number")
                }
                NavigationLink { FormPanel(title: "Politique", spec: .policy) } label: {
                    Label("Qualité et téléchargement", systemImage: "slider.horizontal.3")
                }
                NavigationLink { FormPanel(title: "Wanted", spec: .wanted) } label: {
                    Label("Wanted", systemImage: "binoculars")
                }
            }
            .settingsRow()
        }
        .settingsStyle()
        .navigationTitle("Téléchargement")
    }
}

/// Le choix de la source musicale des recommandations, propre à chacun.
struct MusicSourceView: View {
    @Environment(\.client) private var client
    @State private var preferences: ListeningPreferences?

    var body: some View {
        Form {
            if let preferences {
                Picker("Recommandations tirées de", selection: Binding(
                    get: { preferences.primaryMusicSource },
                    set: { source in
                        self.preferences?.primaryMusicSource = source
                        Task { if let updated = self.preferences { self.preferences = try? await client.update(updated) } }
                    }
                )) {
                    Text("ListenBrainz").tag("listenbrainz")
                    Text("Last.fm").tag("lastfm")
                }
                .pickerStyle(.inline)
                .settingsRow()
            } else {
                ProgressView().listRowBackground(Color.clear)
            }
        }
        .settingsStyle()
        .navigationTitle("Source musicale")
        .task { preferences = try? await client.listeningPreferences() }
    }
}
