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
    private static let oauthBundleKey = "oauth_tokens"
    private static let legacyAccessTokenKey = "oauth_access_token"
    private static let legacyRefreshTokenKey = "oauth_refresh_token"

    // In-memory cache — avoids repeated keychain prompts within a single session.
    private static var _cachedTokens: OAuthTokenBundle? = nil
    private static var _hasLoadedTokens = false

    private struct OAuthTokenBundle: Codable {
        let accessToken: String?
        let refreshToken: String?
    }

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
        loadOAuthTokensIfNeeded()
        return _cachedTokens?.accessToken
    }

    static func readRefreshToken() -> String? {
        loadOAuthTokensIfNeeded()
        return _cachedTokens?.refreshToken
    }

    static func readAccessTokenExpiry() -> Date? {
        let seconds = UserDefaults.standard.double(forKey: accessTokenExpiryKey)
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func saveOAuthTokens(access: String, refresh: String?, expiresIn: TimeInterval?) {
        let bundle = OAuthTokenBundle(accessToken: access, refreshToken: refresh)
        _cachedTokens = bundle
        _hasLoadedTokens = true
        keychainWriteData(oauthBundleKey, value: encode(bundle))
        keychainDelete(legacyAccessTokenKey)
        keychainDelete(legacyRefreshTokenKey)
        if let expiresIn {
            UserDefaults.standard.set(Date().addingTimeInterval(expiresIn).timeIntervalSince1970, forKey: accessTokenExpiryKey)
        } else {
            UserDefaults.standard.removeObject(forKey: accessTokenExpiryKey)
        }
        NotificationCenter.default.post(name: sessionDidChangeNotification, object: nil)
    }

    static func clearOAuthTokens() {
        _cachedTokens = nil
        _hasLoadedTokens = true
        keychainDelete(oauthBundleKey)
        keychainDelete(legacyAccessTokenKey)
        keychainDelete(legacyRefreshTokenKey)
        UserDefaults.standard.removeObject(forKey: accessTokenExpiryKey)
        NotificationCenter.default.post(name: sessionDidChangeNotification, object: nil)
    }

    private static func clearExpiredAccessTokenOnlySession() {
        loadOAuthTokensIfNeeded()
        _cachedTokens = OAuthTokenBundle(accessToken: nil, refreshToken: _cachedTokens?.refreshToken)
        persistCachedOAuthTokens()
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

    private static func loadOAuthTokensIfNeeded() {
        guard !_hasLoadedTokens else { return }
        _hasLoadedTokens = true

        if let data = keychainReadData(oauthBundleKey),
           let bundle = decode(data) {
            _cachedTokens = bundle
            return
        }

        let legacyAccessToken = keychainReadString(legacyAccessTokenKey)
        let legacyRefreshToken = keychainReadString(legacyRefreshTokenKey)
        guard legacyAccessToken != nil || legacyRefreshToken != nil else {
            _cachedTokens = nil
            return
        }

        let migratedBundle = OAuthTokenBundle(accessToken: legacyAccessToken, refreshToken: legacyRefreshToken)
        _cachedTokens = migratedBundle
        persistCachedOAuthTokens()
        keychainDelete(legacyAccessTokenKey)
        keychainDelete(legacyRefreshTokenKey)
    }

    private static func persistCachedOAuthTokens() {
        if let bundle = _cachedTokens,
           bundle.accessToken != nil || bundle.refreshToken != nil {
            keychainWriteData(oauthBundleKey, value: encode(bundle))
        } else {
            keychainDelete(oauthBundleKey)
        }
    }

    private static func encode(_ bundle: OAuthTokenBundle) -> Data {
        (try? JSONEncoder().encode(bundle)) ?? Data()
    }

    private static func decode(_ data: Data) -> OAuthTokenBundle? {
        try? JSONDecoder().decode(OAuthTokenBundle.self, from: data)
    }

    private static func keychainReadString(_ key: String) -> String? {
        guard let data = keychainReadData(key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainReadData(_ key: String) -> Data? {
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
        return data
    }

    private static func keychainWriteData(_ key: String, value: Data) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: key,
        ]
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        } else {
            var add = query
            add[kSecValueData] = value
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
