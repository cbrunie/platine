import SwiftUI

/// Les doublons d'artistes : des fiches qui désignent sans doute la même
/// personne. On choisit celle qui reste, on prévisualise, puis on fusionne ;
/// ou on les déclare distinctes.
struct ArtistDeskView: View {
    @Environment(\.client) private var client
    @State private var progress: JSON?
    @State private var groups: [JSON] = []
    @State private var state = ""
    @State private var search = ""

    private static let states = [("", "Toutes"), ("waiting_for_identity", "En attente d'identité"), ("provider_conflict", "Conflit de sources"),
                                 ("ambiguous_credit_structure", "Crédits ambigus"), ("same_name_only", "Même nom seulement"),
                                 ("credits_moved", "Morceaux déplacés"), ("shared_provider_identity", "Même artiste MusicBrainz"),
                                 ("resolved_automatically", "Résolues seules")]

    var body: some View {
        List {
            if let progress {
                Section {
                    StatGrid(items: [("Résolues seules", progress["automatically_resolved_count"]?.int ?? 0),
                                     ("En attente", progress["waiting_for_identity_count"]?.int ?? 0),
                                     ("À revoir", progress["genuine_review_count"]?.int ?? 0)])
                }
                .settingsRow()
            }
            FilterChips(options: Self.states.map { ($0.0, $0.1) }, selection: $state).bareRow()
            SearchField(prompt: "Chercher un artiste", text: $search) { Task { await load() } }.bareRow()
            Section {
                ForEach(groups.indices, id: \.self) { index in
                    let group = groups[index]
                    NavigationLink { ArtistGroupView(id: group["id"]?.string ?? "") { await load() } } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group["display_name"]?.string ?? "")
                            Text("\(group["member_count"]?.int ?? 0) fiches · \(group["affected_reference_count"]?.int ?? 0) références")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if groups.isEmpty { Text("Aucun doublon dans cette catégorie.").foregroundStyle(.secondary) }
            }
            .settingsRow()
        }
        .settingsStyle()
        .navigationTitle("Doublons d'artistes")
        .task(id: state) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        progress = try? await client.json("GET", "/library/artists/reconciliation")
        var path = "/library/artists/duplicate-groups?limit=50"
        if !state.isEmpty { path += "&state=\(state)" }
        if let query = search.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), !query.isEmpty { path += "&search=\(query)" }
        groups = (try? await client.json("GET", path))?["items"]?.array ?? []
    }
}

private struct ArtistGroupView: View {
    let id: String
    let changed: () async -> Void

    @Environment(\.client) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var detail: JSON?
    @State private var survivor = ""
    @State private var preview: JSON?
    @State private var keepSurvivorIdentity = true
    @State private var agreed = false
    @State private var dismissing = false
    @State private var undoing = false
    @State private var alert: ServerAlert?

    var body: some View {
        List {
            if let detail {
                Section("Fiche qui reste") {
                    ForEach((detail["members"]?.array ?? []).indices, id: \.self) { index in
                        let member = detail["members"]?.array?[index]
                        let memberID = member?["id"]?.string ?? ""
                        Button { survivor = memberID } label: {
                            HStack {
                                Image(systemName: survivor == memberID ? "largecircle.fill.circle" : "circle").foregroundStyle(Color.sage)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(member?["name"]?.string ?? "").foregroundStyle(.primary)
                                    Text("\(member?["album_credit_count"]?.int ?? 0) albums · \(member?["track_credit_count"]?.int ?? 0) plages · \(member?["favorite_count"]?.int ?? 0) favoris")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let mbid = member?["provider_mbid"]?.string {
                                        Text(mbid).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .settingsRow()
                if let reason = detail["reason"]?["message"]?.string, !reason.isEmpty {
                    Section { Text(reason).font(.callout).foregroundStyle(.secondary) }.settingsRow()
                }
                if detail["can_undo"]?.bool == true {
                    Section {
                        Button("Défaire cette réunion", systemImage: "arrow.uturn.backward") { undoing = true }
                    } footer: {
                        Text("Ces fiches ont été réunies automatiquement ; on peut les séparer à nouveau.")
                    }
                    .settingsRow()
                }
                Section {
                    Button("Prévisualiser la fusion", systemImage: "arrow.triangle.merge") { mergePreview() }.disabled(survivor.isEmpty)
                    Button("Garder ces artistes distincts", systemImage: "person.2", role: .destructive) { dismissing = true }
                } footer: {
                    Text("Les identifiants retirés restent des alias. Fichiers, étiquettes, pochettes et chemins ne changent pas.")
                }
                .settingsRow()
            } else {
                ProgressView().listRowBackground(Color.clear)
            }
        }
        .settingsStyle()
        .navigationTitle(detail?["display_name"]?.string ?? "Doublon")
        .sheet(item: Binding(get: { preview.map { IdentifiedJSON(value: $0) } }, set: { preview = $0?.value })) { item in
            NavigationStack {
                Form {
                    Section {
                        Text("\((detail?["members"]?.array?.count ?? 1) - 1) identifiant(s) retiré(s) resteront des alias.")
                        if !(item.value["identity_conflicts"]?.array ?? []).isEmpty {
                            Picker("Identité MusicBrainz", selection: $keepSurvivorIdentity) {
                                Text("Garder celle de la fiche qui reste").tag(true)
                                Text("Détacher les identités en conflit").tag(false)
                            }
                            .pickerStyle(.inline)
                        }
                        Toggle("Fusionner toutes les fiches de ce dossier et garder les identifiants retirés en alias", isOn: $agreed)
                    }
                    .settingsRow()
                }
                .settingsStyle()
                .navigationTitle("Confirmer la fusion")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Annuler") { preview = nil } }
                    ToolbarItem(placement: .confirmationAction) { Button("Fusionner") { merge(item.value) }.disabled(!agreed) }
                }
            }
            .presentationDetents([.medium])
        }
        .confirmationDialog("Garder ces artistes distincts ?", isPresented: $dismissing, titleVisibility: .visible) {
            Button("Garder distincts") { dismissGroup() }
        } message: {
            Text("Ce groupe est écarté pour ces versions des fiches. Si l'une d'elles change, il pourra revenir.")
        }
        .confirmationDialog("Défaire cette réunion ?", isPresented: $undoing, titleVisibility: .visible) {
            Button("Défaire", role: .destructive) { undoJoin() }
        } message: {
            Text("Les fiches réunies redeviennent distinctes, avec leurs crédits.")
        }
        .serverAlert($alert)
        .task {
            detail = try? await client.json("GET", "/library/artists/duplicate-groups/\(id)")
            survivor = detail?["recommended_survivor_id"]?.string ?? ""
        }
    }

    private var request: [String: JSON] {
        [
            "source_artist_ids": .array((detail?["members"]?.array ?? []).compactMap { $0["id"] }),
            "surviving_artist_id": .string(survivor),
            "expected_revisions": detail?["member_revisions"] ?? .object([:]),
        ]
    }

    private func mergePreview() {
        Task {
            do {
                agreed = false
                preview = try await client.json("POST", "/library/artists/merge-preview", body: .object(request))
            } catch {
                alert = ServerAlert(title: "Aperçu impossible", message: error.localizedDescription)
            }
        }
    }

    private func merge(_ preview: JSON) {
        var body = request
        body["preview_token"] = preview["preview_token"] ?? .null
        body["provider_choice"] = .string(keepSurvivorIdentity ? "retain_survivor" : "detach")
        body["idempotency_key"] = .string(UUID().uuidString.lowercased())
        Task {
            do {
                _ = try await client.json("POST", "/library/artists/merge", body: .object(body))
                self.preview = nil
                await changed()
                dismiss()
            } catch {
                self.preview = nil
                alert = ServerAlert(title: "Fusion refusée",
                                    message: "Les fiches ont changé depuis l'aperçu : refais un aperçu.\n\(error.localizedDescription)")
            }
        }
    }

    private func undoJoin() {
        Task {
            do {
                _ = try await client.json("POST", "/library/artists/duplicate-groups/\(id)/undo")
                await changed()
                dismiss()
            } catch {
                alert = ServerAlert(title: "Impossible de défaire", message: error.localizedDescription)
            }
        }
    }

    private func dismissGroup() {
        Task {
            do {
                _ = try await client.json("POST", "/library/artists/duplicate-groups/\(id)/dismiss",
                                          body: .object(["expected_member_revisions": detail?["member_revisions"] ?? .object([:])]))
                await changed()
                dismiss()
            } catch {
                alert = ServerAlert(title: "Refusé", message: error.localizedDescription)
            }
        }
    }
}
