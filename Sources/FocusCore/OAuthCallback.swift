import Foundation
import Network

enum OAuthCallbackError: Error { case failed, timedOut }

/// The listener exists only during sign-in and binds exclusively to this Mac's loopback interface.
@MainActor
final class OAuthCallback {
    private let listener: NWListener
    private var ready: CheckedContinuation<URL, any Error>?
    private var result: CheckedContinuation<URL, any Error>?
    private var state: String?
    private var callback: URL?
    private var timeoutTask: Task<Void, Never>?
    private var connections: [NWConnection] = []

    private let path: String

    init(path: String) throws {
        self.path = path
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { ready in
                self.ready = ready
                listener.stateUpdateHandler = { [weak self] status in
                    Task { @MainActor in
                        guard let self else { return }
                        if case .ready = status, let port = self.listener.port {
                            let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(self.path)")!
                            self.callback = url
                            self.ready?.resume(returning: url); self.ready = nil
                        } else if case .failed = status { self.stop(error: OAuthCallbackError.failed) }
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in self?.accept(connection) }
                }
                listener.start(queue: .main)
            }
        } onCancel: { Task { @MainActor in self.stop() } }
    }

    func open(_ url: URL, timeout: Duration = .seconds(300), browser: @escaping @Sendable (URL) async throws -> Void) async throws -> URL {
        state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { result in
                self.result = result
                timeoutTask = Task {
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    self.stop(error: OAuthCallbackError.timedOut)
                }
                Task {
                    do { try await browser(url) }
                    catch { self.stop(error: error) }
                }
            }
        } onCancel: { Task { @MainActor in self.stop() } }
    }

    func stop(error: any Error = CancellationError()) {
        timeoutTask?.cancel(); timeoutTask = nil
        listener.cancel()
        for connection in connections { connection.cancel() }
        connections = []
        ready?.resume(throwing: error); ready = nil
        result?.resume(throwing: error); result = nil
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 8 else { connection.cancel(); return }
        connections.append(connection)
        connection.start(queue: .main)
        receive(connection, bytes: Data())
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.close(connection) }
    }

    private func close(_ connection: NWConnection) {
        connection.cancel()
        connections.removeAll { $0 === connection }
    }

    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                let bytes = bytes + (data ?? Data())
                guard error == nil, bytes.count <= 8_192 else { self.close(connection); return }
                let request = String(decoding: bytes, as: UTF8.self)
                guard request.contains("\r\n\r\n") else {
                    if complete { self.close(connection) } else { self.receive(connection, bytes: bytes) }
                    return
                }
                let url = self.callbackURL(request)
                let text = url == nil ? "Invalid authorization callback." : "Authorization received. You can return to Focus Island."
                let response = "HTTP/1.1 \(url == nil ? "400 Bad Request" : "200 OK")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(text.utf8.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n\(text)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.close(connection)
                        if let url {
                            self.timeoutTask?.cancel(); self.timeoutTask = nil
                            self.result?.resume(returning: url); self.result = nil
                        }
                    }
                })
            }
        }
    }

    private func callbackURL(_ request: String) -> URL? {
        guard let callback, let state, result != nil else { return nil }
        let lines = request.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("\(path)?"),
              lines.contains(where: { $0.lowercased() == "host: 127.0.0.1:\(callback.port!)" }),
              let url = URL(string: "http://127.0.0.1:\(callback.port!)\(parts[1])"),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state else { return nil }
        return url
    }
}
