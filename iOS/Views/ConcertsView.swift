import SwiftUI

/// Les concerts des artistes suivis, comme « Following › Events » sur le web.
struct ConcertsView: View {
    @Environment(\.client) private var client
    @State private var concerts: Concerts?
    @State private var cities: [ConcertCity] = []

    var body: some View {
        // Comme la page « Events » du web : les dates à venir, puis les villes où les chercher.
        List {
            Section("À venir") {
                if let concerts {
                    if !concerts.configured {
                        message("Pas de source de concerts", "Un admin doit brancher Ticketmaster ou Skiddle dans les réglages.")
                    } else if concerts.items.isEmpty {
                        message("Aucun concert en vue", "Aucune date pour tes artistes suivis autour de tes villes.")
                    } else {
                        ForEach(concerts.items) { ConcertRow(concert: $0) }
                    }
                } else {
                    SkeletonRows(count: 3)
                }
            }
            .settingsRow()

            Section {
                NavigationLink { CitiesView() } label: {
                    LabeledContent("Mes villes") {
                        Text(cities.isEmpty ? "Aucune" : cities.map(\.cityName).joined(separator: ", ")).lineLimit(1)
                    }
                }
            } footer: {
                Text("Les concerts des artistes suivis sont cherchés autour de ces villes.")
            }
            .settingsRow()
        }
        .settingsStyle()
        .navigationTitle("Concerts")
        .task { await load() }
        .refreshable { await load() }
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        async let list = try? client.concerts()
        async let places = try? client.concertCities().items
        concerts = await list ?? Concerts(configured: true, items: [])
        cities = await places ?? []
    }
}
