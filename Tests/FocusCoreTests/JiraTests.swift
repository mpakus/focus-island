import Foundation
import GRDB
import OpenIslandCore
import Testing
@testable import FocusCore

func jiraFixture(id: String = "10001", key: String = "TEST-1", title: String = "A Jira issue", updated: String = "2026-10-23T10:00:00.000+0000", status: String = "Submitted") throws -> JiraIssue {
    let object: [String: Any] = ["id": id, "key": key, "fields": [
        "summary": title, "updated": updated, "status": ["name": status, "statusCategory": ["key": "new"]],
        "description": ["type": "doc", "content": [["type": "paragraph", "content": [["type": "text", "text": "Source description"]]]]]
    ]]
    return try JSONDecoder().decode(JiraIssue.self, from: JSONSerialization.data(withJSONObject: object))
}

let jiraTestConnection = JiraConnection(site: "https://example.atlassian.net", email: "person@example.com", cloudID: "00000000-0000-0000-0000-000000000001")

struct JiraTaskServiceTests {
    @Test func importIsIdempotentAndNeverStartsFocus() throws {
        let store = try FocusStore.inMemory()
        let service = JiraTaskService(store: store)
        let issue = try jiraFixture(status: "In Progress")
        let first = try service.importIssues([issue, issue], connection: jiraTestConnection)
        let second = try service.importIssues([issue], connection: jiraTestConnection)
        #expect(first == [second[0], second[0]])
        let board = try BoardService(store: store).snapshot()
        #expect(board.tasks.count == 1 && board.jiraLinks.count == 1)
        #expect(board.tasks.first?.boardColumn == .backlog)
        #expect(board.currentTask(liveSessions: []) == nil)
        #expect(board.tasks.first?.details == "Source description")
    }

    @Test func sameIssueIDOnDifferentSitesCreatesDifferentTasks() throws {
        let store = try FocusStore.inMemory()
        let service = JiraTaskService(store: store)
        let issue = try jiraFixture()
        let first = try service.importIssues([issue], connection: jiraTestConnection)
        var other = jiraTestConnection
        other.cloudID = "00000000-0000-0000-0000-000000000002"
        other.site = "https://other.atlassian.net"
        let second = try service.importIssues([issue], connection: other)
        #expect(first != second)
    }

    @Test func refreshAndStaleEditorPreserveLocalWork() throws {
        let store = try FocusStore.inMemory()
        let service = JiraTaskService(store: store)
        let board = BoardService(store: store)
        let id = try service.importIssues([jiraFixture()], connection: jiraTestConnection, column: .todo, projectPath: "/tmp/repo")[0]
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
        let link = try #require(board.snapshot().jiraLinks[id])
        try service.refresh(jiraFixture(key: "MOVED-9", title: "Fresh source title", updated: "2026-10-24T10:00:00.000+0000", status: "Done"), link: link)
        try board.updateTask(stale)
        let task = try #require(board.snapshot().task(id: id))
        #expect(task.title == "Fresh source title")
        #expect(task.note == "Local unsaved note" && task.projectPath == "/tmp/repo")
        #expect(task.boardColumn == .done && task.doneAt == Date(timeIntervalSince1970: 500))
        #expect(try board.snapshot().jiraLinks[id]?.key == "MOVED-9")
        #expect(try store.dbQueue.read { db in try tables.map { try Row.fetchAll(db, sql: "SELECT * FROM \($0)") } } == before)
    }

    @Test func detachedDeletedOrOlderResponsesCannotRestoreLinks() throws {
        for delete in [false, true] {
            let store = try FocusStore.inMemory()
            let service = JiraTaskService(store: store)
            let board = BoardService(store: store)
            let issue = try jiraFixture()
            let id = try service.importIssues([issue], connection: jiraTestConnection)[0]
            let link = try #require(board.snapshot().jiraLinks[id])
            try service.refresh(jiraFixture(title: "Old", updated: "2026-10-22T10:00:00.000Z"), link: link)
            #expect(try board.snapshot().task(id: id)?.title == issue.fields.summary)
            if delete { try board.deleteTask(id: id) } else { try service.detach(taskID: id) }
            try service.refresh(issue, link: link)
            try service.markUnavailable(link)
            #expect(try board.snapshot().jiraLinks.isEmpty)
            #expect(try board.snapshot().tasks.count == (delete ? 0 : 1))
        }
    }

    @Test func invalidBatchLeavesNoTasksAndUnavailableKeepsData() throws {
        let store = try FocusStore.inMemory()
        let service = JiraTaskService(store: store)
        #expect(throws: JiraError.invalidResponse) {
            try service.importIssues([jiraFixture(), jiraFixture(id: "bad")], connection: jiraTestConnection)
        }
        let board = BoardService(store: store)
        #expect(try board.snapshot().tasks.isEmpty)
        let id = try service.importIssues([jiraFixture()], connection: jiraTestConnection)[0]
        let before = try board.snapshot()
        try service.markUnavailable(#require(before.jiraLinks[id]))
        #expect(try board.snapshot().tasks == before.tasks)
        #expect(try board.snapshot().jiraLinks[id]?.unavailable == true)
    }

    @Test func migrationPreservesV6AndBacksUpOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("focus.sqlite")
        do {
            let queue = try DatabaseQueue(path: file.path)
            try FocusStore.migrator(upTo: "v6").migrate(queue)
            try queue.write { db in
                try db.execute(sql: "INSERT INTO tasks (id,title,boardColumn,position,createdAt,updatedAt) VALUES ('old','Keep me','todo',1,?,?)", arguments: [Date(), Date()])
                try SessionRecord(id: "codex:old", cwd: nil, projectName: nil, title: "Codex", firstPrompt: nil, lastPrompt: nil, lastAssistantMessage: nil, startedAt: .now, lastActivityAt: .now, endedAt: nil, status: .live, taskId: "old", transcriptPath: nil, provider: .codex).insert(db)
            }
        }
        for _ in 0..<2 {
            let store = try FocusStore(fileURL: file)
            #expect(try BoardService(store: store).snapshot().task(id: "old")?.title == "Keep me")
            #expect(try SessionHistory(store: store).session(id: "codex:old")?.taskId == "old")
        }
        let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("before-jira") }
        #expect(backups.count == 1)
        let snapshot = try DatabaseQueue(path: #require(backups.first).path)
        #expect(try snapshot.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }.contains("v7") == false)
        #expect(try snapshot.read { try String.fetchOne($0, sql: "SELECT title FROM tasks") } == "Keep me")
    }

    @Test func migrationErrorsDoNotRecreateTheDatabase() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("focus.sqlite")
        let queue = try DatabaseQueue(path: file.path)
        try FocusStore.migrator(upTo: "v6").migrate(queue)
        try queue.write { try $0.execute(sql: "CREATE TABLE jira_task_links (unexpected TEXT)") }
        let result = FocusStore.openWithRecovery(fileURL: file)
        #expect(result.outcome == .inMemoryFallback)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try queue.read { try $0.columns(in: "jira_task_links").map(\.name) } == ["unexpected"])
        #expect(!FocusStore.isCorruption(FocusStoreOpenError.migrationFailed(JiraError.invalidResponse)))
    }
}

struct JiraClientTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FOCUS_ISLAND_JIRA_LIVE_EXECUTABLE"] != nil))
    func liveAssignedIssueImportUsesDisposableStorage() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["FOCUS_ISLAND_JIRA_LIVE_EXECUTABLE"])
        let client = JiraCLIClient(run: { try await JiraCommand.run($0, executable: URL(fileURLWithPath: path)) })
        let connection = try await client.connect()
        let issues = try await client.search(connection: connection)
        let selected = try #require(issues.first)
        let issue = try await client.issue(id: selected.id, connection: connection)
        let store = try FocusStore.inMemory()
        let service = JiraTaskService(store: store)
        let board = BoardService(store: store)
        let id = try service.importIssues([issue], connection: connection)[0]
        var task = try #require(board.snapshot().task(id: id))
        task.note = "Disposable verification note"
        try board.updateTask(task)
        try board.moveTask(id: id, to: .done, beforeTaskID: nil)
        let again = try await client.issue(id: issue.id, connection: connection)
        try service.refresh(again, link: #require(board.snapshot().jiraLinks[id]))
        #expect(try board.snapshot().task(id: id)?.note == task.note)
        #expect(try board.snapshot().task(id: id)?.boardColumn == .done)
        #expect(again.fields.status == issue.fields.status)
    }

    @Test func authStatusValidatesSiteAndAccount() throws {
        let account = try JiraCLIClient.account(from: Data("✓ Authenticated\n  Site: example.atlassian.net\n  Email: Person@example.com\n".utf8))
        #expect(account.site == jiraTestConnection.site && account.email == jiraTestConnection.email)
        for site in ["http://example.atlassian.net", "https://example.atlassian.net.evil.com", "https://user@example.atlassian.net", "https://example.atlassian.net/path", "https://example.atlassian.net?token=x"] {
            #expect(throws: JiraError.invalidResponse) { try JiraConnection.canonicalSite(site) }
        }
        #expect(throws: JiraError.signInRequired) { try JiraCLIClient.account(from: Data("Unknown format".utf8)) }
    }

    @Test func searchRejectsIncompleteOrMalformedData() throws {
        #expect(try JiraCLIClient.decodeSearch(Data("[]".utf8)).isEmpty)
        let duplicated = try JSONEncoder().encode([jiraFixture(), jiraFixture()])
        #expect(try JiraCLIClient.decodeSearch(duplicated).count == 1)
        #expect(try JiraCLIClient.decodeSearch(Data(#"{"issues":[],"isLast":true}"#.utf8)).isEmpty)
        for value in ["{\"issues\":[]}", "{\"issues\":[],\"total\":100,\"maxResults\":50}", "{\"issues\":[],\"isLast\":false}", "{\"issues\":[],\"nextPageToken\":\"next\"}", "{\"issues\":[{}]}", "not json"] {
            #expect(throws: JiraError.invalidResponse) { try JiraCLIClient.decodeSearch(Data(value.utf8)) }
        }
    }

    @Test func issueReadIncludesDescriptionAndVerifiesIdentity() async throws {
        let client = JiraCLIClient(run: { arguments in
            if arguments == ["jira", "auth", "status"] { return Data("Site: example.atlassian.net\nEmail: person@example.com".utf8) }
            #expect(arguments == ["jira", "workitem", "view", "10001", "--fields", JiraCLIClient.fields + ",description", "--json"])
            return try JSONEncoder().encode(jiraFixture())
        })
        let issue = try await client.issue(id: "10001", connection: jiraTestConnection)
        #expect(issue.fields.description?.plainText == "Source description")
        let wrongID = JiraCLIClient(run: { arguments in
            if arguments == ["jira", "auth", "status"] { return Data("Site: example.atlassian.net\nEmail: person@example.com".utf8) }
            return try JSONEncoder().encode(jiraFixture(id: "20002"))
        })
        await #expect(throws: JiraError.invalidResponse) { try await wrongID.issue(id: "10001", connection: jiraTestConnection) }
    }

    @Test func onlyReadCommandsAndFullPaginationAreUsed() async throws {
        let client = JiraCLIClient(run: { arguments in
            if arguments == ["jira", "auth", "status"] { return Data("Site: example.atlassian.net\nEmail: person@example.com".utf8) }
            #expect(arguments == ["jira", "workitem", "search", "--jql", JiraCLIClient.jql, "--fields", JiraCLIClient.fields, "--paginate", "--json"])
            return Data("[]".utf8)
        }, cloudID: { _ in jiraTestConnection.cloudID })
        #expect(try await client.connect() == jiraTestConnection)
        #expect(try await client.search(connection: jiraTestConnection).isEmpty)
        var other = jiraTestConnection
        other.email = "other@example.com"
        await #expect(throws: JiraError.accountChanged) { try await client.search(connection: other) }
        await #expect(throws: JiraError.invalidResponse) { try await client.issue(id: "--web", connection: jiraTestConnection) }
    }

    @Test func adfRetainsReadableTextWithoutExecutingMarkup() throws {
        let data = Data(#"{"type":"doc","content":[{"type":"heading","content":[{"type":"text","text":"Heading"}]},{"type":"unknown","content":[{"type":"text","text":"<script>text only</script>"}]},{"type":"hardBreak"},{"type":"paragraph","content":[{"type":"text","text":"Привет 👋"}]}]}"#.utf8)
        let document = try JSONDecoder().decode(JiraDocument.self, from: data)
        #expect(document.plainText == "Heading\n<script>text only</script>\nПривет 👋")
    }

    @Test func processTimeoutCancellationAndFailureAreBounded() async throws {
        let shell = URL(fileURLWithPath: "/bin/sh")
        await #expect(throws: JiraError.timedOut) {
            try await JiraCommand.run(["-c", "exec sleep 5"], executable: shell, timeout: 0.05)
        }
        let task = Task { try await JiraCommand.run(["-c", "exec sleep 5"], executable: shell) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await #expect(throws: JiraError.signInRequired) {
            try await JiraCommand.run(["-c", "echo unauthorized >&2; exit 1"], executable: shell)
        }
        let output = try await JiraCommand.run(["-c", "printf '[]'"], executable: shell)
        #expect(output == Data("[]".utf8))
    }
}
