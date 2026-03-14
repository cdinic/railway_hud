import Foundation
import Security

/// Single source of truth for all shared constants and cross-cutting helpers.
enum Config {
    static let orderKey  = "com.railway-hud.serviceOrder"
    static let projectKey = "com.railway-hud.projectID"
    static let sessionDidChangeNotification = Notification.Name("com.railway-hud.sessionDidChange")
    static let projectDidChangeNotification = Notification.Name("com.railway-hud.projectDidChange")
    private static let accessTokenExpiryKey = "com.railway-hud.oauthAccessTokenExpiry"
    private static let oauthStateKey = "com.railway-hud.oauthState"
    private static let oauthCodeVerifierKey = "com.railway-hud.oauthCodeVerifier"

    private static let keychainService = "com.railway-hud"

    // In-memory cache — avoids repeated keychain prompts within a single session.
    private static var _cachedAccessToken:  String? = nil
    private static var _cachedRefreshToken: String? = nil

    static func readProjectID() -> String? {
        UserDefaults.standard.string(forKey: projectKey)
    }

    static func hasOAuthSession() -> Bool {
        if let refreshToken = readRefreshToken(), !refreshToken.isEmpty {
            return true
        }
        guard let accessToken = readOAuthToken(), !accessToken.isEmpty else {
            return false
        }
        guard let expiry = readAccessTokenExpiry() else {
            return true
        }
        guard expiry.timeIntervalSinceNow > 0 else {
            clearExpiredAccessTokenOnlySession()
            return false
        }
        return true
    }

    // MARK: - OAuth tokens (Keychain, cached in memory)

    static func readOAuthToken() -> String? {
        if _cachedAccessToken == nil { _cachedAccessToken = keychainRead("oauth_access_token") }
        return _cachedAccessToken
    }

    static func readRefreshToken() -> String? {
        if _cachedRefreshToken == nil { _cachedRefreshToken = keychainRead("oauth_refresh_token") }
        return _cachedRefreshToken
    }

    static func readAccessTokenExpiry() -> Date? {
        let seconds = UserDefaults.standard.double(forKey: accessTokenExpiryKey)
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func saveOAuthTokens(access: String, refresh: String?, expiresIn: TimeInterval?) {
        _cachedAccessToken  = access
        _cachedRefreshToken = refresh
        keychainWrite("oauth_access_token", value: access)
        if let r = refresh { keychainWrite("oauth_refresh_token", value: r) }
        if let expiresIn {
            UserDefaults.standard.set(Date().addingTimeInterval(expiresIn).timeIntervalSince1970, forKey: accessTokenExpiryKey)
        } else {
            UserDefaults.standard.removeObject(forKey: accessTokenExpiryKey)
        }
        NotificationCenter.default.post(name: sessionDidChangeNotification, object: nil)
    }

    static func clearOAuthTokens() {
        _cachedAccessToken  = nil
        _cachedRefreshToken = nil
        keychainDelete("oauth_access_token")
        keychainDelete("oauth_refresh_token")
        UserDefaults.standard.removeObject(forKey: accessTokenExpiryKey)
        NotificationCenter.default.post(name: sessionDidChangeNotification, object: nil)
    }

    private static func clearExpiredAccessTokenOnlySession() {
        _cachedAccessToken = nil
        keychainDelete("oauth_access_token")
        UserDefaults.standard.removeObject(forKey: accessTokenExpiryKey)
        NotificationCenter.default.post(name: sessionDidChangeNotification, object: nil)
    }

    static func savePendingOAuth(state: String, codeVerifier: String) {
        UserDefaults.standard.set(state, forKey: oauthStateKey)
        UserDefaults.standard.set(codeVerifier, forKey: oauthCodeVerifierKey)
    }

    static func readPendingOAuthState() -> String? {
        UserDefaults.standard.string(forKey: oauthStateKey)
    }

    static func readPendingCodeVerifier() -> String? {
        UserDefaults.standard.string(forKey: oauthCodeVerifierKey)
    }

    static func clearPendingOAuth() {
        UserDefaults.standard.removeObject(forKey: oauthStateKey)
        UserDefaults.standard.removeObject(forKey: oauthCodeVerifierKey)
    }

    // MARK: - Project selection

    static func saveProjectID(_ id: String) {
        UserDefaults.standard.set(id, forKey: projectKey)
        NotificationCenter.default.post(name: projectDidChangeNotification, object: nil)
    }

    static func clearProjectID() {
        UserDefaults.standard.removeObject(forKey: projectKey)
        NotificationCenter.default.post(name: projectDidChangeNotification, object: nil)
    }

    // MARK: - Keychain

    private static func keychainRead(_ key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: key,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainWrite(_ key: String, value: String) {
        let data  = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: key,
        ]
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var add = query
            add[kSecValueData] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func keychainDelete(_ key: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
