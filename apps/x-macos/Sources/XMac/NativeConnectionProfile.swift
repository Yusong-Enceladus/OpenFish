import Foundation
import Security
import CryptoKit

struct NativeConnectionProfile: Equatable, Sendable {
    static let local = NativeConnectionProfile(
        baseURL: URL(string: "http://127.0.0.1:3080")!,
        bearerToken: nil,
        tlsFingerprint: nil
    )

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

    static func restored() -> NativeConnectionProfile {
        guard let raw = UserDefaults.standard.string(forKey: "OpenCodex.hostURL"),
              let url = normalizedURL(raw) else { return .local }
        return NativeConnectionProfile(
            baseURL: url,
            bearerToken: NativeCredentialStore.token(for: url),
            tlsFingerprint: NativeCredentialStore.fingerprint(for: url)
        )
    }

    static func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
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
        UserDefaults.standard.set(baseURL.absoluteString, forKey: "OpenCodex.hostURL")
        if isLocal {
            NativeCredentialStore.removeAuthorization(for: baseURL)
        } else if let bearerToken, !bearerToken.isEmpty, Self.validFingerprint(tlsFingerprint), let tlsFingerprint {
            try NativeCredentialStore.setToken(bearerToken, for: baseURL)
            try NativeCredentialStore.setFingerprint(tlsFingerprint, for: baseURL)
        } else {
            throw NativeCredentialError.incompleteRemoteAuthorization
        }
    }

    func forgetAuthorization() -> NativeConnectionProfile {
        NativeCredentialStore.removeAuthorization(for: baseURL)
        return NativeConnectionProfile(baseURL: baseURL, bearerToken: nil, tlsFingerprint: nil)
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

enum NativeCredentialStore {
    private static let service = "app.openfish.mac.remote"
    private static let fingerprintService = "app.openfish.mac.remote.tls-pin"
    private static let legacyService = "ai.deepseek.opencodex.remote"

    private static func account(for url: URL) -> String {
        url.absoluteString
    }

    private static func legacyAccount(for url: URL) -> String {
        url.host.map { "\($0):\(url.port ?? (url.scheme == "https" ? 443 : 80))" } ?? url.absoluteString
    }

    static func token(for url: URL) -> String? {
        if let token = value(service: service, account: account(for: url)) { return token }
        if let token = value(service: service, account: legacyAccount(for: url)) {
            try? setToken(token, for: url)
            remove(service: service, account: legacyAccount(for: url))
            return token
        }
        guard let token = value(service: legacyService, account: legacyAccount(for: url))
                ?? value(service: legacyService, account: account(for: url)) else { return nil }
        try? setToken(token, for: url)
        return token
    }

    static func fingerprint(for url: URL) -> String? {
        value(service: fingerprintService, account: account(for: url))
    }

    private static func value(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setToken(_ token: String, for url: URL) throws {
        try set(token, service: service, account: account(for: url))
    }

    static func setFingerprint(_ fingerprint: String, for url: URL) throws {
        try set(fingerprint.lowercased(), service: fingerprintService, account: account(for: url))
    }

    private static func set(_ value: String, service: String, account: String) throws {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
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

    static func removeAuthorization(for url: URL) {
        for candidateService in [service, legacyService, fingerprintService] {
            for candidateAccount in [account(for: url), legacyAccount(for: url)] {
                remove(service: candidateService, account: candidateAccount)
            }
        }
    }

    private static func remove(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum NativeCredentialError: Error, CustomStringConvertible {
    case keychain(OSStatus)
    case incompleteRemoteAuthorization

    var description: String {
        switch self {
        case let .keychain(status): return "Keychain rejected the remote credential (\(status))."
        case .incompleteRemoteAuthorization: return "A remote Host requires HTTPS, a paired device token, and its pinned TLS identity."
        }
    }
}

/// URLSession trust delegate for OpenFish's private Host identity. A bootstrap
/// delegate accepts exactly the first leaf certificate it sees and pins every
/// subsequent request in that pairing exchange to the same bytes.
class OpenFishTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
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
        if accepted {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
