import SwiftUI

/// Une pastille d'icône, comme dans l'app Réglages : un symbole blanc sur une
/// couleur, ou le vrai logo d'un service.
struct IconTile: View {
    enum Glyph {
        case symbol(String)
        /// Un logo en couleurs, posé sur une pastille sombre.
        case logo(String)
        /// Un logo monochrome, en blanc sur la couleur de la marque.
        case mark(String)
    }

    let glyph: Glyph
    var color: Color = .sage

    init(symbol: String, color: Color = .sage) {
        glyph = .symbol(symbol)
        self.color = color
    }

    init(_ glyph: Glyph, color: Color = .sage) {
        self.glyph = glyph
        self.color = color
    }

    var body: some View {
        Group {
            switch glyph {
            case let .symbol(name):
                Image(systemName: name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(color.gradient, in: .rect(cornerRadius: 8))
            case let .logo(name):
                Image(name).resizable().scaledToFit()
                    .padding(4)
                    .frame(width: 30, height: 30)
                    .background(Color.base300, in: .rect(cornerRadius: 8))
            case let .mark(name):
                Image(name).resizable().scaledToFit()
                    .foregroundStyle(.white)
                    .padding(6)
                    .frame(width: 30, height: 30)
                    .background(color.gradient, in: .rect(cornerRadius: 8))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08)))
    }
}

extension View {
    /// Les listes de réglages aux couleurs de DroppedNeedle : cartes vert sombre sur fond vert-noir.
    func settingsStyle() -> some View {
        scrollContentBackground(.hidden)
            #if targetEnvironment(macCatalyst)
            // Le Mac ouvre un grand vide au-dessus d'une première section sans titre.
            .listSectionSpacing(.compact)
            .disclosureGroupStyle(TrailingDisclosureStyle())
            #endif
            .background {
                ZStack {
                    Color.base100
                    RadialGradient(colors: [Color.sage.opacity(0.14), .clear], center: .top, startRadius: 0, endRadius: 420)
                }
                .ignoresSafeArea()
            }
            .tint(.sage)
    }

    func settingsRow() -> some View {
        listRowBackground(Color.base200)
            .buttonStyle(SettingsActionStyle())
            .macRowSpacing()
    }

    /// Le Mac colle les lignes de liste les unes aux autres : on leur rend l'air de l'iPhone.
    func macRowSpacing() -> some View {
        #if targetEnvironment(macCatalyst)
        listRowInsets(.vertical, 8)
        #else
        self
        #endif
    }
}

/// Les actions des réglages, comme dans l'app Réglages : texte blanc et icône
/// vert sauge ; une action destructive est rouge, icône comprise.
struct SettingsActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ActionBody(configuration: configuration)
    }

    private struct ActionBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let destructive = configuration.role == .destructive
            configuration.label
                .labelStyle(ActionLabel(color: destructive ? .red : .sage))
                .foregroundStyle(destructive ? Color.red : Color.primary)
                .contentShape(.rect)
                .opacity(enabled ? (configuration.isPressed ? 0.5 : 1) : 0.4)
        }
    }

    private struct ActionLabel: LabelStyle {
        let color: Color

        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 14) {
                configuration.icon.foregroundStyle(color).frame(width: 26)
                configuration.title
            }
        }
    }
}

// MARK: Description d'un formulaire

/// Un champ d'un réglage du serveur, repéré par son chemin JSON (« a.b »).
struct Field {
    enum Kind {
        case toggle
        case text
        /// Les secrets reviennent masqués du serveur ; on les renvoie tels quels si on n'y touche pas.
        case secret
        case number
        case url
        case choice([(value: String, label: String)])
        /// Un choix parmi des valeurs numériques (durées, seuils).
        case numberChoice([(value: Double, label: String)])
        /// Plusieurs valeurs cochées dans une liste de textes.
        case multi([(value: String, label: String)])
        /// Une liste de textes, un par ligne.
        case lines
    }

    let key: String
    let label: String
    var kind: Kind = .text
    var help: String?
}

struct FormSection {
    var title: String?
    let fields: [Field]
    var footer: String?
}

/// Un bouton d'action du serveur : vérifier une connexion, synchroniser, vider un cache…
struct FormAction {
    let title: String
    let symbol: String
    let method: String
    let path: String
    /// Envoie le formulaire en cours, pour tester ce qu'on vient de saisir.
    var sendsForm = false
    var destructive = false
}

/// Un formulaire lu par un GET et enregistré par un PUT du même objet.
struct FormSpec {
    let load: String
    var save: String?
    var saveMethod = "PUT"
    let sections: [FormSection]
    var actions: [FormAction] = []
}

// MARK: Formulaire

/// Un réglage du serveur rendu en natif depuis sa description.
struct FormPanel: View {
    let title: String
    let spec: FormSpec

    @Environment(\.client) private var client
    @State private var value: JSON?
    @State private var original: JSON?
    @State private var error: String?
    @State private var saving = false
    @State private var running: String?
    @State private var result: (title: String, message: String)?

    var body: some View {
        Form {
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.yellow) }
                    .settingsRow()
            }
            if value != nil {
                ForEach(Array(spec.sections.enumerated()), id: \.offset) { _, section in
                    Section {
                        ForEach(section.fields, id: \.key) { field in
                            row(field).settingsRow()
                        }
                    } header: {
                        if let title = section.title { Text(title) }
                    } footer: {
                        if let footer = section.footer { Text(footer) }
                    }
                }
                if !spec.actions.isEmpty {
                    Section {
                        ForEach(spec.actions, id: \.path) { action in
                            Button(role: action.destructive ? .destructive : nil) { run(action) } label: {
                                HStack {
                                    Label(action.title, systemImage: action.symbol)
                                    Spacer()
                                    if running == action.path { ProgressView() }
                                }
                            }
                            .disabled(running != nil)
                            .settingsRow()
                        }
                    }
                }
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
        .settingsStyle()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if spec.save != nil {
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Enregistrer") { save() }.disabled(value == original)
                    }
                }
            }
        }
        .alert(result?.title ?? "", isPresented: .constant(result != nil)) {
            Button("OK") { result = nil }
        } message: {
            Text(result?.message ?? "")
        }
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func row(_ field: Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch field.kind {
            case .toggle:
                Toggle(field.label, isOn: binding(field.key, \.bool, false, JSON.bool))
            case .text, .url:
                LabeledContent(field.label) {
                    TextField(field.label, text: binding(field.key, \.string, "", JSON.string))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(field.kind.isURL ? .URL : .default)
                }
            case .secret:
                LabeledContent(field.label) {
                    SecureField("Non défini", text: binding(field.key, \.string, "", JSON.string))
                        .multilineTextAlignment(.trailing)
                }
            case .number:
                LabeledContent(field.label) {
                    TextField(field.label, value: binding(field.key, \.number, 0, JSON.number), format: .number)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                }
            case let .choice(options):
                Picker(field.label, selection: binding(field.key, \.string, "", JSON.string)) {
                    ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
                }
            case let .numberChoice(options):
                Picker(field.label, selection: binding(field.key, \.number, 0, JSON.number)) {
                    ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
                }
            case let .multi(options):
                Text(field.label)
                ForEach(options, id: \.value) { option in
                    let selected = (value?[field.key]?.array ?? []).contains(.string(option.value))
                    Button {
                        var items = value?[field.key]?.array ?? []
                        if selected { items.removeAll { $0 == .string(option.value) } } else { items.append(.string(option.value)) }
                        value?[field.key] = .array(items)
                    } label: {
                        HStack {
                            Text(option.label).foregroundStyle(.primary)
                            Spacer()
                            if selected { Image(systemName: "checkmark").foregroundStyle(Color.sage) }
                        }
                    }
                }
            case .lines:
                Text(field.label)
                TextEditor(text: Binding(
                    get: { (value?[field.key]?.array ?? []).compactMap(\.string).joined(separator: "\n") },
                    set: { text in
                        value?[field.key] = .array(text.split(separator: "\n").map { .string(String($0)) })
                    }
                ))
                .frame(minHeight: 80)
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
            }
            if let help = field.help {
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func binding<Value>(_ key: String, _ read: KeyPath<JSON, Value?>, _ fallback: Value,
                                _ write: @escaping (Value) -> JSON) -> Binding<Value> {
        Binding(get: { value?[key]?[keyPath: read] ?? fallback }, set: { value?[key] = write($0) })
    }

    private func load() async {
        do {
            let loaded = try await client.json("GET", spec.load)
            value = loaded
            original = loaded
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() {
        guard let value, let path = spec.save else { return }
        saving = true
        Task {
            do {
                let saved = try await client.json(spec.saveMethod, path, body: value)
                // Certaines routes renvoient l'objet enregistré, d'autres rien.
                if case .object = saved { self.value = saved; original = saved } else { original = value }
                result = ("Enregistré", "Le serveur a pris en compte les changements.")
            } catch {
                result = ("Échec de l'enregistrement", error.localizedDescription)
            }
            saving = false
        }
    }

    private func run(_ action: FormAction) {
        running = action.path
        Task {
            do {
                let response = try await client.json(action.method, action.path, body: action.sendsForm ? value : nil)
                result = (action.title, Self.summary(of: response))
            } catch {
                result = (action.title, error.localizedDescription)
            }
            running = nil
        }
    }

    /// Ce que le serveur répond à une action, en une phrase.
    static func summary(of response: JSON) -> String {
        for key in ["message", "detail", "redirect_uri", "status"] {
            if let text = response[key]?.string, !text.isEmpty { return text }
        }
        if let ok = response["valid"]?.bool ?? response["success"]?.bool ?? response["ok"]?.bool {
            return ok ? "C'est bon." : "Ça n'a pas marché."
        }
        return "Fait."
    }
}

private extension Field.Kind {
    var isURL: Bool { if case .url = self { true } else { false } }
}

// MARK: Composants des contrôles

/// Des chiffres alignés en grille, valeur au-dessus, libellé dessous.
struct StatGrid: View {
    let items: [(label: String, value: Int)]
    var columns = 3

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: columns), spacing: 14) {
            ForEach(items.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 2) {
                    Text(items[index].value.formatted()).font(.display(22, relativeTo: .title3)).monospacedDigit()
                    Text(items[index].label).font(.caption).foregroundStyle(.secondary).oneLine().minimumScaleFactor(0.8)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Des filtres en pilules, posés sur le dégradé : la pilule choisie est pleine.
struct FilterChips: View {
    let options: [(value: String, label: String)]
    @Binding var selection: String

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(options, id: \.value) { option in
                    let selected = option.value == selection
                    Button { selection = option.value } label: {
                        Text(option.label)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .foregroundStyle(selected ? Color.base100 : .primary)
                            .background { if selected { Capsule().fill(Color.sage) } }
                            .glassEffect(selected ? .identity : .regular, in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
    }
}

/// Un champ de recherche en pilule de verre.
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var submit: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(submit)
            if !text.isEmpty {
                Button { text = ""; submit() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }
}

extension View {
    /// Une ligne de liste posée directement sur le dégradé, sans carte.
    func bareRow() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }
}

#if targetEnvironment(macCatalyst)
/// Le chevron à droite, comme sur l'iPhone : celui du Mac, à gauche, mord sur les icônes.
struct TrailingDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { withAnimation(.snappy) { configuration.isExpanded.toggle() } } label: {
            HStack {
                configuration.label
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        if configuration.isExpanded { configuration.content }
    }
}
#endif
