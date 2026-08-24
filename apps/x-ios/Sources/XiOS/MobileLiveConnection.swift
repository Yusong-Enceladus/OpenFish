import Foundation

enum MobileConnectionState: Equatable, Sendable {
    case connecting
    case connected
    case reconnecting(Int)

    var label: String {
        switch self {
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting"
        }
    }
}

enum MobileLiveUpdate: Sendable {
    case state(MobileConnectionState)
    /// The saved device credential was explicitly rejected by the Host.
    case authorizationRevoked
    case host(MobileServerRequest)
    case mux(MobileServerRequest)
}

private enum MobileLiveConnectionError: Error {
    case bufferOverflow
    case streamEnded
    case socketClosedBeforeOpen
    case socketOpenTimedOut
}

/// Bridges URLSession's WebSocket-open callback into async readiness. DSH's
/// event sockets are strictly downlink-only, so sending an application frame
/// (or relying on `sendPing` before the HTTP upgrade finishes) is not a valid
/// readiness probe on every Apple network stack.
private final class MobileWebSocketDelegate: MobileTLSDelegate, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let openLock = NSLock()
    private var opened: Set<Int> = []
    private var failures: [Int: Error] = [:]
    private var waiters: [Int: CheckedContinuation<Void, Error>] = [:]

    func waitUntilOpen(_ task: URLSessionWebSocketTask) async throws {
        let identifier = task.taskIdentifier
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            openLock.lock()
            if opened.contains(identifier) {
                openLock.unlock()
                continuation.resume()
                return
            }
            if let error = failures.removeValue(forKey: identifier) {
                openLock.unlock()
                continuation.resume(throwing: error)
                return
            }
            waiters[identifier] = continuation
            openLock.unlock()
            // waitsForConnectivity is desirable for ordinary network changes,
            // but an attempt created while the Host is between processes can
            // otherwise wait forever even after the listener returns. Bound
            // one generation so the owner can cancel both downlinks and retry
            // them against the new Host process.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.timeOutOpenWaiter(for: identifier)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        let identifier = webSocketTask.taskIdentifier
        openLock.lock()
        failures[identifier] = nil
        opened.insert(identifier)
        let waiter = waiters.removeValue(forKey: identifier)
        openLock.unlock()
        waiter?.resume()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        failOpenWaiter(for: webSocketTask.taskIdentifier)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard task is URLSessionWebSocketTask else { return }
        failOpenWaiter(for: task.taskIdentifier, error: error)
    }

    private func failOpenWaiter(for identifier: Int, error: Error? = nil) {
        let failure = error ?? MobileLiveConnectionError.socketClosedBeforeOpen
        openLock.lock()
        let waiter = waiters.removeValue(forKey: identifier)
        let wasOpen = opened.remove(identifier) != nil
        if waiter == nil, !wasOpen {
            failures[identifier] = failure
        }
        openLock.unlock()
        waiter?.resume(throwing: failure)
    }

    private func timeOutOpenWaiter(for identifier: Int) {
        openLock.lock()
        let waiter = waiters.removeValue(forKey: identifier)
        openLock.unlock()
        waiter?.resume(throwing: MobileLiveConnectionError.socketOpenTimedOut)
    }
}

actor MobileLiveConnection {
    nonisolated let updates: AsyncStream<MobileLiveUpdate>
    private let baseURL: URL
    private let token: String?
    private let continuation: AsyncStream<MobileLiveUpdate>.Continuation
    private let trustDelegate: MobileWebSocketDelegate
    private let session: URLSession
    private var task: Task<Void, Never>?
    private var sockets: [URLSessionWebSocketTask] = []

    init(baseURL: URL, token: String?, tlsFingerprint: String? = nil) {
        self.baseURL = baseURL
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        let trustDelegate = MobileWebSocketDelegate(expectedFingerprint: tlsFingerprint)
        self.trustDelegate = trustDelegate
        session = URLSession(configuration: configuration, delegate: trustDelegate, delegateQueue: nil)
        var captured: AsyncStream<MobileLiveUpdate>.Continuation?
        updates = AsyncStream(bufferingPolicy: .bufferingOldest(2_048)) { captured = $0 }
        continuation = captured!
    }

    func start() {
        guard task == nil else { return }
        continuation.yield(.state(.connecting))
        task = Task { await run() }
    }

    func stop() {
        task?.cancel()
        task = nil
        sockets.forEach { $0.cancel(with: .goingAway, reason: nil) }
        sockets = []
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                let host = try socket("/api/events.host")
                let mux = try socket("/api/events.mux")
                sockets = [host, mux]
                host.resume()
                mux.resume()
                // `resume()` only schedules a WebSocket task. Confirm the
                // authenticated HTTP upgrade through URLSession's open callback
                // before publishing Connected. A pre-open `sendPing` can hang
                // indefinitely on a physical iPhone even after REST pairing
                // succeeded, leaving the app permanently at Connecting.
                async let hostReady: Void = trustDelegate.waitUntilOpen(host)
                async let muxReady: Void = trustDelegate.waitUntilOpen(mux)
                _ = try await (hostReady, muxReady)
                attempt = 0
                continuation.yield(.state(.connected))
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await Self.pump(host, map: MobileLiveUpdate.host, into: self.continuation) }
                    group.addTask { try await Self.pump(mux, map: MobileLiveUpdate.mux, into: self.continuation) }
                    _ = try await group.next()
                    group.cancelAll()
                }
                throw URLError(.networkConnectionLost)
            } catch {
                let authorizationRevoked = sockets.contains { socket in
                    guard let response = socket.response as? HTTPURLResponse else { return false }
                    return response.statusCode == 401 || response.statusCode == 403
                }
                sockets.forEach { $0.cancel(with: .goingAway, reason: nil) }
                sockets = []
                if Task.isCancelled { return }
                if authorizationRevoked {
                    continuation.yield(.authorizationRevoked)
                    task = nil
                    return
                }
                attempt += 1
                continuation.yield(.state(.reconnecting(attempt)))
                try? await Task.sleep(for: .milliseconds(min(10_000, 400 * (1 << min(attempt, 4)))))
            }
        }
    }

    private func socket(_ path: String) throws -> URLSessionWebSocketTask {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = path
        components.query = nil
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        return session.webSocketTask(with: request)
    }

    private static func pump(
        _ socket: URLSessionWebSocketTask,
        map: @Sendable (MobileServerRequest) -> MobileLiveUpdate,
        into continuation: AsyncStream<MobileLiveUpdate>.Continuation
    ) async throws {
        while !Task.isCancelled {
            let message = try await socket.receive()
            let data: Data
            switch message {
            case let .data(value): data = value
            case let .string(value): data = Data(value.utf8)
            @unknown default: continue
            }
            let envelope = try JSONDecoder().decode(MobileServerRequest.self, from: data)
            switch continuation.yield(map(envelope)) {
            case .enqueued:
                break
            case .dropped:
                throw MobileLiveConnectionError.bufferOverflow
            case .terminated:
                throw MobileLiveConnectionError.streamEnded
            @unknown default:
                throw MobileLiveConnectionError.streamEnded
            }
        }
    }

}
