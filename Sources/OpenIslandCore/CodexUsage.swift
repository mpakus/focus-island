import Foundation
import Darwin

public enum CodexUsageError: Error, Equatable, LocalizedError {
    case unavailable, signInRequired, unsupportedAccount, invalidResponse, timedOut
    public var errorDescription: String? { L10n.tr("codex.usage.\(self)") }
}

public struct CodexUsageWindow: Equatable, Sendable, Identifiable {
    public let id: String
    public let usedPercentage: Double
    public let durationMinutes: Int?
    public let resetsAt: Date?
    public var label: String {
        guard let minutes = durationMinutes, minutes > 0 else { return L10n.tr("codex.usage.\(id)") }
        if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}

public struct CodexUsageBucket: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let windows: [CodexUsageWindow]
}

public struct CodexUsageSnapshot: Equatable, Sendable {
    public let buckets: [CodexUsageBucket]
    public let fetchedAt: Date

    public static func decode(_ data: Data, now: Date = .now) throws -> Self {
        struct Window: Decodable { let usedPercent: Double; let windowDurationMins: Int?; let resetsAt: Double? }
        struct Limit: Decodable { let limitId: String?; let limitName: String?; let primary: Window?; let secondary: Window? }
        struct Response: Decodable { let rateLimits: Limit?; let rateLimitsByLimitId: [String: Limit]? }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw CodexUsageError.invalidResponse }
        let limits = response.rateLimitsByLimitId.flatMap { $0.isEmpty ? nil : $0 }
            ?? response.rateLimits.map { [$0.limitId ?? "codex": $0] } ?? [:]
        let buckets = limits.sorted { $0.key < $1.key }.compactMap { id, limit -> CodexUsageBucket? in
            let windows = [("primary", limit.primary), ("secondary", limit.secondary)].compactMap { key, value -> CodexUsageWindow? in
                guard let value, value.usedPercent.isFinite else { return nil }
                return CodexUsageWindow(id: key, usedPercentage: min(100, max(0, value.usedPercent)),
                    durationMinutes: value.windowDurationMins,
                    resetsAt: value.resetsAt.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil })
            }
            guard !windows.isEmpty else { return nil }
            return CodexUsageBucket(id: id, name: limit.limitName ?? (id == "codex" ? "Codex" : "Codex · \(id)"), windows: windows)
        }
        guard !buckets.isEmpty else { throw CodexUsageError.unavailable }
        return Self(buckets: buckets, fetchedAt: now)
    }
}

/// One short-lived, quota-only app-server connection; no conversation or login is created.
public enum CodexUsageClient {
    public static func executable(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        let candidates = directories.map { "\($0)/codex" } + ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex"]
            + ["/Applications", "\(home)/Applications"].flatMap { directory in
                ["Codex", "ChatGPT"].flatMap { app in
                    ["\(directory)/\(app).app/Contents/Resources/codex", "\(directory)/\(app).app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"]
                }
            }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    public static func read(executable: URL? = executable(), timeout: TimeInterval = 15) async throws -> CodexUsageSnapshot {
        guard let executable else { throw CodexUsageError.unavailable }
        let session = Session(executable: executable, timeout: timeout)
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { try session.read() }.value
        } onCancel: { session.cancel() }
    }

    private final class Session: @unchecked Sendable {
        let executable: URL
        let timeout: TimeInterval
        private let lock = NSLock()
        private var cancelled = false
        init(executable: URL, timeout: TimeInterval) { self.executable = executable; self.timeout = timeout }
        func cancel() { lock.withLock { cancelled = true } }

        func read() throws -> CodexUsageSnapshot {
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = executable
            process.arguments = ["app-server", "--listen", "stdio://", "-c", "analytics.enabled=false"]
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try check()
            do { try process.run() } catch { throw CodexUsageError.unavailable }
            input.fileHandleForReading.closeFile(); output.fileHandleForWriting.closeFile()
            defer {
                try? input.fileHandleForWriting.close()
                let end = Date().addingTimeInterval(0.2)
                while process.isRunning && Date() < end { usleep(10_000) }
                if process.isRunning { process.terminate() }
                let stop = Date().addingTimeInterval(0.2)
                while process.isRunning && Date() < stop { usleep(10_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                try? output.fileHandleForReading.close()
            }
            let fd = output.fileHandleForReading.fileDescriptor
            guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1,
                  fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { throw CodexUsageError.unavailable }
            let deadline = Date().addingTimeInterval(timeout)
            var buffer = Data(), total = 0
            func send(_ method: String, id: Int? = nil, params: [String: Any]) throws {
                var body: [String: Any] = ["method": method, "params": params]
                if let id { body["id"] = id }
                var data = try JSONSerialization.data(withJSONObject: body); data.append(10)
                do { try input.fileHandleForWriting.write(contentsOf: data) } catch { throw CodexUsageError.unavailable }
            }
            func response(_ id: Int) throws -> [String: Any] {
                while true {
                    try check()
                    guard Date() < deadline else { throw CodexUsageError.timedOut }
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
                        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw CodexUsageError.invalidResponse }
                        if message["method"] != nil {
                            guard message["id"] == nil else { throw CodexUsageError.invalidResponse }
                            continue
                        }
                        guard message["id"] as? Int == id else { throw CodexUsageError.invalidResponse }
                        guard message["error"] == nil, let result = message["result"] as? [String: Any] else { throw CodexUsageError.unavailable }
                        return result
                    }
                    var bytes = [UInt8](repeating: 0, count: 8192)
                    let count = Darwin.read(fd, &bytes, bytes.count)
                    if count > 0 {
                        total += count
                        guard total <= 2 * 1024 * 1024, buffer.count + count <= 256 * 1024 else { throw CodexUsageError.invalidResponse }
                        buffer.append(contentsOf: bytes.prefix(count))
                    } else if count == 0 { throw CodexUsageError.unavailable }
                    else if errno != EAGAIN && errno != EINTR { throw CodexUsageError.unavailable }
                    else { usleep(10_000) }
                }
            }
            try send("initialize", id: 1, params: ["clientInfo": ["name": "focus_island_usage", "version": "0.7.0"], "capabilities": ["explicitGatewayOauth": true]])
            _ = try response(1)
            try send("initialized", params: [:])
            try send("account/read", id: 2, params: ["refreshToken": false])
            let account = try response(2)
            guard let account = account["account"] as? [String: Any] else { throw CodexUsageError.signInRequired }
            guard account["type"] as? String == "chatgpt" else { throw CodexUsageError.unsupportedAccount }
            try send("account/rateLimits/read", id: 3, params: ["excludeResetCreditDetails": true])
            return try CodexUsageSnapshot.decode(JSONSerialization.data(withJSONObject: response(3)))
        }
        private func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
    }
}
