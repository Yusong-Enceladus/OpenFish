import Foundation
import Security

struct NativeConnectionProfile: Equatable, Sendable {
    static let local = NativeConnectionProfile(
        baseURL: URL(string: "http://127.0.0.1:3080")!,
        bearerToken: nil
    )

    let baseURL: URL
    let bearerToken: String?

    var isLocal: Bool {
        let host = baseURL.host?.lowercased()
        return host == "localhost" || host == "::1" || host?.hasPrefix("127.") == true
    }

    static func restored() -> NativeConnectionProfile {
        guard let raw = UserDefaults.standard.string(forKey: "OpenCodex.hostURL"),
              let url = normalizedURL(raw) else { return .local }
        return NativeConnectionProfile(baseURL: url, bearerToken: NativeCredentialStore.token(for: url))
    }

    static func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
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
        UserDefaults.standard.set(baseURL.absoluteString, forKey: "OpenCodex.hostURL")
        if let bearerToken, !bearerToken.isEmpty {
            try NativeCredentialStore.setToken(bearerToken, for: baseURL)
        } else {
            NativeCredentialStore.removeToken(for: baseURL)
        }
    }
}

enum NativeCredentialStore {
    private static let service = "app.openfish.mac.remote"
    private static let legacyService = "ai.deepseek.opencodex.remote"

    private static func account(for url: URL) -> String {
        url.host.map { "\($0):\(url.port ?? (url.scheme == "https" ? 443 : 80))" }
            ?? url.absoluteString
    }

    static func token(for url: URL) -> String? {
        if let token = token(for: url, service: service) { return token }
        guard let token = token(for: url, service: legacyService) else { return nil }
        try? setToken(token, for: url)
        return token
    }

    private static func token(for url: URL, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: url),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setToken(_ token: String, for url: URL) throws {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: url),
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var inserted = key
            inserted.merge(attributes) { _, replacement in replacement }
            let addStatus = SecItemAdd(inserted as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw NativeCredentialError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw NativeCredentialError.keychain(status)
        }
    }

    static func removeToken(for url: URL) {
        for candidate in [service, legacyService] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: candidate,
                kSecAttrAccount as String: account(for: url),
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}

enum NativeCredentialError: Error, CustomStringConvertible {
    case keychain(OSStatus)

    var description: String {
        switch self {
        case let .keychain(status): return "Keychain rejected the remote credential (\(status))."
        }
    }
}
