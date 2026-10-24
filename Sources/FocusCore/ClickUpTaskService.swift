import Foundation
import GRDB

public final class ClickUpTaskService: Sendable {
    private let store: FocusStore
    public init(store: FocusStore) { self.store = store }

    @discardableResult
    public func importTasks(_ tasks: [ClickUpTask], connection: ClickUpConnection, column: BoardColumn = .backlog, projectPath: String? = nil, now: Date = .now) throws -> [String] {
        try connection.validate()
        guard column == .backlog || column == .todo else { throw ClickUpError.invalidResponse }
        for task in tasks { try task.validate(workspaceID: connection.workspaceID) }
        return try store.dbQueue.write { db in
            try tasks.map { remote in
                if let existing = try ClickUpTaskLink.filter(Column("workspaceID") == connection.workspaceID && Column("remoteTaskID") == remote.id).fetchOne(db) {
                    return existing.taskId
                }
                let task = try BoardService.insertTask(title: remote.title, column: column, projectPath: projectPath, details: remote.details, now: now, db: db)
                try Self.link(remote, taskID: task.id, now: now).insert(db)
                return task.id
            }
        }
    }

    public func refresh(_ remote: ClickUpTask, link expected: ClickUpTaskLink, now: Date = .now) throws {
        try remote.validate(workspaceID: expected.workspaceID)
        guard remote.id == expected.remoteTaskID else { throw ClickUpError.invalidResponse }
        try store.dbQueue.write { db in
            guard let current = try ClickUpTaskLink.fetchOne(db, key: expected.taskId), current == expected,
                  remote.updatedAt >= current.remoteUpdatedAt, var task = try FocusTask.fetchOne(db, key: current.taskId) else { return }
            task.title = remote.title.trimmingCharacters(in: .whitespacesAndNewlines)
            task.details = remote.details
            task.updatedAt = now
            try task.update(db)
            try Self.link(remote, taskID: task.id, now: now).update(db)
        }
    }

    public func markUnavailable(_ expected: ClickUpTaskLink) throws {
        try store.dbQueue.write { db in
            guard var current = try ClickUpTaskLink.fetchOne(db, key: expected.taskId), current == expected else { return }
            current.unavailable = true
            try current.update(db)
        }
    }

    public func detach(taskID: String) throws {
        _ = try store.dbQueue.write { db in try ClickUpTaskLink.deleteOne(db, key: taskID) }
    }

    private static func link(_ remote: ClickUpTask, taskID: String, now: Date) -> ClickUpTaskLink {
        ClickUpTaskLink(taskId: taskID, workspaceID: remote.workspaceID, remoteTaskID: remote.id, customID: remote.customID,
            listID: remote.listID, listName: remote.listName, parentID: remote.parentID, status: remote.status, statusType: remote.statusType,
            assigneeIDs: remote.assigneeIDs, remoteUpdatedAt: remote.updatedAt, refreshedAt: now, unavailable: false, archived: remote.archived)
    }
}
