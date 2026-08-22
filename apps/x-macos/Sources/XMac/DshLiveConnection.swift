import Foundation

enum DshConnectionState: Equatable, Sendable {
    case connecting
    case connected
    case reconnecting(attempt: Int)

    var label: String {
        switch self {
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting"
        }
    }
}

enum DshDownlinkChannel: Sendable {
    case host
    case mux
}

enum DshLiveUpdate: Sendable {
    case state(DshConnectionState)
    case envelope(DshDownlinkChannel, DshServerRequest)
}

private enum DshLiveConnectionError: Error {
    case invalidBaseURL
    case streamEnded
    case binaryFrameDecodeFailed
    case invalidEnvelope
    case updateBufferOverflow
    case socketClosedBeforeOpen
}

/// Bridges URLSession's WebSocket open callback into async readiness without sending
/// application data on DSH's strictly downlink-only sockets.
private final class DshWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var opened: Set<Int> = []
    private var failures: [Int: Error] = [:]
    private var waiters: [Int: CheckedContinuation<Void, Error>] = [:]

    func waitUntilOpen(_ task: URLSessionWebSocketTask) async throws {
        let identifier = task.taskIdentifier
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if opened.contains(identifier) {
                lock.unlock()
                continuation.resume()
                return
            }
            if let error = failures.removeValue(forKey: identifier) {
                lock.unlock()
                continuation.resume(throwing: error)
                return
            }
            waiters[identifier] = continuation
            lock.unlock()
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        let identifier = webSocketTask.taskIdentifier
        lock.lock()
        failures[identifier] = nil
        opened.insert(identifier)
        let waiter = waiters.removeValue(forKey: identifier)
        lock.unlock()
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
        let failure = error ?? DshLiveConnectionError.socketClosedBeforeOpen
        lock.lock()
        let waiter = waiters.removeValue(forKey: identifier)
        let wasOpen = opened.remove(identifier) != nil
        if waiter == nil, !wasOpen {
            failures[identifier] = failure
        }
        lock.unlock()
        waiter?.resume(throwing: failure)
    }
}

/// Owns the two downlink-only WebSockets exposed by DSH's existing client connection seam.
/// A failed generation always rebuilds both streams so host and session frames share one cut.
actor DshLiveConnection {
    nonisolated let updates: AsyncStream<DshLiveUpdate>

    private let baseURL: URL
    private let bearerToken: String?
    private let delegate: DshWebSocketDelegate
    private let session: URLSession
    private let continuation: AsyncStream<DshLiveUpdate>.Continuation
    private var loopTask: Task<Void, Never>?
    private var activeSockets: [URLSessionWebSocketTask] = []

    init(baseURL: URL, bearerToken: String? = nil) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        let delegate = DshWebSocketDelegate()
        self.delegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)

        var captured: AsyncStream<DshLiveUpdate>.Continuation?
        updates = AsyncStream(bufferingPolicy: .bufferingOldest(2_048)) { captured = $0 }
        continuation = captured!
    }

    func start() {
        guard loopTask == nil else { return }
        continuation.yield(.state(.connecting))
        loopTask = Task { await runLoop() }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        for socket in activeSockets {
            socket.cancel(with: .goingAway, reason: nil)
        }
        activeSockets = []
        continuation.finish()
    }

    private func runLoop() async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                let mux = try socket(path: "/api/events.mux")
                let host = try socket(path: "/api/events.host")
                activeSockets = [mux, host]
                mux.resume()
                host.resume()

                // DSH sockets are downlink-only, so readiness must use URLSession's open
                // callback rather than an application message or a synthetic client frame.
                async let muxReady: Void = delegate.waitUntilOpen(mux)
                async let hostReady: Void = delegate.waitUntilOpen(host)
                _ = try await (muxReady, hostReady)

                attempt = 0
                try publish(.state(.connected))
                try await pumpGeneration(mux: mux, host: host)
            } catch {
                for socket in activeSockets {
                    socket.cancel(with: .goingAway, reason: nil)
                }
                activeSockets = []
                if Task.isCancelled { break }

                attempt += 1
                continuation.yield(.state(.reconnecting(attempt: attempt)))
                let capMilliseconds = min(10_000, 500 * (1 << min(attempt - 1, 4)))
                let delayMilliseconds = Int.random(in: max(1, capMilliseconds / 2) ... capMilliseconds)
                try? await Task.sleep(nanoseconds: UInt64(delayMilliseconds) * 1_000_000)
            }
        }
    }

    private func publish(_ update: DshLiveUpdate) throws {
        switch continuation.yield(update) {
        case .enqueued:
            return
        case .dropped:
            throw DshLiveConnectionError.updateBufferOverflow
        case .terminated:
            throw CancellationError()
        @unknown default:
            throw DshLiveConnectionError.streamEnded
        }
    }

    private func socket(path: String) throws -> URLSessionWebSocketTask {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw DshLiveConnectionError.invalidBaseURL
        }
        switch components.scheme {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: throw DshLiveConnectionError.invalidBaseURL
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw DshLiveConnectionError.invalidBaseURL }
        var request = URLRequest(url: url)
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "authorization")
        }
        return session.webSocketTask(with: request)
    }

    private func pumpGeneration(
        mux: URLSessionWebSocketTask,
        host: URLSessionWebSocketTask
    ) async throws {
        let sink = continuation
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await Self.pump(mux, channel: .mux, sink: sink) }
                group.addTask { try await Self.pump(host, channel: .host, sink: sink) }
                _ = try await group.next()
                mux.cancel(with: .goingAway, reason: nil)
                host.cancel(with: .goingAway, reason: nil)
                group.cancelAll()
                throw DshLiveConnectionError.streamEnded
            }
        } catch {
            mux.cancel(with: .goingAway, reason: nil)
            host.cancel(with: .goingAway, reason: nil)
            throw error
        }
    }

    private static func pump(
        _ task: URLSessionWebSocketTask,
        channel: DshDownlinkChannel,
        sink: AsyncStream<DshLiveUpdate>.Continuation
    ) async throws {
        let decoder = JSONDecoder()
        while !Task.isCancelled {
            let message = try await task.receive()
            let data: Data
            switch message {
            case let .string(text):
                data = Data(text.utf8)
            case let .data(value):
                data = value
            @unknown default:
                throw DshLiveConnectionError.binaryFrameDecodeFailed
            }
            let envelope = try decoder.decode(DshServerRequest.self, from: data)
            guard envelope.type == "server-request",
                  envelope.payload["type"]?.stringValue == envelope.method else {
                throw DshLiveConnectionError.invalidEnvelope
            }
            if envelope.payload["type"]?.stringValue == "stream/error" {
                throw DshLiveConnectionError.streamEnded
            }
            switch sink.yield(.envelope(channel, envelope)) {
            case .enqueued:
                break
            case .dropped:
                throw DshLiveConnectionError.updateBufferOverflow
            case .terminated:
                throw CancellationError()
            @unknown default:
                throw DshLiveConnectionError.streamEnded
            }
        }
    }
}
