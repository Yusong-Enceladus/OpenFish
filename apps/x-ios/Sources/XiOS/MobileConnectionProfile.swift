import Foundation
import Security

struct MobileConnectionProfile: Equatable, Sendable {
    let baseURL: URL
    let bearerToken: String?

    static let local = MobileConnectionProfile(
        baseURL: URL(string: "http://127.0.0.1:3080")!,
        bearerToken: nil
    )

    static func restored() -> MobileConnectionProfile {
        guard let raw = UserDefaults.standard.string(forKey: "OpenCodex.iPhone.hostURL"),
              let url = normalizedURL(raw) else { return .local }
        return MobileConnectionProfile(baseURL: url, bearerToken: MobileCredentialStore.token(for: url))
    }

    static func normalizedURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              components.scheme == "http" || components.scheme == "https",
              components.host != nil else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    func persist() throws {
        UserDefaults.standard.set(baseURL.absoluteString, forKey: "OpenCodex.iPhone.hostURL")
        if let bearerToken { try MobileCredentialStore.set(bearerToken, for: baseURL) }
        else { MobileCredentialStore.remove(for: baseURL) }
    }
}
private enum MobileCredentialStore {
    private static let service = "app.openfish.ios.host"
    private static let legacyService = "ai.deepseek.opencodex.iphone.host"

    static func token(for url: URL) -> String? {
        if let token = token(for: url, service: service) { return token }
        guard let token = token(for: url, service: legacyService) else { return nil }
        try? set(token, for: url)
        return token
    }

    private static func token(for url: URL, service: String) -> String? {
        var query = baseQuery(for: url, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ token: String, for url: URL) throws {
        let query = baseQuery(for: url)
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MobileApiError.transport("Keychain rejected the Host credential (\(status)).")
        }
    }

    static func remove(for url: URL) {
        SecItemDelete(baseQuery(for: url, service: service) as CFDictionary)
        SecItemDelete(baseQuery(for: url, service: legacyService) as CFDictionary)
    }

    private static func baseQuery(for url: URL, service: String = service) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: url.absoluteString,
        ]
    }
}
