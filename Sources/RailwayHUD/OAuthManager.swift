import AppKit
import CryptoKit
import Foundation
import Security

/// Handles Railway OAuth 2.0 with PKCE (RFC 8252 — OAuth for Native Apps).
///
/// **One-time setup:** Register an OAuth application at
/// railway.app → Workspace → Settings → Developer → OAuth Applications.
/// Set the redirect URI to `com.local.railway-hud://oauth/callback`.
/// Paste the resulting Client ID into `clientID` below.
final class OAuthManager: NSObject {
    static let shared = OAuthManager()
    private override init() {}

    // ← Replace with your Railway OAuth app's Client ID after registering it.
    static let clientID = "rlwy_oaci_ps1TNBurKYH4IOnbqxTtBk7v"
    private static let callbackScheme = "com.local.railway-hud"

    private let discoveryURL = URL(string: "https://backboard.railway.com/oauth/.well-known/openid-configuration")!
    private let redirectURI  = "\(callbackScheme)://oauth/callback"
    private let tokenRefreshLeeway: TimeInterval = 5 * 60
    private let fallbackAccessTokenLifetime: TimeInterval = 60 * 60

    private var codeVerifier = ""
    private var authState = ""
    private let refreshQueue = DispatchQueue(label: "com.railway-hud.oauth-refresh")
    private var refreshCompletions: [(Bool) -> Void] = []
    private var isRefreshing = false

    /// Called on the main queue when OAuth completes successfully.
    var onSuccess: (() -> Void)?

    // MARK: - Public API

    func startFlow() {
        guard !Self.clientID.isEmpty else {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "OAuth not configured"
                alert.informativeText = """
                    Register an OAuth application at:
                    railway.app → Workspace → Settings → Developer → OAuth Applications

                    Set the redirect URI to com.local.railway-hud://oauth/callback, then paste \
                    the Client ID into OAuthManager.clientID and rebuild.
                    """
                alert.runModal()
            }
            return
        }

        codeVerifier = Self.randomBase64(bytes: 32)
        authState = Self.randomBase64(bytes: 24)
        Config.savePendingOAuth(state: authState, codeVerifier: codeVerifier)
        let challenge = Self.s256(codeVerifier)

        fetchDiscovery { [weak self] json in
            guard let self,
                  let authEP  = json?["authorization_endpoint"] as? String,
                  let authURL = URL(string: authEP),
                  var comps   = URLComponents(url: authURL, resolvingAgainstBaseURL: false)
            else { return }

            let queryItems = [
                URLQueryItem(name: "client_id",             value: Self.clientID),
                URLQueryItem(name: "response_type",         value: "code"),
                URLQueryItem(name: "redirect_uri",          value: self.redirectURI),
                URLQueryItem(name: "scope",                 value: "openid offline_access workspace:viewer project:viewer"),
                URLQueryItem(name: "state",                 value: self.authState),
                URLQueryItem(name: "code_challenge",        value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
            ]
            comps.queryItems = queryItems
            if let url = comps.url {
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    /// Called by the auth session, or by AppDelegate as a fallback when macOS delivers the callback URL.
    func handleCallback(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let expectedState = Config.readPendingOAuthState() ?? authState
        let storedCodeVerifier = Config.readPendingCodeVerifier() ?? codeVerifier

        if let oauthError = components.queryItems?.first(where: { $0.name == "error" })?.value {
            let description = components.queryItems?.first(where: { $0.name == "error_description" })?.value ?? ""
            Config.clearPendingOAuth()
            Self.showError("Railway error: \(oauthError)\(description.isEmpty ? "" : " — \(description)")")
            return
        }

        if let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value,
           !expectedState.isEmpty,
           returnedState != expectedState {
            Config.clearPendingOAuth()
            Self.showError("Invalid OAuth state. Please try connecting again.")
            return
        }

        guard !storedCodeVerifier.isEmpty else {
            Config.clearPendingOAuth()
            Self.showError("Missing PKCE verifier. Please try connecting again.")
            return
        }

        authState = expectedState
        codeVerifier = storedCodeVerifier
        guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value else { return }
        exchangeCode(code)
    }

    func withValidAccessToken(forceRefresh: Bool = false,
                              completion: @escaping (String?) -> Void) {
        if !forceRefresh, let accessToken = Config.readOAuthToken() {
            if !accessTokenNeedsRefresh() || hasUsableAccessTokenWithoutRefresh() {
                completion(accessToken)
                return
            }
        }

        refreshToken(force: forceRefresh) { success in
            if success {
                completion(Config.readOAuthToken())
                return
            }
            if !forceRefresh,
               let accessToken = Config.readOAuthToken(),
               !self.accessTokenHasExpired() {
                completion(accessToken)
                return
            }
            completion(nil)
        }
    }

    func refreshToken(force: Bool = false, completion: @escaping (Bool) -> Void) {
        if !force,
           let accessToken = Config.readOAuthToken(),
           !accessTokenNeedsRefresh() {
            completion(!accessToken.isEmpty)
            return
        }
        if !force, hasUsableAccessTokenWithoutRefresh() {
            completion(true)
            return
        }

        refreshQueue.async {
            self.refreshCompletions.append(completion)
            guard !self.isRefreshing else { return }
            self.isRefreshing = true
            self.performRefresh()
        }
    }

    // MARK: - Token exchange

    private func exchangeCode(_ code: String) {
        fetchDiscovery { [weak self] json in
            guard let self,
                  let tokenEP  = json?["token_endpoint"] as? String,
                  let tokenURL = URL(string: tokenEP) else { return }
            let params = [
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": self.redirectURI,
                "client_id": Self.clientID,
                "code_verifier": self.codeVerifier,
            ]

            self.performTokenRequest(url: tokenURL, parameters: params) { result in
                switch result {
                case .success(let payload):
                    self.authState = ""
                    self.codeVerifier = ""
                    Config.clearPendingOAuth()
                    Config.saveOAuthTokens(
                        access: payload.accessToken,
                        refresh: payload.refreshToken,
                        expiresIn: payload.expiresIn ?? self.fallbackAccessTokenLifetime
                    )
                    DispatchQueue.main.async { self.onSuccess?() }
                case .failure(let message):
                    Config.clearPendingOAuth()
                    OAuthManager.showError(message.localizedDescription)
                }
            }
        }
    }

    // MARK: - Helpers

    private struct TokenPayload {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval?
    }

    private enum TokenRequestError: LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case .message(let text):
                return text
            }
        }
    }

    private func performRefresh() {
        guard let refresh = Config.readRefreshToken(), !refresh.isEmpty else {
            completeRefresh(success: false, clearTokens: false)
            return
        }

        fetchDiscovery { [weak self] json in
            guard let self,
                  let tokenEP = json?["token_endpoint"] as? String,
                  let tokenURL = URL(string: tokenEP) else {
                self?.completeRefresh(success: false, clearTokens: false)
                return
            }

            self.performTokenRequest(
                url: tokenURL,
                parameters: [
                    "grant_type": "refresh_token",
                    "refresh_token": refresh,
                    "client_id": Self.clientID,
                ]
            ) { result in
                switch result {
                case .success(let payload):
                    Config.saveOAuthTokens(
                        access: payload.accessToken,
                        refresh: payload.refreshToken ?? refresh,
                        expiresIn: payload.expiresIn ?? self.fallbackAccessTokenLifetime
                    )
                    self.completeRefresh(success: true, clearTokens: false)
                case .failure(let message):
                    let description = message.localizedDescription
                    let shouldClear = description.contains("invalid_grant") || description.contains("invalid_token")
                    self.completeRefresh(success: false, clearTokens: shouldClear)
                }
            }
        }
    }

    private func completeRefresh(success: Bool, clearTokens: Bool) {
        refreshQueue.async {
            if clearTokens {
                Config.clearOAuthTokens()
            }
            let completions = self.refreshCompletions
            self.refreshCompletions = []
            self.isRefreshing = false
            DispatchQueue.main.async {
                completions.forEach { $0(success) }
            }
        }
    }

    private func performTokenRequest(url: URL,
                                     parameters: [String: String],
                                     completion: @escaping (Result<TokenPayload, TokenRequestError>) -> Void) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncoded(parameters).data(using: .utf8)

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                completion(.failure(.message("Token exchange network error: \(error.localizedDescription)")))
                return
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data else {
                completion(.failure(.message("Token exchange: empty response")))
                return
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errCode = json["error"] as? String {
                let desc = json["error_description"] as? String ?? ""
                completion(.failure(.message("Railway error: \(errCode)\(desc.isEmpty ? "" : " — \(desc)")")))
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = json["access_token"] as? String else {
                let raw = String(data: data, encoding: .utf8) ?? "(unreadable)"
                completion(.failure(.message("Unexpected token response (\(statusCode)): \(raw)")))
                return
            }

            let refresh = json["refresh_token"] as? String
            let expiresIn = json["expires_in"] as? Double
            completion(.success(TokenPayload(accessToken: access, refreshToken: refresh, expiresIn: expiresIn)))
        }.resume()
    }

    private func accessTokenNeedsRefresh() -> Bool {
        guard let accessToken = Config.readOAuthToken(), !accessToken.isEmpty else { return true }
        guard let expiry = Config.readAccessTokenExpiry() else {
            return Config.readRefreshToken() != nil
        }
        return expiry.timeIntervalSinceNow <= tokenRefreshLeeway
    }

    private func accessTokenHasExpired() -> Bool {
        guard let expiry = Config.readAccessTokenExpiry() else { return false }
        return expiry.timeIntervalSinceNow <= 0
    }

    private func hasUsableAccessTokenWithoutRefresh() -> Bool {
        guard Config.readRefreshToken() == nil else { return false }
        guard let accessToken = Config.readOAuthToken(), !accessToken.isEmpty else { return false }
        return !accessTokenHasExpired()
    }

    private static func showError(_ message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText    = "OAuth error"
            alert.informativeText = message
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func fetchDiscovery(completion: @escaping ([String: Any]?) -> Void) {
        URLSession.shared.dataTask(with: discoveryURL) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            completion(json)
        }.resume()
    }

    private static func formEncoded(_ parameters: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return parameters
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .sorted()
            .joined(separator: "&")
    }

    private static func randomBase64(bytes count: Int) -> String {
        var buf = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &buf)
        return Data(buf).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func s256(_ input: String) -> String {
        Data(SHA256.hash(data: Data(input.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
