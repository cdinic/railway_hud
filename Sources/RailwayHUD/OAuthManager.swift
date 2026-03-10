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

    private var codeVerifier = ""

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
        let challenge = Self.s256(codeVerifier)

        fetchDiscovery { [weak self] json in
            guard let self,
                  let authEP  = json?["authorization_endpoint"] as? String,
                  let authURL = URL(string: authEP),
                  var comps   = URLComponents(url: authURL, resolvingAgainstBaseURL: false)
            else { return }

            comps.queryItems = [
                URLQueryItem(name: "client_id",             value: Self.clientID),
                URLQueryItem(name: "response_type",         value: "code"),
                URLQueryItem(name: "redirect_uri",          value: self.redirectURI),
                URLQueryItem(name: "scope",                 value: "openid offline_access workspace:viewer project:viewer"),
                URLQueryItem(name: "code_challenge",        value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
            ]
            if let url = comps.url {
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    /// Called by the auth session, or by AppDelegate as a fallback when macOS delivers the callback URL.
    func handleCallback(url: URL) {
        guard let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        else { return }
        exchangeCode(code)
    }

    func refreshToken(completion: @escaping (Bool) -> Void) {
        guard let refresh = Config.readRefreshToken() else { completion(false); return }
        fetchDiscovery { json in
            guard let tokenEP  = json?["token_endpoint"] as? String,
                  let tokenURL = URL(string: tokenEP) else { completion(false); return }
            var req = URLRequest(url: tokenURL)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data([
                "grant_type=refresh_token",
                "refresh_token=\(refresh)",
                "client_id=\(Self.clientID)",
            ].joined(separator: "&").utf8)
            URLSession.shared.dataTask(with: req) { data, _, _ in
                guard let data,
                      let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let access  = json["access_token"] as? String else { completion(false); return }
                let newRefresh = json["refresh_token"] as? String ?? refresh
                Config.saveOAuthTokens(access: access, refresh: newRefresh)
                completion(true)
            }.resume()
        }
    }

    // MARK: - Token exchange

    private func exchangeCode(_ code: String) {
        fetchDiscovery { [weak self] json in
            guard let self,
                  let tokenEP  = json?["token_endpoint"] as? String,
                  let tokenURL = URL(string: tokenEP) else { return }
            var req = URLRequest(url: tokenURL)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data([
                "grant_type=authorization_code",
                "code=\(code)",
                "redirect_uri=\(self.redirectURI)",
                "client_id=\(Self.clientID)",
                "code_verifier=\(self.codeVerifier)",
            ].joined(separator: "&").utf8)

            URLSession.shared.dataTask(with: req) { data, _, error in
                if let error {
                    OAuthManager.showError("Token exchange network error: \(error.localizedDescription)")
                    return
                }
                guard let data else { OAuthManager.showError("Token exchange: empty response"); return }

                // Surface any error returned by Railway before trying to parse the token.
                if let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errCode = json["error"] as? String {
                    let desc = json["error_description"] as? String ?? ""
                    OAuthManager.showError("Railway error: \(errCode) — \(desc)")
                    return
                }

                guard let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let access = json["access_token"] as? String else {
                    let raw = String(data: data, encoding: .utf8) ?? "(unreadable)"
                    OAuthManager.showError("Unexpected token response: \(raw)")
                    return
                }

                let refresh = json["refresh_token"] as? String
                Config.saveOAuthTokens(access: access, refresh: refresh)
                DispatchQueue.main.async { self.onSuccess?() }
            }.resume()
        }
    }

    // MARK: - Helpers

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
