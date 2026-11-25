import SwiftUI

/// La connexion sur Apple TV : de grands champs l'un sous l'autre, que la télécommande parcourt
/// de haut en bas, et la platine qui tourne à gauche.
struct TVLoginView: View {
    @Environment(Session.self) private var session
    @State private var username = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        @Bindable var session = session
        HStack(spacing: 120) {
            Turntable(cover: nil, isPlaying: true, showsArm: false)
                .frame(width: 640, height: 640)
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Platine").font(.display(64, relativeTo: .largeTitle))
                    Text("Ta platine pour DroppedNeedle").font(.title3).foregroundStyle(.secondary)
                }
                .padding(.bottom, 20)
                TextField("Serveur", text: $session.server)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Identifiant", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("Mot de passe", text: $password)
                    .textContentType(.password)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                }
                Button(action: signIn) {
                    Group {
                        if working { ProgressView() } else { Text("Poser l'aiguille") }
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(working || username.isEmpty || password.isEmpty)
            }
            .frame(width: 700)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                Color.base100
                RadialGradient(colors: [Color.sage.opacity(0.18), .clear], center: .topLeading, startRadius: 0, endRadius: 1200)
            }
            .ignoresSafeArea()
        }
    }

    private func signIn() {
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
