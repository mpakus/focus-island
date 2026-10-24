import Foundation
import GRDB
import OpenIslandCore
import Testing
@testable import FocusCore

func clickUpFixture(id: String = "abc", key: String = "CU-1", title: String = "A ClickUp task", updated: String = "2026-10-23T10:00:00.000Z", status: String = "Open") throws -> ClickUpTask {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return ClickUpTask(id: id, workspaceID: "100", title: title, details: "Source description", customID: key, listID: "20", listName: "Example list", parentID: nil, status: status, statusType: "open", assigneeIDs: ["7"], updatedAt: try #require(formatter.date(from: updated)), archived: false)
}

struct ClickUpTaskServiceTests {
    @Test func importsAreIdempotentScopedAndNeverStartFocus() throws {
        let store = try FocusStore.inMemory()
        let service = ClickUpTaskService(store: store)
        var task = try clickUpFixture()
        let first = try service.importTasks([task, task], connection: clickUpTestConnection)
        #expect(first[0] == first[1])
        #expect(try service.importTasks([task], connection: clickUpTestConnection) == [first[0]])
        var other = clickUpTestConnection; other.workspaceID = "200"; task.workspaceID = "200"
        let second = try service.importTasks([task], connection: other)
        #expect(first[0] != second[0])
        let snapshot = try BoardService(store: store).snapshot()
        #expect(snapshot.tasks.count == 2 && snapshot.clickUpLinks.count == 2)
        #expect(snapshot.tasks.allSatisfy { $0.boardColumn == .backlog })
        #expect(snapshot.currentTask(liveSessions: []) == nil)
    }

    @Test func refreshAndStaleEditorPreserveLocalWork() throws {
        let store = try FocusStore.inMemory()
        let service = ClickUpTaskService(store: store)
        let board = BoardService(store: store)
        let id = try service.importTasks([clickUpFixture()], connection: clickUpTestConnection, column: .todo, projectPath: "/tmp/repo")[0]
        var stale = try #require(board.snapshot().task(id: id))
        stale.note = "Local unsaved note"
        try board.moveTask(id: id, to: .done, beforeTaskID: nil, now: Date(timeIntervalSince1970: 500))
        try store.dbQueue.write { db in
            for provider in [AgentTool.claudeCode, .codex] {
                try SessionRecord(id: provider.rawValue, cwd: nil, projectName: nil, title: "Session", firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: .now, lastActivityAt: .now, endedAt: nil, status: .live, taskId: id, transcriptPath: nil, provider: provider).insert(db)
            }
            try TaskCriterion(id: "criterion", taskId: id, text: "Local criterion", done: true, position: 1, createdAt: .now).insert(db)
            try QueuedPrompt(id: "prompt", sessionId: "codex", taskId: id, text: "Local prompt", createdAt: .now).insert(db)
            var span = ActivitySpan(kind: .codex, sessionId: "codex", taskId: id, startedAt: .now)
            try span.insert(db)
            try db.execute(sql: "INSERT INTO pomodoros (id,taskId,phase,plannedSeconds,startedAt,pausedSeconds,completed) VALUES ('timer',?,'focus',1500,?,0,0)", arguments: [id, Date()])
            try DayPlan(day: "2026-10-23", focusTaskIds: [id], tomorrowNote: "Tomorrow").insert(db)
        }
        let tables = ["sessions", "task_criteria", "queued_prompts", "activity_spans", "pomodoros", "day_plans"]
        let before = try store.dbQueue.read { db in try tables.map { try Row.fetchAll(db, sql: "SELECT * FROM \($0)") } }
        let link = try #require(board.snapshot().clickUpLinks[id])
        try service.refresh(clickUpFixture(key: "MOVED-9", title: "Fresh source title", updated: "2026-10-24T10:00:00.000+0000", status: "Done"), link: link)
        try board.updateTask(stale)
        let task = try #require(board.snapshot().task(id: id))
        #expect(task.title == "Fresh source title")
        #expect(task.note == "Local unsaved note" && task.projectPath == "/tmp/repo")
        #expect(task.boardColumn == .done && task.doneAt == Date(timeIntervalSince1970: 500))
        #expect(try board.snapshot().clickUpLinks[id]?.customID == "MOVED-9")
        #expect(try store.dbQueue.read { db in try tables.map { try Row.fetchAll(db, sql: "SELECT * FROM \($0)") } } == before)
    }

    @Test func detachedDeletedOrOlderResponsesCannotRestoreLinks() throws {
        for delete in [false, true] {
            let store = try FocusStore.inMemory()
            let service = ClickUpTaskService(store: store)
            let board = BoardService(store: store)
            let issue = try clickUpFixture()
            let id = try service.importTasks([issue], connection: clickUpTestConnection)[0]
            let link = try #require(board.snapshot().clickUpLinks[id])
            try service.refresh(clickUpFixture(title: "Old", updated: "2026-10-22T10:00:00.000Z"), link: link)
            #expect(try board.snapshot().task(id: id)?.title == issue.title)
            if delete { try board.deleteTask(id: id) } else { try service.detach(taskID: id) }
            try service.refresh(issue, link: link)
            try service.markUnavailable(link)
            #expect(try board.snapshot().clickUpLinks.isEmpty)
            #expect(try board.snapshot().tasks.count == (delete ? 0 : 1))
        }
    }

    @Test func invalidBatchLeavesNoTasksAndUnavailableKeepsData() throws {
        let store = try FocusStore.inMemory()
        let service = ClickUpTaskService(store: store)
        #expect(throws: ClickUpError.invalidResponse) {
            try service.importTasks([clickUpFixture(), clickUpFixture(id: "bad id")], connection: clickUpTestConnection)
        }
        let board = BoardService(store: store)
        #expect(try board.snapshot().tasks.isEmpty)
        let id = try service.importTasks([clickUpFixture()], connection: clickUpTestConnection)[0]
        let before = try board.snapshot()
        try service.markUnavailable(#require(before.clickUpLinks[id]))
        #expect(try board.snapshot().tasks == before.tasks)
        #expect(try board.snapshot().clickUpLinks[id]?.unavailable == true)
    }

    @Test func migrationPreservesV7AndBacksUpOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("focus.sqlite")
        do {
            let queue = try DatabaseQueue(path: file.path)
            try FocusStore.migrator(upTo: "v7").migrate(queue)
            try queue.write { db in
                try db.execute(sql: "INSERT INTO tasks (id,title,boardColumn,position,createdAt,updatedAt) VALUES ('old','Keep me','todo',1,?,?)", arguments: [Date(), Date()])
                try db.execute(sql: "INSERT INTO jira_task_links (taskId,cloudID,site,issueID,key,status,remoteUpdatedAt,refreshedAt) VALUES ('old','site','https://example.atlassian.net','10001','DEMO-1','Open',?,?)", arguments: [Date(), Date()])
                try SessionRecord(id: "codex:old", cwd: nil, projectName: nil, title: "Codex", firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: .now, lastActivityAt: .now, endedAt: nil, status: .live, taskId: "old", transcriptPath: nil, provider: .codex).insert(db)
            }
        }
        for _ in 0..<2 {
            let store = try FocusStore(fileURL: file)
            #expect(try BoardService(store: store).snapshot().task(id: "old")?.title == "Keep me")
            #expect(try SessionHistory(store: store).session(id: "codex:old")?.taskId == "old")
            #expect(try BoardService(store: store).snapshot().jiraLinks["old"]?.key == "DEMO-1")
        }
        let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("before-clickup") }
        #expect(backups.count == 1)
        let snapshot = try DatabaseQueue(path: #require(backups.first).path)
        #expect(try snapshot.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }.contains("v8") == false)
        #expect(try snapshot.read { try String.fetchOne($0, sql: "SELECT title FROM tasks") } == "Keep me")
    }

}
