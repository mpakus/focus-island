import Foundation
import GRDB
import Testing
@testable import FocusCore

struct FocusBackupsTests {
    @Test func snapshotRestorePreservesEveryTableAndKeepsCurrentDataForRecovery() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("focus.sqlite")
        let store = try FocusStore(fileURL: url)
        let mode = try store.dbQueue.writeWithoutTransaction { try String.fetchOne($0, sql: "PRAGMA journal_mode = WAL") }
        #expect(mode == "wal")
        let task = try BoardService(store: store).createTask(title: "Before", column: .inProgress)
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE tasks SET note = 'Keep my note' WHERE id = ?", arguments: [task.id])
            try db.execute(sql: "INSERT INTO sessions (id, title, startedAt, lastActivityAt, status, taskId, provider, nativeSessionID) VALUES ('codex:s', 'Session', 100, 200, 'ended', ?, 'codex', 's')", arguments: [task.id])
            try db.execute(sql: "INSERT INTO day_plans (day, tomorrowNote) VALUES ('2026-10-26', 'Next step')")
            try db.execute(sql: "INSERT INTO jira_task_links (taskId, cloudID, site, issueID, key, status, remoteUpdatedAt, refreshedAt) VALUES (?, 'cloud', 'https://example.atlassian.net', '123', 'TEST-1', 'Open', 100, 200)", arguments: [task.id])
        }
        let clickUpTask = try BoardService(store: store).createTask(title: "ClickUp", column: .done)
        try store.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO clickup_task_links (taskId, workspaceID, remoteTaskID, listID, listName, status, statusType, assigneeIDs, remoteUpdatedAt, refreshedAt) VALUES (?, 'workspace', 'remote', 'list', 'Test list', 'Closed', 'closed', '[]', 100, 200)", arguments: [clickUpTask.id])
        }
        try TaskCriteriaService(store: store).add(taskID: task.id, text: "Check the result")
        try PromptQueue(store: store).enqueue(sessionID: "codex:s", taskID: task.id, text: "Continue")
        _ = try ActivityLog(store: store).open(kind: .codex, sessionID: "codex:s", taskID: task.id, at: .now)
        _ = try PomodoroStore(store: store).start(taskID: task.id, phase: .focus, plannedSeconds: 1500)
        let before = try contents(store.dbQueue)
        let backups = try FocusBackups(store: store)
        let original = try backups.create()
        let snapshot = directory.appendingPathComponent("portable.sqlite")
        // Copy only the database file, without the live source's WAL or SHM files.
        try FileManager.default.copyItem(at: original, to: snapshot)
        let preview = try backups.preview(snapshot)
        #expect(preview.tasks == 2 && preview.sessions == 1 && preview.notes == 1 && preview.criteria == 1 && preview.pomodoros == 1)
        // Preview freezes the selected file; changing its source must not change what is restored.
        try Data("source changed after preview".utf8).write(to: snapshot)
        _ = try BoardService(store: store).createTask(title: "After backup", column: .todo)
        try backups.stage(preview)
        try store.dbQueue.close()
        let restored = try FocusStore(fileURL: url)
        #expect(restored.restoreError == nil)
        #expect(try contents(restored.dbQueue) == before)
        let recovery = try #require(FileManager.default.contentsOfDirectory(at: backups.directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("before-restore-") })
        let recoveryStore = try FocusStore(fileURL: recovery)
        #expect(try BoardService(store: recoveryStore).snapshot().tasks.count == 3)
        try recoveryStore.dbQueue.close()
        _ = try BoardService(store: restored).createTask(title: "After restore", column: .todo)
        try restored.dbQueue.close()
        let reopened = try FocusStore(fileURL: url)
        #expect(try BoardService(store: reopened).snapshot().tasks.count == 3)
        try reopened.dbQueue.close()
    }

    @Test func olderBackupIsMigratedOnACopyAndPreviewCanBeCancelled() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("old.sqlite")
        let old = try DatabaseQueue(path: source.path)
        try FocusStore.migrator(upTo: "v5").migrate(old)
        let store = try FocusStore(fileURL: directory.appendingPathComponent("current.sqlite"))
        let backups = try FocusBackups(store: store)
        let preview = try backups.preview(source)
        #expect(preview.tasks == 0)
        #expect(try old.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM grdb_migrations") } == 5)
        backups.discard(preview)
        #expect(!FileManager.default.fileExists(atPath: preview.preparedURL.path))
        #expect(try BoardService(store: store).snapshot().tasks.isEmpty)
        try old.close(); try store.dbQueue.close()
    }

    @Test func invalidFutureAndModifiedSchemasAreRejectedWithoutChangingCurrentData() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FocusStore(fileURL: directory.appendingPathComponent("focus.sqlite"))
        _ = try BoardService(store: store).createTask(title: "Keep", column: .todo)
        let backups = try FocusBackups(store: store)
        let invalid = directory.appendingPathComponent("invalid.sqlite")
        try Data("not a database".utf8).write(to: invalid)
        #expect(throws: (any Error).self) { try backups.preview(invalid) }
        for change in ["INSERT INTO grdb_migrations VALUES ('v99')", "CREATE TRIGGER unwanted AFTER INSERT ON tasks BEGIN DELETE FROM tasks; END"] {
            let snapshot = try backups.create()
            let candidate = try DatabaseQueue(path: snapshot.path)
            try candidate.write { try $0.execute(sql: change) }
            try candidate.close()
            #expect(throws: FocusBackupError.self) { try backups.preview(snapshot) }
        }
        #expect(try BoardService(store: store).snapshot().tasks.map(\.title) == ["Keep"])
        #expect(throws: FocusBackupError.self) { try backups.export(to: backups.databaseURL) }
        try store.dbQueue.close()
    }

    @Test func damagedPendingRestoreKeepsCurrentDatabaseAndDoesNotReplay() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("focus.sqlite")
        let store = try FocusStore(fileURL: url)
        _ = try BoardService(store: store).createTask(title: "Keep", column: .todo)
        let backups = try FocusBackups(store: store)
        try backups.stage(backups.preview(backups.create()))
        try Data("damaged".utf8).write(to: url.appendingPathExtension("pending-restore.sqlite"))
        try store.dbQueue.close()
        let reopened = try FocusStore(fileURL: url)
        #expect(reopened.restoreError != nil)
        #expect(try BoardService(store: reopened).snapshot().tasks.map(\.title) == ["Keep"])
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("pending-restore.sqlite").path))
        try reopened.dbQueue.close()
    }

    @Test func dailyBackupsAreConsistentBoundedAndDoNotDeleteManualCopies() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FocusStore(fileURL: directory.appendingPathComponent("focus.sqlite"))
        let backups = try FocusBackups(store: store)
        let manual = try backups.create()
        let start = Date(timeIntervalSince1970: 20_000 * 86_400)
        for day in 0..<10 { try backups.daily(now: start.addingTimeInterval(Double(day) * 86_400)) }
        try backups.daily(now: start.addingTimeInterval(9 * 86_400))
        let files = try FileManager.default.contentsOfDirectory(at: backups.directory, includingPropertiesForKeys: nil)
        #expect(files.filter { $0.lastPathComponent.hasPrefix("daily-") }.count == 7)
        #expect(FileManager.default.fileExists(atPath: manual.path))
        let exported = directory.appendingPathComponent("export.sqlite")
        try Data("previous export".utf8).write(to: exported)
        try backups.export(to: exported)
        let preview = try backups.preview(exported)
        #expect(preview.tasks == 0)
        backups.discard(preview)
        try store.dbQueue.close()
        #expect(throws: FocusBackupError.self) { try FocusBackups(store: FocusStore.inMemory()) }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("focus-backups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func contents(_ queue: DatabaseQueue) throws -> [String: [String]] {
        try queue.read { db in
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
            return try Dictionary(uniqueKeysWithValues: tables.map { table in
                (table, try Row.fetchAll(db, sql: "SELECT * FROM \"\(table)\" ORDER BY rowid").map { String(describing: $0) })
            })
        }
    }
}
