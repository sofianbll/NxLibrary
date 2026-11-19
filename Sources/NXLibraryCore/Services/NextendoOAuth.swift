import CryptoKit
import Foundation
import Security

public enum NextendoError: LocalizedError, Equatable {
    case clientID, browser, timeout, authorization, service, expired, storage, signedOut

    public var errorDescription: String? {
        switch self {
        case .clientID: return L10n.text("Enter a valid public Nextendo client ID in Online services.")
        case .browser: return L10n.text("Could not open the Nextendo sign-in window.")
        case .timeout: return L10n.text("Nextendo sign-in timed out. Try again.")
        case .authorization: return L10n.text("Nextendo did not authorize sign-in. Check the client ID and its permissions.")
        case .service: return L10n.text("Could not check the Nextendo account. Try again.")
        case .expired: return L10n.text("Nextendo sign-in expired. Sign in again.")
        case .storage: return L10n.text("Could not access the shared Nextendo sign-in. Close any running games and try again.")
        case .signedOut: return L10n.text("Sign in to Nextendo in Online services before playing online.")
        }
    }
}

/// One authorization request. The browser never sees the verifier; the token endpoint never gets the state.
public struct NextendoAuthorization: Sendable {
    public let clientID: String
    public let redirect: URL
    public let url: URL
    let verifier: String
    let state: String

    public init(clientID: String, port: UInt16) throws {
        guard Self.validClientID(clientID) else { throw NextendoError.clientID }
        self.clientID = clientID
        verifier = try Self.random(bytes: 32)
        state = try Self.random(bytes: 16)
        redirect = URL(string: "http://127.0.0.1:\(port)/callback")!
        var request = URLComponents(string: "https://nextendo.network/oauth/authorize")!
        // Request the same permissions the host uses, including `profil` for the player's Mii.
        request.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect.absoluteString),
            .init(name: "scope", value: "identity friends game.matchmaking presence profil"),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: Self.challenge(verifier)),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        url = request.url!
    }

    public static func validClientID(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    static func challenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func random(bytes: Int) throws -> String {
        var data = Data(count: bytes)
        guard data.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }) == errSecSuccess
        else { throw NextendoError.browser }
        return base64URL(data)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Ignore unrelated loopback traffic; report a refusal only for a callback with our state.
    public func code(from callback: URL) throws -> String? {
        guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              parts.scheme == redirect.scheme, parts.host == redirect.host, parts.port == redirect.port,
              parts.percentEncodedPath == redirect.path, parts.user == nil, parts.password == nil, parts.fragment == nil,
              let fields = parts.queryItems else { return nil }
        guard fields.filter({ $0.name == "state" }).map(\.value) == [state] else { return nil }
        let codes = fields.filter { $0.name == "code" }
        if fields.contains(where: { $0.name == "error" }) { throw NextendoError.authorization }
        guard codes.count == 1, let code = codes.first?.value, !code.isEmpty, code.utf8.count <= 4096 else { return nil }
        return code
    }
}

public struct NextendoOAuth {
    // Use the same endpoint as nxnative for both authorization-code and refresh grants.
    private static let tokenEndpoint = URL(string: "https://nextendo.network/api/oauth/token")!
    private static let userInfoEndpoint = URL(string: "https://nextendo.network/api/oauth/userinfo")!
    public let store: NextendoTokenStore
    private let send: (URLRequest) async throws -> (Data, URLResponse)

    public init(store: NextendoTokenStore = NextendoTokenStore()) {
        self.init(store: store) { request in
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForResource = 12
            let session = URLSession(configuration: config)
            defer { session.finishTasksAndInvalidate() }
            return try await BoundedDownload.data(for: request, session: session, limit: 65_536)
        }
    }

    init(store: NextendoTokenStore, send: @escaping (URLRequest) async throws -> (Data, URLResponse)) {
        self.store = store
        self.send = send
    }

    public func signIn(_ attempt: NextendoAuthorization, code: String) async throws -> String {
        guard let name = try await store.withLock({ file in
            let token = try await exchange(clientID: attempt.clientID, grant: "authorization_code", [
                "code": code, "redirect_uri": attempt.redirect.absoluteString, "code_verifier": attempt.verifier,
            ])
            let name = try await userName(clientID: attempt.clientID, access: token.access)
            try file.write(token.refresh)
            return name
        }) else { throw NextendoError.storage }
        return name
    }

    /// Checking an account rotates the token under the same lock the engine takes.
    public func accountName(clientID: String) async throws -> String? {
        guard try store.hasToken() else { return nil }
        let access = try await store.withLock(create: false) { file -> String? in
            guard let refresh = try file.read() else { return nil }
            let token = try await exchange(clientID: clientID, grant: "refresh_token", ["refresh_token": refresh])
            try file.write(token.refresh)
            return token.access
        }
        guard let access = access ?? nil else { return nil }
        return try await userName(clientID: clientID, access: access)
    }

    public func signOut() async throws {
        try await store.withLock(create: false) { file in try file.write(nil) }
    }

    private struct Token: Decodable {
        let access: String
        let refresh: String
        enum CodingKeys: String, CodingKey {
            case access = "access_token", refresh = "refresh_token"
        }
    }

    private func exchange(clientID: String, grant: String, _ fields: [String: String]) async throws -> Token {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let fields = fields.merging(["client_id": clientID, "grant_type": grant]) { _, value in value }
        var request = try request(Self.tokenEndpoint, clientID: clientID)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: unreserved)!)"
        }.joined(separator: "&").utf8)
        let (body, status) = try await response(request)
        if status == 400 || status == 401,
           (try? JSONDecoder().decode(Refusal.self, from: body))?.error == "invalid_grant" {
            // Another front end may have signed in with a different client. Don't delete its credential.
            throw grant == "refresh_token" ? NextendoError.expired : NextendoError.authorization
        }
        if [400, 401, 403].contains(status) { throw NextendoError.authorization }
        guard status == 200, let token = try? JSONDecoder().decode(Token.self, from: body),
              !token.access.isEmpty, token.access.utf8.count <= 8192,
              token.access.utf8.allSatisfy({ (33...126).contains($0) }),
              NextendoTokenStore.valid(token.refresh) else { throw NextendoError.service }
        return token
    }

    private struct Refusal: Decodable { let error: String }
    private struct Account: Decodable {
        struct Identity: Decodable { let username: String }
        let username: String?
        let account: Identity?
        let identity: Identity?
    }

    private func userName(clientID: String, access: String) async throws -> String {
        var request = try request(Self.userInfoEndpoint, clientID: clientID)
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let (body, status) = try await response(request)
        guard status == 200, let account = try? JSONDecoder().decode(Account.self, from: body) else {
            throw NextendoError.service
        }
        let names = [account.username, account.account?.username, account.identity?.username].compactMap { $0 }
        guard let name = names.first, !name.isEmpty, name.count <= 128,
              name.rangeOfCharacter(from: .controlCharacters) == nil,
              names.allSatisfy({ $0 == name }) else { throw NextendoError.service }
        return name
    }

    private func request(_ endpoint: URL, clientID: String) throws -> URLRequest {
        guard NextendoAuthorization.validClientID(clientID) else { throw NextendoError.clientID }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue(clientID, forHTTPHeaderField: "X-Nextendo-Client-Id")
        return request
    }

    private func response(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await send(request)
            guard let http = response as? HTTPURLResponse, http.url == request.url else { throw NextendoError.service }
            return (data, http.statusCode)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NextendoError.service
        }
    }
}
