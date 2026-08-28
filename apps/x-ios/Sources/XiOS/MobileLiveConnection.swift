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
    /// One canonical frame from the Host-owned `xNative/follow` contract.
    case feed(MobileJSONValue)
}

private enum MobileLiveConnectionError: Error {
    case bufferOverflow
    case streamEnded
    case socketClosedBeforeOpen
    case socketOpenTimedOut
    case invalidBaseURL
    case invalidEnvelope
    case remoteFailure(String)
}

private struct MobileNativeFollowRequest: Encodable {
    let sessionId: String?
    let parentSessionId: String?
    let mode: String?
    let maxMessages: Int
}

private struct MobileNativeFollowArguments: Encodable {
    let request: MobileNativeFollowRequest
}

private struct MobileNativeFollowPayload: Encodable {
    let args: MobileNativeFollowArguments
}

private struct MobileRemoteStreamOpen: Encodable {
    let type = "open"
    let streamId: String
    let endpoint = "xNative/follow"
    let payload: MobileNativeFollowPayload
}

private struct MobileRemoteStreamCancel: Encodable {
    let type = "cancel"
    let streamId: String
}

private struct MobileRemoteStreamFailure: Decodable {
    let code: String
    let message: String
}

private struct MobileRemoteStreamFrame: Decodable {
    let type: String
    let streamId: String
    let value: MobileJSONValue?
    let error: MobileRemoteStreamFailure?
}

/// Bridges URLSession's WebSocket-open callback into async readiness.
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
        if waiter == nil, !wasOpen { failures[identifier] = failure }
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

/// One authenticated Gateway carrier for Host-wide and selected-task live data.
actor MobileLiveConnection {
    nonisolated let updates: AsyncStream<MobileLiveUpdate>
    private let baseURL: URL
    private let token: String?
    private let continuation: AsyncStream<MobileLiveUpdate>.Continuation
    private let trustDelegate: MobileWebSocketDelegate
    private let session: URLSession
    private var task: Task<Void, Never>?
    private var activeSocket: URLSessionWebSocketTask?
    private var activeStreamId: String?
    private var selectedSessionId: String?
    private var selectedParentSessionId: String?
    private var selectedMode: String?

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
        activeStreamId = nil
        activeSocket?.cancel(with: .goingAway, reason: nil)
        activeSocket = nil
    }

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

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                let socket = try makeSocket()
                activeSocket = socket
                socket.resume()
                try await trustDelegate.waitUntilOpen(socket)
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

    private func publish(_ update: MobileLiveUpdate) throws {
        switch continuation.yield(update) {
        case .enqueued: return
        case .dropped: throw MobileLiveConnectionError.bufferOverflow
        case .terminated: throw MobileLiveConnectionError.streamEnded
        @unknown default: throw MobileLiveConnectionError.streamEnded
        }
    }

    private func makeSocket() throws -> URLSessionWebSocketTask {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw MobileLiveConnectionError.invalidBaseURL
        }
        switch components.scheme {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: throw MobileLiveConnectionError.invalidBaseURL
        }
        components.path = "/api/remote.mux"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw MobileLiveConnectionError.invalidBaseURL }
        var request = URLRequest(url: url)
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        }
        return session.webSocketTask(with: request)
    }

    private func replaceFollowStream(on socket: URLSessionWebSocketTask) async throws {
        if let oldStreamId = activeStreamId {
            try await send(MobileRemoteStreamCancel(streamId: oldStreamId), on: socket)
        }
        let streamId = UUID().uuidString.lowercased()
        activeStreamId = streamId
        try await send(MobileRemoteStreamOpen(
            streamId: streamId,
            payload: MobileNativeFollowPayload(args: MobileNativeFollowArguments(request: MobileNativeFollowRequest(
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
            throw MobileLiveConnectionError.invalidEnvelope
        }
        try await socket.send(.string(text))
    }

    private func pump(_ socket: URLSessionWebSocketTask) async throws {
        let decoder = JSONDecoder()
        while !Task.isCancelled {
            let message = try await socket.receive()
            let data: Data
            switch message {
            case let .data(value): data = value
            case let .string(value): data = Data(value.utf8)
            @unknown default: throw MobileLiveConnectionError.invalidEnvelope
            }
            let frame = try decoder.decode(MobileRemoteStreamFrame.self, from: data)
            guard frame.streamId == activeStreamId else { continue }
            switch frame.type {
            case "item":
                if let value = frame.value { try publish(.feed(value)) }
            case "error":
                let failure = frame.error
                throw MobileLiveConnectionError.remoteFailure(
                    [failure?.code, failure?.message].compactMap { $0 }.joined(separator: ": ")
                )
            case "end":
                throw MobileLiveConnectionError.streamEnded
            default:
                throw MobileLiveConnectionError.invalidEnvelope
            }
        }
    }
}
