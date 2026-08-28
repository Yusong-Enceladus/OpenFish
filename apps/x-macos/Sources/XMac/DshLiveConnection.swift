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

enum DshLiveUpdate: Sendable {
    case state(DshConnectionState)
    /// The Host explicitly rejected the saved bearer credential. This is not
    /// a transient network retry: the user must pair this Mac again.
    case authorizationRevoked
    /// One canonical frame from the Host-owned `xNative/follow` contract.
    case feed(JSONValue)
}

private enum DshLiveConnectionError: Error {
    case invalidBaseURL
    case streamEnded
    case binaryFrameDecodeFailed
    case invalidEnvelope
    case updateBufferOverflow
    case socketClosedBeforeOpen
    case socketOpenTimedOut
    case remoteFailure(String)
}

private struct DshNativeFollowRequest: Encodable {
    let sessionId: String?
    let parentSessionId: String?
    let mode: String?
    let maxMessages: Int
}

private struct DshNativeFollowArguments: Encodable {
    let request: DshNativeFollowRequest
}

private struct DshNativeFollowPayload: Encodable {
    let args: DshNativeFollowArguments
}

private struct DshRemoteStreamOpen: Encodable {
    let type = "open"
    let streamId: String
    let endpoint = "xNative/follow"
    let payload: DshNativeFollowPayload
}

private struct DshRemoteStreamCancel: Encodable {
    let type = "cancel"
    let streamId: String
}

private struct DshRemoteStreamFailure: Decodable {
    let code: String
    let message: String
}

private struct DshRemoteStreamFrame: Decodable {
    let type: String
    let streamId: String
    let value: JSONValue?
    let error: DshRemoteStreamFailure?
}

/// Bridges URLSession's WebSocket open callback into async readiness.
private final class DshWebSocketDelegate: OpenFishTLSDelegate, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var opened: Set<Int> = []
    private var failures: [Int: Error] = [:]
    private var waiters: [Int: CheckedContinuation<Void, Error>] = [:]

    init(expectedFingerprint: String?) {
        super.init(expectedFingerprint: expectedFingerprint)
    }

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
        if waiter == nil, !wasOpen { failures[identifier] = failure }
        lock.unlock()
        waiter?.resume(throwing: failure)
    }

    private func timeOutOpenWaiter(for identifier: Int) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: identifier)
        lock.unlock()
        waiter?.resume(throwing: DshLiveConnectionError.socketOpenTimedOut)
    }
}

/// Owns the single authenticated Gateway carrier used by all native live data.
/// Selecting another task replaces only its logical feed, never the physical
/// connection, so workspace/control/events share one reconnect generation.
actor DshLiveConnection {
    nonisolated let updates: AsyncStream<DshLiveUpdate>

    private let baseURL: URL
    private let bearerToken: String?
    private let delegate: DshWebSocketDelegate
    private let session: URLSession
    private let continuation: AsyncStream<DshLiveUpdate>.Continuation
    private var loopTask: Task<Void, Never>?
    private var activeSocket: URLSessionWebSocketTask?
    private var activeStreamId: String?
    private var selectedSessionId: String?
    private var selectedParentSessionId: String?
    private var selectedMode: String?

    init(baseURL: URL, bearerToken: String? = nil, tlsFingerprint: String? = nil) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        let delegate = DshWebSocketDelegate(expectedFingerprint: tlsFingerprint)
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
        activeStreamId = nil
        activeSocket?.cancel(with: .goingAway, reason: nil)
        activeSocket = nil
    }

    /// Follow the selected parent task or one of its subagent conversations
    /// while keeping Host-wide streams alive on the same Gateway carrier.
    func selectSession(
        _ sessionId: String?,
        parentSessionId: String? = nil,
        mode: String? = nil
    ) async {
        let parentSessionId = sessionId == nil ? nil : parentSessionId
        let mode = parentSessionId == nil ? nil : mode
        guard selectedSessionId != sessionId
                || selectedParentSessionId != parentSessionId
                || selectedMode != mode else { return }
        selectedSessionId = sessionId
        selectedParentSessionId = parentSessionId
        selectedMode = mode
        guard let socket = activeSocket, activeStreamId != nil else { return }
        do {
            try await replaceFollowStream(on: socket)
        } catch {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    private func runLoop() async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                let socket = try makeSocket()
                activeSocket = socket
                socket.resume()
                try await delegate.waitUntilOpen(socket)
                try await replaceFollowStream(on: socket)

                attempt = 0
                try publish(.state(.connected))
                try await pump(socket)
            } catch {
                let authorizationRevoked: Bool = {
                    guard let response = activeSocket?.response as? HTTPURLResponse else { return false }
                    return response.statusCode == 401 || response.statusCode == 403
                }()
                activeStreamId = nil
                activeSocket?.cancel(with: .goingAway, reason: nil)
                activeSocket = nil
                if Task.isCancelled { break }

                if authorizationRevoked {
                    continuation.yield(.authorizationRevoked)
                    loopTask = nil
                    return
                }

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
        case .enqueued: return
        case .dropped: throw DshLiveConnectionError.updateBufferOverflow
        case .terminated: throw CancellationError()
        @unknown default: throw DshLiveConnectionError.streamEnded
        }
    }

    private func makeSocket() throws -> URLSessionWebSocketTask {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw DshLiveConnectionError.invalidBaseURL
        }
        switch components.scheme {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: throw DshLiveConnectionError.invalidBaseURL
        }
        components.path = "/api/remote.mux"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw DshLiveConnectionError.invalidBaseURL }
        var request = URLRequest(url: url)
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "authorization")
        }
        return session.webSocketTask(with: request)
    }

    private func replaceFollowStream(on socket: URLSessionWebSocketTask) async throws {
        if let oldStreamId = activeStreamId {
            try await send(DshRemoteStreamCancel(streamId: oldStreamId), on: socket)
        }
        let streamId = UUID().uuidString.lowercased()
        activeStreamId = streamId
        try await send(DshRemoteStreamOpen(
            streamId: streamId,
            payload: DshNativeFollowPayload(args: DshNativeFollowArguments(request: DshNativeFollowRequest(
                sessionId: selectedSessionId,
                parentSessionId: selectedParentSessionId,
                mode: selectedMode,
                maxMessages: 100
            )))
        ), on: socket)
    }

    private func send<Value: Encodable>(_ value: Value, on socket: URLSessionWebSocketTask) async throws {
        let data = try JSONEncoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw DshLiveConnectionError.invalidEnvelope
        }
        try await socket.send(.string(text))
    }

    private func pump(_ socket: URLSessionWebSocketTask) async throws {
        let decoder = JSONDecoder()
        while !Task.isCancelled {
            let message = try await socket.receive()
            let data: Data
            switch message {
            case let .string(text): data = Data(text.utf8)
            case let .data(value): data = value
            @unknown default: throw DshLiveConnectionError.binaryFrameDecodeFailed
            }
            let frame = try decoder.decode(DshRemoteStreamFrame.self, from: data)
            guard frame.streamId == activeStreamId else { continue }
            switch frame.type {
            case "item":
                if let value = frame.value { try publish(.feed(value)) }
            case "error":
                let failure = frame.error
                throw DshLiveConnectionError.remoteFailure(
                    [failure?.code, failure?.message].compactMap { $0 }.joined(separator: ": ")
                )
            case "end":
                throw DshLiveConnectionError.streamEnded
            default:
                throw DshLiveConnectionError.invalidEnvelope
            }
        }
    }
}
