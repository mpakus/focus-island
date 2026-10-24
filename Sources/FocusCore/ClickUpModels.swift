import Foundation
import GRDB
import OpenIslandCore

public enum ClickUpError: Error, Equatable, LocalizedError {
    case signInRequired, accountChanged, invalidResponse, unavailable, commandFailed, databaseUnavailable, authorizationTimedOut, rateLimited
    case rateLimitedUntil(Date)
    public var errorDescription: String? {
        if case let .rateLimitedUntil(date) = self {
            return L10n.tr("clickup.rate_limited_until", date.formatted(date: .abbreviated, time: .shortened))
        }
        return L10n.tr("clickup.error.\(self)")
    }
}

public struct ClickUpConnection: Codable, Equatable, Sendable {
    public var workspaceID: String
    public var workspaceName: String
    public var userID: String
    public var username: String

    public init(workspaceID: String, workspaceName: String, userID: String, username: String) {
        self.workspaceID = workspaceID; self.workspaceName = workspaceName
        self.userID = userID; self.username = username
    }

    public func validate() throws {
        guard Self.isNumericID(workspaceID), Self.isNumericID(userID), !workspaceName.isEmpty, !username.isEmpty else { throw ClickUpError.invalidResponse }
    }
    static func isNumericID(_ value: String) -> Bool { value.range(of: "^[0-9]+$", options: .regularExpression) != nil }
}

public struct ClickUpTask: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var workspaceID: String
    public var title: String
    public var details: String?
    public var customID: String?
    public var listID: String
    public var listName: String
    public var parentID: String?
    public var status: String
    public var statusType: String
    public var assigneeIDs: [String]
    public var updatedAt: Date
    public var archived: Bool

    public var displayID: String { customID ?? id }
    public var unfinished: Bool { !archived && !["done", "closed"].contains(statusType) }
    public var url: URL? {
        guard Self.validID(id) else { return nil }
        return URL(string: "https://app.clickup.com/t/\(id)")
    }

    public func validate(workspaceID: String) throws {
        guard self.workspaceID == workspaceID, ClickUpConnection.isNumericID(workspaceID),
              Self.validID(id), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ClickUpConnection.isNumericID(listID), !status.isEmpty, !statusType.isEmpty,
              assigneeIDs.allSatisfy { $0.range(of: "^-?[0-9]+$", options: .regularExpression) != nil }, updatedAt.timeIntervalSince1970.isFinite,
              updatedAt.timeIntervalSince1970 > 0 else { throw ClickUpError.invalidResponse }
    }
    static func validID(_ value: String) -> Bool { value.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil }
}

public enum ClickUpTaskResult: Sendable {
    case task(ClickUpTask), unavailable(String)
    public var id: String {
        switch self { case .task(let task): task.id; case .unavailable(let id): id }
    }
}

public protocol ClickUpProviding: Sendable {
    func authorize() async throws -> ClickUpConnection
    func connect() async throws -> ClickUpConnection
    func search(connection: ClickUpConnection) async throws -> [ClickUpTask]
    func tasks(ids: [String], connection: ClickUpConnection) async throws -> [ClickUpTaskResult]
    func disconnect() throws
}

public struct ClickUpTaskLink: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "clickup_task_links"
    public var taskId: String
    public var workspaceID: String
    public var remoteTaskID: String
    public var customID: String?
    public var listID: String
    public var listName: String
    public var parentID: String?
    public var status: String
    public var statusType: String
    public var assigneeIDs: [String]
    public var remoteUpdatedAt: Date
    public var refreshedAt: Date
    public var unavailable: Bool
    public var archived: Bool

    public var displayID: String { customID ?? remoteTaskID }
    public var url: URL? {
        guard ClickUpTask.validID(remoteTaskID) else { return nil }
        return URL(string: "https://app.clickup.com/t/\(remoteTaskID)")
    }
}
