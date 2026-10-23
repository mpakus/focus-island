import Foundation

public protocol JiraProviding: Sendable {
    func connect() async throws -> JiraConnection
    func search(connection: JiraConnection) async throws -> [JiraIssue]
    func issue(id: String, connection: JiraConnection) async throws -> JiraIssue
}

public struct JiraCLIClient: JiraProviding {
    public static let jql = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC, key ASC"
    static let fields = "summary,status,project,issuetype,priority,assignee,updated"
    private let run: @Sendable ([String]) async throws -> Data
    private let cloudID: @Sendable (String) async throws -> String

    public init(
        run: @escaping @Sendable ([String]) async throws -> Data = { try await JiraCommand.run($0) },
        cloudID: @escaping @Sendable (String) async throws -> String = { site in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(from: URL(string: "\(site)/_edge/tenant_info")!)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let value = try JSONSerialization.jsonObject(with: data) as? [String: String],
                  let id = value["cloudId"], UUID(uuidString: id) != nil else { throw JiraError.invalidResponse }
            return id
        }
    ) {
        self.run = run
        self.cloudID = cloudID
    }

    public func connect() async throws -> JiraConnection {
        let account = try Self.account(from: await run(["jira", "auth", "status"]))
        let id = try await cloudID(account.site)
        guard UUID(uuidString: id) != nil else { throw JiraError.invalidResponse }
        let connection = JiraConnection(site: account.site, email: account.email, cloudID: id)
        try await verify(connection)
        return connection
    }

    public func search(connection: JiraConnection) async throws -> [JiraIssue] {
        try await verify(connection)
        let data = try await run(["jira", "workitem", "search", "--jql", Self.jql, "--fields", Self.fields, "--paginate", "--json"])
        try await verify(connection)
        return try Self.decodeSearch(data)
    }

    public func issue(id: String, connection: JiraConnection) async throws -> JiraIssue {
        guard id.range(of: "^[0-9]+$", options: .regularExpression) != nil else { throw JiraError.invalidResponse }
        try await verify(connection)
        let data = try await run(["jira", "workitem", "view", id, "--fields", Self.fields + ",description", "--json"])
        try await verify(connection)
        let issue: JiraIssue
        do { issue = try JSONDecoder().decode(JiraIssue.self, from: data) }
        catch { throw JiraError.invalidResponse }
        try issue.validate()
        guard issue.id == id else { throw JiraError.invalidResponse }
        return issue
    }

    private func verify(_ connection: JiraConnection) async throws {
        let account = try Self.account(from: await run(["jira", "auth", "status"]))
        guard account.site == connection.site, account.email == connection.email else { throw JiraError.accountChanged }
    }

    static func account(from data: Data) throws -> (site: String, email: String) {
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
        func value(_ label: String) -> String? {
            lines.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(label) }?
                .trimmingCharacters(in: .whitespaces).dropFirst(label.count).trimmingCharacters(in: .whitespaces)
        }
        // shortcut: ACLI 1.3 has no JSON auth status; reject unknown formats until a structured command exists.
        guard let site = value("Site:") ?? value("Authenticated site:"),
              let email = value("Email:"), email.contains("@"), !email.contains(" ") else { throw JiraError.signInRequired }
        return (try JiraConnection.canonicalSite(site), email.lowercased())
    }

    static func decodeSearch(_ data: Data) throws -> [JiraIssue] {
        struct Page: Decodable {
            let issues: [JiraIssue]
            let isLast: Bool?
            let nextPageToken: String?
        }
        let issues: [JiraIssue]
        do {
            if let array = try? JSONDecoder().decode([JiraIssue].self, from: data) {
                issues = array
            } else {
                let page = try JSONDecoder().decode(Page.self, from: data)
                guard page.isLast != false, page.nextPageToken == nil else { throw JiraError.invalidResponse }
                issues = page.issues
            }
        } catch { throw JiraError.invalidResponse }
        var seen = Set<String>()
        return try issues.filter { issue in
            try issue.validate()
            return seen.insert(issue.id).inserted
        }
    }
}

/// Only fixed, read-only ACLI commands are constructed by JiraCLIClient. No shell or credential files.
public enum JiraCommand {
    public static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = ["/opt/homebrew/bin/acli", "/usr/local/bin/acli", "\(home)/.local/bin/acli"]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    public static func run(_ arguments: [String], executable: URL? = nil, timeout: TimeInterval = 90) async throws -> Data {
        guard let executable = executable ?? self.executable() else { throw JiraError.cliMissing }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("output")
        let errors = folder.appendingPathComponent("errors")
        for file in [output, errors] {
            guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw JiraError.commandFailed }
        }
        let stdout = try FileHandle(forWritingTo: output)
        let stderr = try FileHandle(forWritingTo: errors)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        environment["LANG"] = "en_US.UTF-8"
        process.environment = environment
        try Task.checkCancellation()
        do { try process.run() } catch { throw JiraError.commandFailed }
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            try Task.checkCancellation()
            guard Date() < deadline else { throw JiraError.timedOut }
            for file in [output, errors] {
                let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
                guard size <= 16 * 1_024 * 1_024 else { throw JiraError.invalidResponse }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        for file in [output, errors] {
            let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size <= 16 * 1_024 * 1_024 else { throw JiraError.invalidResponse }
        }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: try Data(contentsOf: errors), as: UTF8.self).lowercased()
            if message.contains("unauthorized") || message.contains("auth login") { throw JiraError.signInRequired }
            if message.contains("404") || message.contains("not found") || message.contains("403") || message.contains("forbidden") { throw JiraError.unavailable }
            throw JiraError.commandFailed
        }
        let data = try Data(contentsOf: output)
        guard data.count <= 16 * 1_024 * 1_024 else { throw JiraError.invalidResponse }
        return data
    }
}
