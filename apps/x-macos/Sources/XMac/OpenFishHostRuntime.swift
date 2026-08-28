import Foundation
import Darwin

struct OpenFishDriverBundle: Decodable, Identifiable, Equatable, Sendable {
    let packageName: String
    let requested: String
    let version: String
    let patch: String
    let source: String
    let integrity: String?
    let installScriptsAllowed: Bool?
    let active: Bool

    var id: String { packageName }
}

struct OpenFishDriverCommandResult: Decodable, Sendable {
    let action: String
    let requiresRestart: Bool
    let changedPackage: String?
    let bundles: [OpenFishDriverBundle]
}

enum OpenFishDriverManagerError: LocalizedError {
    case unavailable
    case failed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The bundled OpenFish Driver manager is unavailable. Reinstall the packaged Mac app."
        case .failed(let message):
            return message
        case .invalidResponse:
            return "The bundled Driver manager returned an unreadable response."
        }
    }
}

/// Local-only bridge to the exact-version Driver Bundle manager shipped in the
/// app. It never invokes a shell and never accepts package-manager arguments.
enum OpenFishDriverManager {
    private struct Runtime: Sendable {
        let root: URL
        let node: URL
        let cli: URL
    }

    static var isAvailable: Bool { runtime() != nil }

    static func list() async throws -> OpenFishDriverCommandResult {
        try await run(["driver", "--profile", "x", "list"])
    }

    static func install(
        spec: String,
        expectedPackageName: String?,
        allowScripts: Bool
    ) async throws -> OpenFishDriverCommandResult {
        var arguments = ["driver", "--profile", "x"]
        if let expectedPackageName, !expectedPackageName.isEmpty {
            arguments.append(contentsOf: ["--package", expectedPackageName])
        }
        if allowScripts { arguments.append("--allow-scripts") }
        arguments.append(contentsOf: ["install", spec])
        return try await run(arguments)
    }

    static func remove(packageName: String) async throws -> OpenFishDriverCommandResult {
        try await run(["driver", "--profile", "x", "remove", packageName])
    }

    private static func runtime() -> Runtime? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let root = resources.appendingPathComponent("OpenFishHostRuntime", isDirectory: true)
        let node = root.appendingPathComponent("node/bin/node")
        let cli = root.appendingPathComponent("app/lib/bin.js")
        let npm = root.appendingPathComponent("node/lib/node_modules/npm/bin/npm-cli.js")
        let bun = root.appendingPathComponent("app/node_modules/bun/bin/bun.exe")
        let uv = root.appendingPathComponent("uv/uv")
        guard FileManager.default.isExecutableFile(atPath: node.path),
              FileManager.default.fileExists(atPath: cli.path),
              FileManager.default.fileExists(atPath: npm.path),
              FileManager.default.isExecutableFile(atPath: bun.path),
              FileManager.default.isExecutableFile(atPath: uv.path) else { return nil }
        return Runtime(root: root, node: node, cli: cli)
    }

    private static func run(_ arguments: [String]) async throws -> OpenFishDriverCommandResult {
        guard let runtime = runtime() else { throw OpenFishDriverManagerError.unavailable }
        return try await Task.detached(priority: .userInitiated) {
            let files = FileManager.default
            let scratch = files.temporaryDirectory
                .appendingPathComponent("openfish-driver-\(UUID().uuidString)", isDirectory: true)
            try files.createDirectory(
                at: scratch,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? files.removeItem(at: scratch) }

            let stdoutURL = scratch.appendingPathComponent("stdout")
            let stderrURL = scratch.appendingPathComponent("stderr")
            files.createFile(atPath: stdoutURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            files.createFile(atPath: stderrURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let stdout = try FileHandle(forWritingTo: stdoutURL)
            let stderr = try FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdout.close()
                try? stderr.close()
            }

            let child = Process()
            child.executableURL = runtime.node
            child.arguments = [runtime.cli.path] + arguments
            let parent = ProcessInfo.processInfo.environment
            var environment: [String: String] = [
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "PATH": "\(runtime.root.appendingPathComponent("node/bin").path):/usr/bin:/bin:/usr/sbin:/sbin",
                "OPENFISH_EMBEDDED_RUNTIME_ROOT": runtime.root.path,
            ]
            // Preserve only location and locale choices needed by the trusted
            // bundled CLI. NODE_OPTIONS, registry credentials, API keys, shell
            // hooks, and unrelated app environment never enter this process;
            // the CLI separately gives npm lifecycle code an operation-private
            // HOME, cache, temp directory, and closed environment.
            for key in ["DSH_HOME", "LANG", "LC_ALL", "TMPDIR"] {
                if let value = parent[key], !value.isEmpty { environment[key] = value }
            }
            child.environment = environment
            child.standardOutput = stdout
            child.standardError = stderr
            try child.run()
            child.waitUntilExit()
            try stdout.synchronize()
            try stderr.synchronize()

            let output = try Data(contentsOf: stdoutURL)
            if child.terminationStatus != 0 {
                let bytes = try Data(contentsOf: stderrURL).suffix(8_192)
                let detail = String(decoding: bytes, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw OpenFishDriverManagerError.failed(
                    detail.isEmpty ? "The Driver Bundle operation failed." : detail
                )
            }
            guard let result = try? JSONDecoder().decode(OpenFishDriverCommandResult.self, from: output) else {
                throw OpenFishDriverManagerError.invalidResponse
            }
            return result
        }.value
    }
}

/// Starts the Host embedded in the app bundle when no compatible local Host is already healthy.
@MainActor
enum OpenFishHostRuntime {
    private static var process: Process?
    // Increment whenever the launcher-to-Host security contract changes. The
    // runtime bundle digest alone cannot retire a Host started by an older Mac
    // launcher when only the native launcher changed.
    private static let launcherRuntimeVersion = "embedded-harness-runtime-v5-upgrade-recovery"

    private struct RuntimeManifest: Decodable {
        let runtimeId: String
    }

    private struct EmbeddedRuntime {
        let root: URL
        let node: URL
        let host: URL
        let managedRuntimeId: String
    }

    private struct Health: Decodable {
        let ok: Bool
        let product: String
        let protocolVersion: String
        let host: String
        let surface: String
        let plainHost: String?
        let secureRemotePort: Int?
        let embeddedRuntimeId: String?
        let embeddedProcessId: Int32?
    }

    private enum LocalHostState {
        case absent
        case compatible(pid: Int32)
        case safeLocal(pid: Int32)
        case unmanaged
        case stale(pid: Int32)
    }

    private static var retiringProcessId: Int32?
    private static let bootstrapRecheckLimit = 12
    private static var bootstrapRechecksRemaining = bootstrapRecheckLimit
    private static var bootstrapRecheckScheduled = false

    private static func embeddedRuntime() -> EmbeddedRuntime? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let root = resources.appendingPathComponent("OpenFishHostRuntime", isDirectory: true)
        let node = root.appendingPathComponent("node/bin/node")
        let host = root.appendingPathComponent("app/lib/bin.js")
        let hostNpm = root.appendingPathComponent("app/node_modules/npm/bin/npm-cli.js")
        let driverNpm = root.appendingPathComponent("node/lib/node_modules/npm/bin/npm-cli.js")
        let bun = root.appendingPathComponent("app/node_modules/bun/bin/bun.exe")
        let uv = root.appendingPathComponent("uv/uv")
        let manifest = root.appendingPathComponent("runtime.json")
        guard FileManager.default.isExecutableFile(atPath: node.path),
              FileManager.default.fileExists(atPath: host.path),
              FileManager.default.fileExists(atPath: hostNpm.path),
              FileManager.default.fileExists(atPath: driverNpm.path),
              FileManager.default.isExecutableFile(atPath: bun.path),
              FileManager.default.isExecutableFile(atPath: uv.path),
              let data = try? Data(contentsOf: manifest),
              let expected = try? JSONDecoder().decode(RuntimeManifest.self, from: data) else { return nil }
        return EmbeddedRuntime(
            root: root,
            node: node,
            host: host,
            managedRuntimeId: "\(expected.runtimeId):\(launcherRuntimeVersion)"
        )
    }

    static func bootstrapIfNeeded() {
        guard let embedded = embeddedRuntime() else { return }
        let existing = localHostState(
            expectedRuntimeId: embedded.managedRuntimeId,
            expectedExecutable: embedded.node
        )
        let processToRetire: Int32?
        switch existing {
        case .compatible(_):
            bootstrapRechecksRemaining = bootstrapRecheckLimit
            return
        case .unmanaged:
            // A verified Host that is still starting or retiring can briefly
            // own the port without answering the identity handshake. Never
            // signal an unverified process, but do not make an app upgrade
            // depend on the user reopening OpenFish either. Recheck for a
            // bounded window and remain fail-closed if the listener really is
            // external.
            scheduleBootstrapRecheck()
            return
        case .safeLocal(let pid):
            // A failed identity generation must never expose clear-text LAN
            // traffic. Keep the safe loopback Host alive until an identity can
            // be prepared, then replace it with the secure remote-capable Host.
            guard prepareRemoteTLSIdentity() != nil else { return }
            processToRetire = pid
        case .stale(let pid):
            processToRetire = pid
        case .absent:
            processToRetire = nil
        }
        bootstrapRechecksRemaining = bootstrapRecheckLimit
        if let pid = processToRetire {
            guard kill(pid, SIGTERM) == 0 else {
                scheduleBootstrapRecheck()
                return
            }
            retiringProcessId = pid
            if process?.processIdentifier == pid { process = nil }
            finishScheduledRestart(embedded: embedded, attemptsRemaining: 60)
            return
        }

        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/openfish/logs", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logs.path)
        let output = logs.appendingPathComponent("embedded-host.log")
        if !FileManager.default.fileExists(atPath: output.path) {
            FileManager.default.createFile(
                atPath: output.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        guard let log = try? FileHandle(forWritingTo: output) else { return }
        _ = try? log.seekToEnd()

        let child = Process()
        child.executableURL = embedded.node
        // Command-line values outrank a persisted profile. Even a stale or
        // user-edited x profile therefore cannot expose the plaintext carrier
        // beyond this Mac; remote clients get the separate TLS-only listener.
        var arguments = [
            embedded.host.path,
            "--profile", "x",
            "--host", "127.0.0.1",
            "--port", "3080",
            "--no-open",
        ]
        if let trustedHost = trustedBonjourHost() {
            arguments.append(contentsOf: ["--trusted-host", trustedHost])
        }
        child.arguments = arguments
        let parent = ProcessInfo.processInfo.environment
        var environment: [String: String] = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "\(embedded.root.appendingPathComponent("node/bin").path):/usr/bin:/bin:/usr/sbin:/sbin",
            "OPENFISH_EMBEDDED_RUNTIME_ID": embedded.managedRuntimeId,
            "OPENFISH_EMBEDDED_RUNTIME_ROOT": embedded.root.path,
        ]
        // The trusted Host gets only filesystem location and locale context.
        // Provider keys, npm credentials, NODE_OPTIONS, shell hooks, auth
        // sockets, and arbitrary launch-environment values never cross into
        // the packaged control plane or its child Harnesses.
        for key in ["DSH_HOME", "LANG", "LC_ALL", "TMPDIR", "USER", "LOGNAME"] {
            if let value = parent[key], !value.isEmpty { environment[key] = value }
        }
        if let identity = prepareRemoteTLSIdentity() {
            environment["OPENFISH_TLS_CERT_PATH"] = identity.certificate.path
            environment["OPENFISH_TLS_PRIVATE_KEY_PATH"] = identity.privateKey.path
        }
        child.environment = environment
        child.standardOutput = log
        child.standardError = log
        do {
            try child.run()
            process = child
        } catch {
            try? log.write(contentsOf: Data("Open Fish could not start its embedded Host: \(error)\n".utf8))
        }
    }

    private static func scheduleBootstrapRecheck() {
        guard bootstrapRechecksRemaining > 0, !bootstrapRecheckScheduled else { return }
        bootstrapRechecksRemaining -= 1
        bootstrapRecheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            bootstrapRecheckScheduled = false
            bootstrapIfNeeded()
        }
    }

    /// Retire only the verified Host process that belongs to this app bundle,
    /// then relaunch from the same packaged runtime. An unrelated service on
    /// port 3080 is never signalled.
    @discardableResult
    static func restartManagedHost() -> Bool {
        guard let embedded = embeddedRuntime() else { return false }
        switch localHostState(
            expectedRuntimeId: embedded.managedRuntimeId,
            expectedExecutable: embedded.node
        ) {
        case .absent:
            bootstrapIfNeeded()
            return true
        case .unmanaged:
            return false
        case .compatible(let pid), .safeLocal(let pid), .stale(let pid):
            guard kill(pid, SIGTERM) == 0 else { return false }
            retiringProcessId = pid
            if process?.processIdentifier == pid { process = nil }
            finishScheduledRestart(embedded: embedded, attemptsRemaining: 60)
            return true
        }
    }

    private static func finishScheduledRestart(
        embedded: EmbeddedRuntime,
        attemptsRemaining: Int
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let state = localHostState(
                expectedRuntimeId: embedded.managedRuntimeId,
                expectedExecutable: embedded.node
            )
            switch state {
            case .absent:
                retiringProcessId = nil
                bootstrapIfNeeded()
            case .compatible(let pid), .safeLocal(let pid), .stale(let pid):
                if pid == retiringProcessId {
                    guard attemptsRemaining > 0 else { return }
                    finishScheduledRestart(embedded: embedded, attemptsRemaining: attemptsRemaining - 1)
                } else {
                    // Another verified app-owned Host won the relaunch race.
                    retiringProcessId = nil
                }
            case .unmanaged:
                // A terminating listener can briefly stop answering health
                // before releasing its socket. Keep waiting only for this
                // explicitly requested restart window.
                guard attemptsRemaining > 0 else { return }
                finishScheduledRestart(embedded: embedded, attemptsRemaining: attemptsRemaining - 1)
            }
        }
    }

    private struct RemoteTLSIdentity {
        let certificate: URL
        let privateKey: URL
    }

    /// Create one durable, app-owned TLS identity. Plain HTTP remains bound to
    /// loopback; this identity is used only by the Host's separate LAN listener.
    private static func prepareRemoteTLSIdentity() -> RemoteTLSIdentity? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/openfish/tls", isDirectory: true)
        let certificate = root.appendingPathComponent("host-cert.pem")
        let privateKey = root.appendingPathComponent("host-key.pem")
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            if secureRegularFile(certificate, privateKey: false),
               secureRegularFile(privateKey, privateKey: true),
               certificateIsUsable(certificate),
               certificateMatchesPrivateKey(certificate, privateKey) {
                return RemoteTLSIdentity(certificate: certificate, privateKey: privateKey)
            }

            let suffix = UUID().uuidString
            let temporaryCertificate = root.appendingPathComponent(".host-cert-\(suffix).pem")
            let temporaryPrivateKey = root.appendingPathComponent(".host-key-\(suffix).pem")
            defer {
                try? FileManager.default.removeItem(at: temporaryCertificate)
                try? FileManager.default.removeItem(at: temporaryPrivateKey)
            }
            let openssl = Process()
            openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            openssl.arguments = [
                "req", "-x509", "-newkey", "rsa:3072", "-sha256", "-nodes",
                "-days", "3650", "-subj", "/CN=OpenFish Local Host",
                "-keyout", temporaryPrivateKey.path,
                "-out", temporaryCertificate.path,
            ]
            openssl.standardOutput = FileHandle.nullDevice
            openssl.standardError = FileHandle.nullDevice
            try openssl.run()
            openssl.waitUntilExit()
            guard openssl.terminationStatus == 0 else { return nil }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryPrivateKey.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temporaryCertificate.path)
            guard secureRegularFile(temporaryCertificate, privateKey: false),
                  secureRegularFile(temporaryPrivateKey, privateKey: true),
                  certificateIsUsable(temporaryCertificate),
                  certificateMatchesPrivateKey(temporaryCertificate, temporaryPrivateKey) else { return nil }

            // Preserve an existing identity until the complete replacement
            // pair is ready. A failed promotion restores both old files; the
            // Host is never launched with a certificate from one generation
            // and a private key from another.
            let backupCertificate = root.appendingPathComponent(".host-cert-backup-\(suffix).pem")
            let backupPrivateKey = root.appendingPathComponent(".host-key-backup-\(suffix).pem")
            let hadCertificate = FileManager.default.fileExists(atPath: certificate.path)
            let hadPrivateKey = FileManager.default.fileExists(atPath: privateKey.path)
            var movedCertificate = false
            var movedPrivateKey = false
            do {
                if hadCertificate {
                    try FileManager.default.moveItem(at: certificate, to: backupCertificate)
                    movedCertificate = true
                }
                if hadPrivateKey {
                    try FileManager.default.moveItem(at: privateKey, to: backupPrivateKey)
                    movedPrivateKey = true
                }
                try FileManager.default.moveItem(at: temporaryCertificate, to: certificate)
                try FileManager.default.moveItem(at: temporaryPrivateKey, to: privateKey)
                guard certificateMatchesPrivateKey(certificate, privateKey) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try? FileManager.default.removeItem(at: backupCertificate)
                try? FileManager.default.removeItem(at: backupPrivateKey)
            } catch {
                try? FileManager.default.removeItem(at: certificate)
                try? FileManager.default.removeItem(at: privateKey)
                if movedCertificate { try? FileManager.default.moveItem(at: backupCertificate, to: certificate) }
                if movedPrivateKey { try? FileManager.default.moveItem(at: backupPrivateKey, to: privateKey) }
                throw error
            }
            return RemoteTLSIdentity(certificate: certificate, privateKey: privateKey)
        } catch {
            return nil
        }
    }

    private static func secureRegularFile(_ url: URL, privateKey: Bool) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_size > 0,
              info.st_size <= 1_048_576 else { return false }
        return !privateKey || (info.st_mode & 0o077) == 0
    }

    private static func certificateIsUsable(_ certificate: URL) -> Bool {
        let openssl = Process()
        openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        // Certificate pinning makes rotation an explicit re-pairing event.
        // Keep the ten-year app-owned identity until it actually expires;
        // silently rotating it early would strand every paired iPhone.
        openssl.arguments = ["x509", "-checkend", "0", "-noout", "-in", certificate.path]
        openssl.standardOutput = FileHandle.nullDevice
        openssl.standardError = FileHandle.nullDevice
        do {
            try openssl.run()
            openssl.waitUntilExit()
            return openssl.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func certificateMatchesPrivateKey(_ certificate: URL, _ privateKey: URL) -> Bool {
        func modulus(_ arguments: [String]) -> Data? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                return try output.fileHandleForReading.readToEnd()
            } catch {
                return nil
            }
        }
        guard let certificateModulus = modulus(["x509", "-noout", "-modulus", "-in", certificate.path]),
              let keyModulus = modulus(["rsa", "-noout", "-modulus", "-in", privateKey.path]) else {
            return false
        }
        return !certificateModulus.isEmpty && certificateModulus == keyModulus
    }

    private static func trustedBonjourHost() -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return nil }
        let hostname = String(
            decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostname.isEmpty else { return nil }
        return hostname.hasSuffix(".local") ? hostname : "\(hostname).local"
    }

    private static func localHostState(expectedRuntimeId: String, expectedExecutable: URL) -> LocalHostState {
        guard let url = URL(string: "http://127.0.0.1:3080/x-native/v2/health") else { return .absent }
        let request = URLRequest(url: url, timeoutInterval: 0.35)
        let completed = DispatchSemaphore(value: 0)
        final class ResultBox: @unchecked Sendable { var health: Health? }
        let result = ResultBox()
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200, let data {
                result.health = try? JSONDecoder().decode(Health.self, from: data)
            }
            completed.signal()
        }.resume()
        _ = completed.wait(timeout: .now() + 0.4)
        guard let health = result.health,
              health.ok,
              health.product == "opencodex",
              health.protocolVersion == "v2",
              health.host == "dsh",
              health.surface == "native" else {
            // A busy or still-starting Host can miss the short health deadline.
            // Treat an occupied loopback port as externally managed instead of
            // racing a second Host into EADDRINUSE. A later app connection will
            // surface the unhealthy Host explicitly without spawning duplicates.
            return localHostPortIsOccupied() ? .unmanaged : .absent
        }
        guard let actual = health.embeddedRuntimeId, !actual.isEmpty,
              let pid = health.embeddedProcessId,
              pid > 1,
              isEmbeddedHostProcess(pid: pid, expectedExecutable: expectedExecutable) else {
            // A process listening on 3080 can claim arbitrary JSON. Never turn
            // an unauthenticated health response into permission to signal an
            // unrelated local process.
            return .unmanaged
        }
        guard actual == expectedRuntimeId else { return .stale(pid: pid) }
        // This is an app-owned process, so an unsafe plaintext bind is safe to
        // retire. Older handshakes omit `plainHost` and are deliberately stale.
        guard health.plainHost == "127.0.0.1" else { return .stale(pid: pid) }
        if health.secureRemotePort == 3_081 { return .compatible(pid: pid) }
        if health.secureRemotePort == nil { return .safeLocal(pid: pid) }
        return .stale(pid: pid)
    }

    private static func isEmbeddedHostProcess(pid: Int32, expectedExecutable: URL) -> Bool {
        // proc_info.h defines PROC_PIDPATHINFO_MAXSIZE as 4 * MAXPATHLEN, but
        // Swift 6 no longer imports that macro directly.
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let count = proc_pidpath(pid, &path, UInt32(path.count))
        guard count > 0 else { return false }
        let decodedPath = String(
            decoding: path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        let actual = URL(fileURLWithPath: decodedPath).resolvingSymlinksInPath().standardizedFileURL
        let expected = expectedExecutable.resolvingSymlinksInPath().standardizedFileURL
        return actual == expected
    }

    private static func localHostPortIsOccupied() -> Bool {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return true }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(3_080).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
