import Foundation
import GRDB

public final class JiraTaskService: Sendable {
    private let store: FocusStore
    public init(store: FocusStore) { self.store = store }

    @discardableResult
    public func importIssues(_ issues: [JiraIssue], connection: JiraConnection, column: BoardColumn = .backlog, projectPath: String? = nil, now: Date = .now) throws -> [String] {
        guard column == .backlog || column == .todo else { throw JiraError.invalidResponse }
        for issue in issues { try issue.validate() }
        return try store.dbQueue.write { db in
            try issues.map { issue in
                if let existing = try JiraTaskLink.filter(Column("cloudID") == connection.cloudID && Column("issueID") == issue.id).fetchOne(db) {
                    return existing.taskId
                }
                let task = try BoardService.insertTask(title: issue.fields.summary, column: column, projectPath: projectPath, details: issue.fields.description?.plainText, now: now, db: db)
                try Self.link(issue, taskID: task.id, connection: connection, now: now).insert(db)
                return task.id
            }
        }
    }

    public func refresh(_ issue: JiraIssue, link expected: JiraTaskLink, now: Date = .now) throws {
        try issue.validate()
        guard issue.id == expected.issueID else { throw JiraError.invalidResponse }
        try store.dbQueue.write { db in
            guard let current = try JiraTaskLink.fetchOne(db, key: expected.taskId),
                  current == expected, var task = try FocusTask.fetchOne(db, key: current.taskId),
                  let updated = issue.updatedAt, updated >= current.remoteUpdatedAt else { return }
            task.title = issue.fields.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            task.details = issue.fields.description?.plainText
            task.updatedAt = now
            try task.update(db)
            let connection = JiraConnection(site: current.site, email: "", cloudID: current.cloudID)
            try Self.link(issue, taskID: task.id, connection: connection, now: now).update(db)
        }
    }

    public func markUnavailable(_ expected: JiraTaskLink) throws {
        try store.dbQueue.write { db in
            guard var current = try JiraTaskLink.fetchOne(db, key: expected.taskId), current == expected else { return }
            current.unavailable = true
            try current.update(db)
        }
    }

    public func detach(taskID: String) throws {
        _ = try store.dbQueue.write { db in try JiraTaskLink.deleteOne(db, key: taskID) }
    }

    private static func link(_ issue: JiraIssue, taskID: String, connection: JiraConnection, now: Date) -> JiraTaskLink {
        JiraTaskLink(taskId: taskID, cloudID: connection.cloudID, site: connection.site, issueID: issue.id,
                     key: issue.key, status: issue.fields.status.name, statusCategory: issue.fields.status.statusCategory?.key,
                     assigneeID: issue.fields.assignee?.accountId, remoteUpdatedAt: issue.updatedAt!, refreshedAt: now, unavailable: false)
    }
}
