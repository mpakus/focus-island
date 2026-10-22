import Foundation

public struct CodexSessionRegistry: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = BridgeSocketLocation.defaultURL.deletingLastPathComponent().appendingPathComponent("codex-sessions.json")) {
        self.fileURL = fileURL
    }

    private struct Records: Codable {
        var version = 1
        var sessions: [AgentSession]
    }

    public func save(_ sessions: [AgentSession]) throws {
        let records = Records(sessions: sessions.filter { $0.tool == .codex && !$0.isDemoSession })
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records).write(to: fileURL, options: .atomic)
    }

    public func load() throws -> [AgentSession] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode(Records.self, from: Data(contentsOf: fileURL))
        guard records.version == 1 else { return [] }
        return records.sessions.filter {
            $0.tool == .codex && $0.codexMetadata?.ended == false
        }.map { stored in
            var session = stored
            session.isHookManaged = true
            session.isProcessAlive = false
            session.attachmentState = .stale
            session.codexMetadata?.isStale = true
            session.phase = .idle
            session.permissionRequest = nil
            session.questionPrompt = nil
            session.summary = "Codex status unconfirmed — waiting for a new event."
            return session
        }
    }
}
