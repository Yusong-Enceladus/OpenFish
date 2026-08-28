import Foundation
import Security
import CryptoKit

struct MobileConnectionProfile: Equatable, Sendable {
    let baseURL: URL
    let bearerToken: String?
    let tlsFingerprint: String?

    init(baseURL: URL, bearerToken: String? = nil, tlsFingerprint: String? = nil) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.tlsFingerprint = tlsFingerprint
    }

    var isLocal: Bool {
        Self.isLoopbackHost(baseURL.host)
    }

    var requiresPairing: Bool {
        !isLocal && (bearerToken?.isEmpty != false || !Self.validFingerprint(tlsFingerprint))
    }

    static let local = MobileConnectionProfile(
        baseURL: URL(string: "http://127.0.0.1:3080")!,
        bearerToken: nil,
        tlsFingerprint: nil
    )

    static func restored() -> MobileConnectionProfile {
        guard let raw = UserDefaults.standard.string(forKey: "OpenCodex.iPhone.hostURL"),
              let url = normalizedURL(raw) else { return .local }
        return MobileConnectionProfile(
            baseURL: url,
            bearerToken: MobileCredentialStore.token(for: url),
            tlsFingerprint: MobileCredentialStore.fingerprint(for: url)
        )
    }

    static func normalizedURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              components.scheme == "http" || components.scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { return nil }
        let local = isLoopbackHost(url.host)
        guard local || url.scheme == "https" else { return nil }
        return url
    }

    func persist() throws {
        if isLocal {
            MobileCredentialStore.remove(for: baseURL)
        } else if let bearerToken, !bearerToken.isEmpty,
                  Self.validFingerprint(tlsFingerprint), let tlsFingerprint {
            do {
                try MobileCredentialStore.set(bearerToken, for: baseURL)
                try MobileCredentialStore.setFingerprint(tlsFingerprint, for: baseURL)
            } catch {
                MobileCredentialStore.remove(for: baseURL)
                throw error
            }
        } else {
            throw MobileApiError.transport("A remote Host requires HTTPS, a paired token, and its pinned TLS identity.")
        }
        UserDefaults.standard.set(baseURL.absoluteString, forKey: "OpenCodex.iPhone.hostURL")
    }

    func forgetAuthorization() -> MobileConnectionProfile {
        MobileCredentialStore.remove(for: baseURL)
        return MobileConnectionProfile(baseURL: baseURL, bearerToken: nil, tlsFingerprint: nil)
    }

    static func removeAuthorization(for url: URL) {
        MobileCredentialStore.remove(for: url)
    }

    static func validFingerprint(_ value: String?) -> Bool {
        value?.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil
    }

    private static func isLoopbackHost(_ value: String?) -> Bool {
        guard let host = value?.lowercased() else { return false }
        if host == "localhost" || host == "::1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.first == "127"
            && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) && (Int($0) ?? 256) <= 255 }
    }
}
private enum MobileCredentialStore {
    private static let service = "app.openfish.ios.host"
    private static let fingerprintService = "app.openfish.ios.host.tls-pin"
    private static let legacyService = "ai.deepseek.opencodex.iphone.host"

    static func token(for url: URL) -> String? {
        if let token = token(for: url, service: service) { return token }
        guard let token = token(for: url, service: legacyService) else { return nil }
        try? set(token, for: url)
        return token
    }

    static func fingerprint(for url: URL) -> String? {
        token(for: url, service: fingerprintService)
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
        try set(token, for: url, service: service)
    }

    static func setFingerprint(_ fingerprint: String, for url: URL) throws {
        try set(fingerprint.lowercased(), for: url, service: fingerprintService)
    }

    private static func set(_ token: String, for url: URL, service: String) throws {
        let query = baseQuery(for: url, service: service)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw MobileApiError.transport("Keychain rejected the Host credential (\(updateStatus)).")
        }
        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MobileApiError.transport("Keychain rejected the Host credential (\(status)).")
        }
    }

    static func remove(for url: URL) {
        SecItemDelete(baseQuery(for: url, service: service) as CFDictionary)
        SecItemDelete(baseQuery(for: url, service: legacyService) as CFDictionary)
        SecItemDelete(baseQuery(for: url, service: fingerprintService) as CFDictionary)
    }

    private static func baseQuery(for url: URL, service: String = service) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: url.absoluteString,
        ]
    }
}


class MobileTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let expectedFingerprint: String?
    private let permitsBootstrapTrust: Bool
    private var bootstrapFingerprint: String?

    init(expectedFingerprint: String? = nil, permitsBootstrapTrust: Bool = false) {
        self.expectedFingerprint = expectedFingerprint?.lowercased()
        self.permitsBootstrapTrust = permitsBootstrapTrust
    }

    var acceptedFingerprint: String? {
        lock.lock()
        defer { lock.unlock() }
        return expectedFingerprint ?? bootstrapFingerprint
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificateChain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = certificateChain.first else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
        let fingerprint = digest.map { String(format: "%02x", $0) }.joined()
        lock.lock()
        let accepted: Bool
        if let expectedFingerprint {
            accepted = fingerprint == expectedFingerprint
        } else if permitsBootstrapTrust {
            if bootstrapFingerprint == nil { bootstrapFingerprint = fingerprint }
            accepted = fingerprint == bootstrapFingerprint
        } else {
            accepted = false
        }
        lock.unlock()
        completionHandler(
            accepted ? .useCredential : .cancelAuthenticationChallenge,
            accepted ? URLCredential(trust: trust) : nil
        )
    }
}
