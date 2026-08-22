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
    case host(MobileServerRequest)
    case mux(MobileServerRequest)
}

private enum MobileLiveConnectionError: Error {
    case bufferOverflow
    case streamEnded
}

actor MobileLiveConnection {
    nonisolated let updates: AsyncStream<MobileLiveUpdate>
    private let baseURL: URL
    private let token: String?
    private let continuation: AsyncStream<MobileLiveUpdate>.Continuation
    private let session: URLSession
    private var task: Task<Void, Never>?
    private var sockets: [URLSessionWebSocketTask] = []

    init(baseURL: URL, token: String?) {
        self.baseURL = baseURL
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)
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
                sockets.forEach { $0.cancel(with: .goingAway, reason: nil) }
                sockets = []
                if Task.isCancelled { return }
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
