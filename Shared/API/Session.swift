import CryptoKit
import Foundation
import Observation
import Security
import SwiftUI

/// La connexion au serveur : l'adresse dans les préférences, le jeton dans le
/// trousseau. `client` vaut nil tant qu'on n'est pas connecté.
@Observable
final class Session {
    /// La même session pour l'app, Siri et CarPlay.
    static let shared = Session()

    #if DEBUG
    static let defaultServer = "https://diffusion.tail1c4018.ts.net:8454"
    #else
    // ponytail: le champ Serveur s'ouvre sur « https:// », l'utilisateur complète.
    static let defaultServer = "https://"
    #endif

    private(set) var client: DroppedNeedle?
    /// Le compte connecté ; son rôle ouvre l'administration.
    private(set) var user: User?
    var server: String

    var isAdmin: Bool { user?.role == "admin" }

    init() {
        #if DEBUG
        // Pour les tests sur simulateur : un jeton déposé dans Documents/token-import est
        // rangé dans le trousseau puis effacé, sans passer par la saisie au clavier.
        let drop = URL.documentsDirectory.appending(path: "token-import")
        if let token = try? String(contentsOf: drop, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            Keychain.token = token
            try? FileManager.default.removeItem(at: drop)
        }
        #endif
        server = UserDefaults.standard.string(forKey: "server") ?? Self.defaultServer
        if let url = URL(string: server), let token = Keychain.token {
            client = DroppedNeedle(server: url, token: token)
        }
    }

    func login(username: String, password: String) async throws {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespaces)) else {
            throw URLError(.badURL)
        }
        let auth = try await DroppedNeedle(server: url).login(username: username, password: password)
        guard let token = auth.token else { throw DroppedNeedle.Failure.status(0, "Le serveur n'a pas renvoyé de jeton.") }
        signIn(url, token: token)
        user = auth.user
    }

    private func signIn(_ url: URL, token: String) {
        UserDefaults.standard.set(url.absoluteString, forKey: "server")
        Keychain.token = token
        client = DroppedNeedle(server: url, token: token)
    }

    #if !os(tvOS)
    /// Connexion par le navigateur (App Connect) : le mot de passe ne passe pas par l'app, et le serveur
    /// donne à cet appareil sa propre session, qu'on retire dans Profil › Sessions.
    /// `authenticate` ouvre la page du serveur et rend l'adresse de retour.
    func connect(device: String, authenticate: (URL) async throws -> URL) async throws {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespaces)), url.host() != nil else {
            throw URLError(.badURL)
        }
        let api = DroppedNeedle(server: url)
        let verifier = Self.randomToken()
        let state = Self.randomToken()
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        guard let page = api.appConnectURL(challenge: challenge, state: state, device: device) else { throw URLError(.badURL) }
        let back = URLComponents(url: try await authenticate(page), resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? { back.first { $0.name == name }?.value }
        guard item("state") == state else { throw Self.connectFailure("La réponse ne correspond pas à cette demande. Réessaie.") }
        if item("error") == "access_denied" { throw CancellationError() }
        guard let code = item("code") else { throw Self.connectFailure("Le serveur a refusé la demande (\(item("error") ?? "sans code")).") }
        let token: AppConnectToken
        do {
            token = try await api.appConnectToken(code: code, verifier: verifier)
        } catch DroppedNeedle.Failure.status(_, "invalid_client") {
            throw Self.connectFailure("Platine n'est pas autorisée sur ce serveur : l'admin l'ajoute dans Réglages › Applis connectées.")
        }
        guard token.credentialKind == "device_session" else {
            throw Self.connectFailure("Le serveur donne à Platine un mot de passe Subsonic : l'admin doit choisir « Device session » pour elle.")
        }
        signIn(url, token: token.accessToken)
    }

    private static func connectFailure(_ message: String) -> Error { DroppedNeedle.Failure.status(0, message) }

    /// 32 octets aléatoires en base64url : 43 caractères, comme le veut PKCE.
    private static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    #endif

    func refreshUser() async {
        if let me = try? await client?.me() { user = me }
    }

    func logout() {
        Keychain.token = nil
        try? FileManager.default.removeItem(at: DroppedNeedle.discoverCache)
        try? FileManager.default.removeItem(at: Cover.folder)
        try? FileManager.default.removeItem(at: DroppedNeedle.responses)
        // Ses recherches ne doivent pas rester pour le compte suivant.
        UserDefaults.standard.removeObject(forKey: "searchHistory")
        UserDefaults.standard.removeObject(forKey: "listenCounts")
        client = nil
        user = nil
    }
}

/// Le jeton de DroppedNeedle, seul secret de l'app.
enum Keychain {
    private static let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "fr.cbrunie.platine",
        kSecAttrAccount: "droppedneedle-token",
    ]

    static var token: String? {
        get {
            var result: AnyObject?
            var lookup = query
            lookup[kSecReturnData] = true
            guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data
            else { return fallback }
            return String(decoding: data, as: UTF8.self)
        }
        set {
            SecItemDelete(query as CFDictionary)
            fallback = nil
            guard let newValue else { return }
            var item = query
            item[kSecValueData] = Data(newValue.utf8)
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            if SecItemAdd(item as CFDictionary, nil) == errSecMissingEntitlement { fallback = newValue }
        }
    }

    #if DEBUG && targetEnvironment(macCatalyst)
    /// ponytail: une app Mac signée sans équipe Apple n'a pas droit au trousseau (-34018). En debug
    /// seulement, le jeton va alors dans un fichier lisible par le seul utilisateur. Disparaît dès
    /// qu'une équipe signe l'app : le trousseau accepte, et le fichier n'est plus jamais écrit.
    private static var fallback: String? {
        get { try? String(contentsOf: file, encoding: .utf8) }
        set {
            guard let newValue else { try? FileManager.default.removeItem(at: file); return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file.path, contents: Data(newValue.utf8), attributes: [.posixPermissions: 0o600])
        }
    }

    private static let file = URL.applicationSupportDirectory.appending(path: "Platine/token")
    #else
    private static var fallback: String? { get { nil } set {} }
    #endif
}

extension EnvironmentValues {
    /// Le client connecté, pour les vues qui suivent la connexion.
    @Entry var client = DroppedNeedle(server: URL(string: Session.defaultServer)!)
}
