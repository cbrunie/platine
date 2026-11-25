import SwiftUI

/// La recette de qualité : l'ordre des formats qu'on accepte, du préféré au
/// moins bon, comme l'éditeur du web (`qualityRecipeModel.ts`). On réordonne,
/// on ajoute, on retire, on part d'un préréglage. Le serveur en déduit lui-même
/// la plage de qualité ; on lui renvoie toute la politique.
struct QualityRecipeView: View {
    @Environment(\.client) private var client
    @State private var policy: JSON?
    @State private var recipe: [JSON] = []
    @State private var original: [JSON] = []
    @State private var adding = false
    @State private var preset: Preset?
    @State private var alert: ServerAlert?
    @State private var saving = false

    var body: some View {
        List {
            Section {
                ForEach(recipe.indices, id: \.self) { index in
                    HStack(spacing: 12) {
                        Text("\(index + 1)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20)
                        IconTile(symbol: recipe[index]["format"]?.string == "flac" ? "waveform" : "music.note",
                                 color: recipe[index]["format"]?.string == "flac" ? .sage : .sky.mix(with: .blue, by: 0.4))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.label(recipe[index]))
                            Text(Self.detail(recipe[index])).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onMove { recipe.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { recipe.remove(atOffsets: $0) }
                Button("Ajouter un format", systemImage: "plus") { adding = true }
            } header: {
                Text("Du préféré au moins bon")
            } footer: {
                if let error = policy?["quality_recipe_error"]?.string, policy?["quality_recipe_status"]?.string == "invalid" {
                    Text("Recette refusée par le serveur : \(error)").foregroundStyle(.yellow)
                } else {
                    Text("Le premier format trouvé gagne. Un changement vaut aussi pour ce qui attend déjà dans la file.")
                }
            }
            .settingsRow()

            Section("Partir d'un préréglage") {
                ForEach(Preset.allCases, id: \.self) { item in
                    Button(item.title) { preset = item }
                }
            }
            .settingsRow()
        }
        .environment(\.editMode, .constant(.active))
        .settingsStyle()
        .navigationTitle("Recette de qualité")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else {
                    Button("Enregistrer") { save() }.disabled(recipe == original || recipe.isEmpty)
                }
            }
        }
        .confirmationDialog("Remplacer la recette par « \(preset?.title ?? "") » ?", isPresented: .constant(preset != nil),
                            titleVisibility: .visible) {
            Button("Remplacer") { if let preset { recipe = preset.entries }; preset = nil }
            Button("Annuler", role: .cancel) { preset = nil }
        }
        .sheet(isPresented: $adding) { RecipeEntryEditor { recipe.append($0) } }
        .serverAlert($alert)
        .task {
            policy = try? await client.json("GET", "/settings/download-clients/policy")
            original = policy?["quality_recipe"]?.array ?? []
            recipe = original
        }
    }

    // MARK: Enregistrement

    /// Le serveur recalcule la plage min–max depuis la recette et y ramène la
    /// qualité visée ; les champs de verdict renvoyés par le GET sont ignorés.
    private func save() {
        guard var policy else { return }
        policy["quality_recipe"] = .array(recipe)
        saving = true
        Task {
            defer { saving = false }
            do {
                let saved = try await client.json("PUT", "/settings/download-clients/policy", body: policy)
                self.policy = saved
                recipe = saved["quality_recipe"]?.array ?? recipe
                original = recipe
                alert = ServerAlert(title: "Recette enregistrée",
                                    message: "Elle vaut pour les téléchargements à venir et ceux qui attendent.")
            } catch {
                alert = ServerAlert(title: "Recette refusée", message: error.localizedDescription)
            }
        }
    }

    // MARK: Libellés

    static func label(_ entry: JSON) -> String {
        let quality = entry["quality"]?.string ?? ""
        if entry["format"]?.string == "flac" {
            return "FLAC · " + ([
                "cd": "Qualité CD", "24_48": "24 bits / 48 kHz", "24_96": "24 bits / 96 kHz",
                "24_192": "24 bits / 192 kHz", "hi_res": "Au-delà de 24 bits / 192 kHz",
            ][quality] ?? "Sur mesure")
        }
        return "MP3 · " + (["below_192": "Moins de 192", "192_255": "192–255", "256_319": "256–319", "320_plus": "320 et plus"][quality]
            ?? "Sur mesure")
    }

    static func detail(_ entry: JSON) -> String {
        if entry["format"]?.string == "flac" {
            if entry["quality"]?.string == "custom" {
                return "\(entry["bit_depth"]?.int ?? 0) bits / \((entry["sample_rate_hz"]?.number ?? 0) / 1000) kHz"
            }
            return "Sans perte"
        }
        let low = entry["min_bitrate_kbps"]?.int ?? 16
        guard let high = entry["max_bitrate_kbps"]?.int else { return "\(low) kbit/s et plus" }
        return "\(low)–\(high) kbit/s"
    }

    // MARK: Préréglages

    enum Preset: CaseIterable {
        case balanced, mp3Only, efficient, best

        var title: String {
            switch self {
            case .balanced: "Équilibré"
            case .mp3Only: "MP3 seulement"
            case .efficient: "Économe, 192 et plus"
            case .best: "Le meilleur disponible"
            }
        }

        var entries: [JSON] {
            switch self {
            case .balanced: [.flac("cd"), .mp3("320_plus"), .mp3("256_319"), .mp3("192_255")]
            case .mp3Only: [.mp3("320_plus"), .mp3("256_319"), .mp3("192_255")]
            case .efficient: [.mp3("192_255"), .mp3("256_319"), .mp3("320_plus"), .flac("cd")]
            case .best: [.flac("hi_res"), .flac("24_192"), .flac("24_96"), .flac("24_48"), .flac("cd"),
                         .mp3("320_plus"), .mp3("256_319"), .mp3("192_255"), .mp3("below_192")]
            }
        }
    }
}

extension JSON {
    static func flac(_ quality: String) -> JSON {
        .object(["format": .string("flac"), "quality": .string(quality)])
    }

    /// Une entrée MP3 standard, avec les bornes du web (`MP3_REGIONS`). v3 refuse
    /// toute clé inconnue dans une entrée : plus de débit visé.
    static func mp3(_ quality: String) -> JSON {
        let (low, high): (Double, Double?) = switch quality {
        case "below_192": (16, 191)
        case "192_255": (192, 255)
        case "256_319": (256, 319)
        default: (320, nil)
        }
        return .object([
            "format": .string("mp3"), "quality": .string(quality), "min_bitrate_kbps": .number(low),
            "max_bitrate_kbps": high.map(JSON.number) ?? .null,
        ])
    }
}

/// Une entrée de recette : un format standard, ou des bornes sur mesure.
private struct RecipeEntryEditor: View {
    let add: (JSON) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var format = "flac"
    @State private var quality = "cd"
    @State private var minimum: Double = 192
    @State private var maximum: Double = 320
    @State private var bitDepth: Double = 24
    @State private var sampleRate: Double = 96000

    var body: some View {
        NavigationStack {
            Form {
                Picker("Format", selection: $format) {
                    Text("FLAC").tag("flac")
                    Text("MP3").tag("mp3")
                }
                .pickerStyle(.segmented)
                .onChange(of: format) { quality = format == "flac" ? "cd" : "320_plus" }
                .listRowBackground(Color.clear)

                Section {
                    Picker("Qualité", selection: $quality) {
                        if format == "flac" {
                            Text("Qualité CD").tag("cd")
                            Text("24 bits / 48 kHz").tag("24_48")
                            Text("24 bits / 96 kHz").tag("24_96")
                            Text("24 bits / 192 kHz").tag("24_192")
                            Text("Au-delà de 24 bits / 192 kHz").tag("hi_res")
                        } else {
                            Text("320 et plus").tag("320_plus")
                            Text("256–319").tag("256_319")
                            Text("192–255").tag("192_255")
                            Text("Moins de 192").tag("below_192")
                        }
                        Text("Sur mesure").tag("custom")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .settingsRow()

                if quality == "custom" {
                    Section("Sur mesure") {
                        if format == "flac" {
                            Stepper("Profondeur : \(Int(bitDepth)) bits", value: $bitDepth, in: 1 ... 64)
                            Picker("Fréquence", selection: $sampleRate) {
                                ForEach([44100.0, 48000, 88200, 96000, 176400, 192000, 384000], id: \.self) {
                                    Text("\($0 / 1000, format: .number) kHz").tag($0)
                                }
                            }
                        } else {
                            Stepper("Minimum : \(Int(minimum)) kbit/s", value: $minimum, in: 16 ... maximum, step: 16)
                            Stepper("Maximum : \(Int(maximum)) kbit/s", value: $maximum, in: minimum ... 2048, step: 16)
                        }
                    }
                    .settingsRow()
                }
            }
            .settingsStyle()
            .navigationTitle("Nouveau format")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ajouter") {
                        add(entry)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var entry: JSON {
        switch (format, quality) {
        case ("flac", "custom"):
            .object(["format": .string("flac"), "quality": .string("custom"),
                     "bit_depth": .number(bitDepth), "sample_rate_hz": .number(sampleRate)])
        case ("flac", _):
            .flac(quality)
        case (_, "custom"):
            .object(["format": .string("mp3"), "quality": .string("custom"), "min_bitrate_kbps": .number(minimum),
                     "max_bitrate_kbps": .number(maximum)])
        default:
            .mp3(quality)
        }
    }
}
