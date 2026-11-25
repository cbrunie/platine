import SwiftUI

/// La connexion, aux couleurs de DroppedNeedle : le grand disque du lecteur
/// déborde en haut et tourne, puis le serveur et le compte sous du verre.
struct LoginView: View {
    @Environment(Session.self) private var session
    @State private var username = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case server, username, password }

    var body: some View {
        @Bindable var session = session
        GeometryReader { geometry in
            // Sur iPad, le formulaire garde une largeur de téléphone.
            let side = min(geometry.size.width, 520) * 1.25
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 6) {
                        Text("Platine").font(.display(48, relativeTo: .largeTitle))
                        Text("Ta platine pour DroppedNeedle").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 10)

                    VStack(spacing: 0) {
                        field("server.rack") {
                            TextField("Serveur", text: $session.server)
                                .keyboardType(.URL)
                                .textContentType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focus, equals: .server)
                                .submitLabel(.next)
                                .onSubmit { focus = .username }
                        }
                        separator
                        field("person.fill") {
                            TextField("Identifiant", text: $username)
                                .textContentType(.username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focus, equals: .username)
                                .submitLabel(.next)
                                .onSubmit { focus = .password }
                        }
                        separator
                        field("lock.fill") {
                            SecureField("Mot de passe", text: $password)
                                .textContentType(.password)
                                .focused($focus, equals: .password)
                                .submitLabel(.go)
                                .onSubmit(signIn)
                        }
                    }
                    #if !os(tvOS)
                    // Sur Apple TV, les champs ont déjà leur propre fond sous le focus.
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    #endif

                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.yellow)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button(action: signIn) {
                        Group {
                            if working { ProgressView().tint(Color.base100) } else { Text("Poser l'aiguille").font(.headline) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Color.sage)
                    .foregroundStyle(Color.base100)
                    .controlSize(.large)
                    // Toujours en sauge, lisible : grisé, le verre rendait le texte illisible (surtout sur Mac).
                    // `signIn` ignore déjà un formulaire incomplet.
                    .disabled(working)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 520)
                .padding(.top, side * 0.62)
                .padding(.bottom, 40)
                .background(alignment: .top) {
                    // Le disque du lecteur, coupé par le haut de l'écran.
                    Turntable(cover: nil, isPlaying: true)
                        .frame(width: side, height: side)
                        .offset(y: -side * 0.45)
                        .frame(maxWidth: .infinity)
                        .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
        }
        .background {
            ZStack {
                Color.base100
                RadialGradient(colors: [Color.sage.opacity(0.18), .clear], center: .top, startRadius: 0, endRadius: 500)
            }
            .ignoresSafeArea()
        }
    }

    private func field(_ symbol: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).foregroundStyle(Color.sage).frame(width: 22)
            content()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var separator: some View {
        #if !os(tvOS)
        Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5).padding(.leading, 54)
        #endif
    }

    private func signIn() {
        guard !username.isEmpty, !password.isEmpty else { return }
        working = true
        error = nil
        Task {
            do {
                try await session.login(username: username, password: password)
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
