import Foundation
import GRDB
import OpenIslandCore

public enum JiraError: Error, Equatable, LocalizedError {
    case cliMissing, signInRequired, accountChanged, invalidResponse, unavailable, commandFailed, timedOut, databaseUnavailable

    public var errorDescription: String? { L10n.tr("jira.error.\(self)") }
}

public struct JiraConnection: Codable, Equatable, Sendable {
    public var site: String
    public var email: String
    public var cloudID: String

    public init(site: String, email: String, cloudID: String) {
        self.site = site
        self.email = email
        self.cloudID = cloudID
    }

    public static func canonicalSite(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let url = URL(string: value.contains("://") ? value : "https://\(value)"),
              url.scheme == "https", let host = url.host, host.hasSuffix(".atlassian.net"),
              host.count > ".atlassian.net".count, url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil, ["", "/"].contains(url.path)
        else { throw JiraError.invalidResponse }
        return "https://\(host)"
    }
}

public struct JiraIssue: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let key: String
    public let fields: Fields

    public struct Named: Decodable, Equatable, Sendable { public let name: String }
    public struct Status: Decodable, Equatable, Sendable {
        public let name: String
        public let statusCategory: Category?
        public struct Category: Decodable, Equatable, Sendable { public let key: String }
    }
    public struct Assignee: Decodable, Equatable, Sendable { public let accountId: String }
    public struct Fields: Decodable, Equatable, Sendable {
        public let summary: String
        public let description: JiraDocument?
        public let status: Status
        public let project: Named?
        public let issuetype: Named?
        public let priority: Named?
        public let assignee: Assignee?
        public let updated: String
    }

    public var updatedAt: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: fields.updated) ?? ISO8601DateFormatter().date(from: fields.updated)
    }

    public func validate() throws {
        guard id.range(of: "^[0-9]+$", options: .regularExpression) != nil,
              key.range(of: "^[A-Za-z][A-Za-z0-9_]*-[0-9]+$", options: .regularExpression) != nil,
              !fields.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              updatedAt != nil else { throw JiraError.invalidResponse }
    }
}

/// Text-only ADF rendering: unknown nodes retain their text; media stays in Jira.
public struct JiraDocument: Decodable, Equatable, Sendable {
    let type: String
    let text: String?
    let content: [JiraDocument]?

    public var plainText: String {
        String(render(depth: 0).trimmingCharacters(in: .whitespacesAndNewlines).prefix(50_000))
    }

    private func render(depth: Int) -> String {
        guard depth < 32 else { return "…" }
        if type == "hardBreak" { return "\n" }
        let body = text ?? (content ?? []).prefix(1_000).map { $0.render(depth: depth + 1) }.joined()
        return ["paragraph", "heading", "codeBlock", "listItem", "blockquote", "tableRow"].contains(type) ? body + "\n" : body
    }
}

public struct JiraTaskLink: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "jira_task_links"
    public var taskId: String
    public var cloudID: String
    public var site: String
    public var issueID: String
    public var key: String
    public var status: String
    public var statusCategory: String?
    public var assigneeID: String?
    public var remoteUpdatedAt: Date
    public var refreshedAt: Date
    public var unavailable: Bool

    public var url: URL? {
        guard let site = try? JiraConnection.canonicalSite(site),
              key.range(of: "^[A-Za-z][A-Za-z0-9_]*-[0-9]+$", options: .regularExpression) != nil else { return nil }
        return URL(string: "\(site)/browse/\(key)")
    }
}
