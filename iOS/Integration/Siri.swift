import AppIntents

/// « Dis Siri, mets le bac sur Platine » : les commandes de la platine pour
/// Siri, Raccourcis, Spotlight et le bouton Action. Elles jouent sans ouvrir l'app.
struct PlayCrateIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Lire le bac"
    static let description = IntentDescription("Pose les disques de « Dans le bac » sur la platine.")

    func perform() async throws -> some IntentResult {
        await Player.shared.playCrate()
        return .result()
    }
}

struct ResumeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Reprendre la lecture"

    func perform() async throws -> some IntentResult {
        await Player.shared.resume()
        return .result()
    }
}

struct PauseIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Mettre en pause"

    func perform() async throws -> some IntentResult {
        await Player.shared.pause()
        return .result()
    }
}

struct NextIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Morceau suivant"

    func perform() async throws -> some IntentResult {
        await Player.shared.next()
        return .result()
    }
}

struct PlatineShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayCrateIntent(), phrases: [
            "Mets le bac sur \(.applicationName)",
            "Lance \(.applicationName)",
            "Pose l'aiguille sur \(.applicationName)",
        ], shortTitle: "Lire le bac", systemImageName: "opticaldisc.fill")
        AppShortcut(intent: ResumeIntent(), phrases: ["Reprends \(.applicationName)"],
                    shortTitle: "Reprendre", systemImageName: "play.fill")
        AppShortcut(intent: PauseIntent(), phrases: ["Mets \(.applicationName) en pause"],
                    shortTitle: "Pause", systemImageName: "pause.fill")
        AppShortcut(intent: NextIntent(), phrases: ["Morceau suivant sur \(.applicationName)"],
                    shortTitle: "Suivant", systemImageName: "forward.fill")
    }
}
