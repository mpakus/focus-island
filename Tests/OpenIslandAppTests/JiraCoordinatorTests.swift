import FocusCore
import Foundation
import Testing
@testable import OpenIslandApp

actor StubJiraClient: JiraProviding {
    let connection = JiraConnection(site: "https://example.atlassian.net", email: "person@example.com", cloudID: "00000000-0000-0000-0000-000000000001")
    var failSearch = false
    var holdIssue = false
    var issueStarted = false
    var pending: CheckedContinuation<Void, Never>?
    var requests: [String] = []
    var assignedIDs = ["10001"]
    var failingIssueID: String?

    func setFailure() { failSearch = true }
    func hold() { holdIssue = true }
    func release() { holdIssue = false; pending?.resume(); pending = nil }
    func assign(_ ids: [String]) { assignedIDs = ids }
    func failIssue(_ id: String) { failingIssueID = id }

    static func fixture(id: String = "10001", title: String = "Assigned Jira issue") throws -> JiraIssue {
        let object: [String: Any] = ["id": id, "key": id == "10001" ? "TEST-1" : "TEST-\(id)", "fields": ["summary": title, "updated": "2026-10-23T10:00:00.000Z", "status": ["name": "In Progress"], "description": ["type": "doc", "content": [["type": "paragraph", "content": [["type": "text", "text": "Source description"]]]]]]]
        return try JSONDecoder().decode(JiraIssue.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func connect() async throws -> JiraConnection { requests.append("connect"); return connection }
    func search(connection: JiraConnection) async throws -> [JiraIssue] {
        requests.append("search")
        if failSearch { throw JiraError.commandFailed }
        return try assignedIDs.map { try Self.fixture(id: $0) }
    }
    func issue(id: String, connection: JiraConnection) async throws -> JiraIssue {
        requests.append("read")
        if id == failingIssueID { throw JiraError.commandFailed }
        issueStarted = true
        if holdIssue { await withCheckedContinuation { pending = $0 } }
        return try Self.fixture(id: id, title: "Refreshed issue")
    }
}

@MainActor
struct JiraCoordinatorTests {
    func defaults() -> UserDefaults { UserDefaults(suiteName: "JiraTests.\(UUID().uuidString)")! }

    @Test func connectImportAndRestartPreserveSourceAndLocalState() async throws {
        let store = try FocusStore.inMemory()
        let preferences = defaults()
        let client = StubJiraClient()
        let coordinator = JiraCoordinator(store: store, defaults: preferences, durable: true, client: client)
        coordinator.connect()
        await coordinator.operation?.value
        #expect(coordinator.connection != nil && coordinator.issues.count == 1 && coordinator.error == nil)
        coordinator.importIssues(ids: ["10001"], column: .backlog, projectPath: "/tmp/repo")
        await coordinator.operation?.value
        let board = BoardService(store: store)
        let task = try #require(board.snapshot().tasks.first)
        #expect(task.boardColumn == .backlog && task.projectPath == "/tmp/repo")
        #expect(task.title == "Refreshed issue")
        try board.moveTask(id: task.id, to: .done, beforeTaskID: nil)
        let reloaded = JiraCoordinator(store: store, defaults: preferences, durable: true, client: client)
        #expect(reloaded.connection == coordinator.connection)
        reloaded.refresh(links: Array(try board.snapshot().jiraLinks.values))
        await reloaded.operation?.value
        #expect(try board.snapshot().task(id: task.id)?.boardColumn == .done)
        reloaded.disconnect()
        #expect(preferences.data(forKey: JiraCoordinator.connectionKey) == nil)
        #expect(try board.snapshot().tasks.count == 1 && board.snapshot().jiraLinks.count == 1)
        #expect(await client.requests == ["connect", "search", "read", "read"])
    }

    @Test(arguments: [false, true]) func disconnectDuringImportDiscardsLateResult(sync: Bool) async throws {
        let store = try FocusStore.inMemory()
        let client = StubJiraClient()
        let coordinator = JiraCoordinator(store: store, defaults: defaults(), durable: true, client: client)
        coordinator.connect()
        await coordinator.operation?.value
        await client.hold()
        if sync { coordinator.syncAssignedIssues(links: []) }
        else { coordinator.importIssues(ids: ["10001"], column: .todo, projectPath: nil) }
        let operation = coordinator.operation
        for _ in 0..<100 {
            if await client.issueStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await client.issueStarted)
        coordinator.disconnect()
        await client.release()
        await operation?.value
        #expect(coordinator.connection == nil && !coordinator.isBusy && coordinator.error == nil)
        #expect(try BoardService(store: store).snapshot().tasks.isEmpty)
    }

    @Test func failedDiscoveryKeepsPriorListAndDoesNotTouchBoard() async throws {
        let store = try FocusStore.inMemory()
        let client = StubJiraClient()
        let coordinator = JiraCoordinator(store: store, defaults: defaults(), durable: true, client: client)
        coordinator.connect()
        await coordinator.operation?.value
        let prior = coordinator.issues
        await client.setFailure()
        coordinator.loadIssues()
        await coordinator.operation?.value
        #expect(coordinator.issues == prior && coordinator.error != nil && !coordinator.isBusy)
        #expect(try BoardService(store: store).snapshot().tasks.isEmpty)
    }

    @Test func fallbackStorageNeverClaimsSuccessfulImport() async throws {
        let client = StubJiraClient()
        let coordinator = JiraCoordinator(store: try FocusStore.inMemory(), defaults: defaults(), durable: false, client: client)
        coordinator.connect()
        #expect(coordinator.error != nil && !coordinator.isBusy && coordinator.connection == nil)
        #expect(await client.requests.isEmpty)
    }

    @Test func staleSelectionRejectsTheEntireImport() async throws {
        let store = try FocusStore.inMemory()
        let client = StubJiraClient()
        let coordinator = JiraCoordinator(store: store, defaults: defaults(), durable: true, client: client)
        coordinator.connect()
        await coordinator.operation?.value
        coordinator.importIssues(ids: ["10001", "disappeared"], column: .todo, projectPath: nil)
        #expect(coordinator.error != nil && !coordinator.isBusy)
        #expect(try BoardService(store: store).snapshot().tasks.isEmpty)
        #expect(await client.requests == ["connect", "search"])
    }

    @Test func browserAuthorizationConnectsWithoutASeparateConnectAction() async throws {
        let client = StubJiraClient()
        let coordinator = JiraCoordinator(store: try FocusStore.inMemory(), defaults: defaults(), durable: true, client: client)
        coordinator.authorize()
        await coordinator.operation?.value
        #expect(coordinator.connection != nil && coordinator.issues.count == 1 && coordinator.error == nil)
        #expect(await client.requests == ["connect", "search"])
    }

    @Test func syncImportsAssignmentsAndRefreshesMissingLinkedIssuesWithoutDuplicates() async throws {
        let store = try FocusStore.inMemory()
        let client = StubJiraClient()
        let coordinator = JiraCoordinator(store: store, defaults: defaults(), durable: true, client: client)
        coordinator.connect()
        await coordinator.operation?.value
        coordinator.syncAssignedIssues(links: [])
        await coordinator.operation?.value
        let board = BoardService(store: store)
        var task = try #require(board.snapshot().tasks.first)
        #expect(task.boardColumn == .backlog)
        task.note = "Keep local work"
        try board.updateTask(task)
        try board.moveTask(id: task.id, to: .done, beforeTaskID: nil)
        await client.assign(["10002"])
        for _ in 0..<2 {
            coordinator.syncAssignedIssues(links: Array(try board.snapshot().jiraLinks.values))
            await coordinator.operation?.value
        }
        let result = try board.snapshot()
        #expect(result.tasks.count == 2 && result.jiraLinks.count == 2)
        #expect(result.task(id: task.id)?.note == task.note && result.task(id: task.id)?.boardColumn == .done)
        #expect(result.tasks.first { $0.id != task.id }?.boardColumn == .backlog)
        #expect(coordinator.issues.map(\.id) == ["10002"] && coordinator.lastRefresh != nil && coordinator.error == nil)
    }

    @Test func syncDetailFailureLeavesTheWholeNewBatchUnimported() async throws {
        let store = try FocusStore.inMemory()
        let client = StubJiraClient()
        let coordinator = JiraCoordinator(store: store, defaults: defaults(), durable: true, client: client)
        coordinator.connect()
        await coordinator.operation?.value
        await client.assign(["10001", "10002"])
        await client.failIssue("10002")
        coordinator.syncAssignedIssues(links: [])
        await coordinator.operation?.value
        #expect(try BoardService(store: store).snapshot().tasks.isEmpty)
        #expect(coordinator.error != nil && coordinator.lastRefresh == nil)
    }

    @Test(arguments: [false, true]) func syncCannotRestoreADetachedOrDeletedLink(delete: Bool) async throws {
        let store = try FocusStore.inMemory()
        let client = StubJiraClient()
        let coordinator = JiraCoordinator(store: store, defaults: defaults(), durable: true, client: client)
        coordinator.connect()
        await coordinator.operation?.value
        let id = try JiraTaskService(store: store).importIssues([StubJiraClient.fixture()], connection: #require(coordinator.connection))[0]
        let board = BoardService(store: store)
        await client.hold()
        coordinator.syncAssignedIssues(links: Array(try board.snapshot().jiraLinks.values))
        for _ in 0..<100 {
            if await client.issueStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await client.issueStarted)
        if delete { try board.deleteTask(id: id) } else { coordinator.detach(taskID: id) }
        await client.release()
        await coordinator.operation?.value
        #expect(try board.snapshot().jiraLinks.isEmpty)
        #expect(try board.snapshot().tasks.count == (delete ? 0 : 1))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FOCUS_ISLAND_JIRA_LIVE_EXECUTABLE"] != nil))
    func liveSyncUsesADisposableBoard() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["FOCUS_ISLAND_JIRA_LIVE_EXECUTABLE"])
        let client = JiraCLIClient(run: { try await JiraCommand.run($0, executable: URL(fileURLWithPath: path)) })
        let store = try FocusStore.inMemory()
        let coordinator = JiraCoordinator(store: store, defaults: defaults(), durable: true, client: client)
        coordinator.connect()
        await coordinator.operation?.value
        #expect(coordinator.error == nil)
        coordinator.syncAssignedIssues(links: [])
        await coordinator.operation?.value
        #expect(coordinator.error == nil)
        let board = BoardService(store: store)
        var task = try #require(board.snapshot().tasks.first)
        let count = try board.snapshot().tasks.count
        #expect(count == coordinator.issues.count)
        task.note = "Disposable sync verification"
        try board.updateTask(task)
        try board.moveTask(id: task.id, to: .done, beforeTaskID: nil)
        coordinator.syncAssignedIssues(links: Array(try board.snapshot().jiraLinks.values))
        await coordinator.operation?.value
        #expect(coordinator.error == nil && coordinator.lastRefresh != nil)
        #expect(try board.snapshot().tasks.count == count)
        #expect(try board.snapshot().task(id: task.id)?.note == task.note)
        #expect(try board.snapshot().task(id: task.id)?.boardColumn == .done)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FOCUS_ISLAND_JIRA_BROWSER_KEYCHAIN"] != nil))
    func liveBrowserConnectionSyncsADisposableBoard() async throws {
        let service = try #require(ProcessInfo.processInfo.environment["FOCUS_ISLAND_JIRA_BROWSER_KEYCHAIN"])
        let client = JiraMCPClient(credentials: JiraKeychain(service: service), browser: { _ in throw JiraError.signInRequired }, chooseSite: { $0[0] })
        let store = try FocusStore.inMemory()
        let coordinator = JiraCoordinator(store: store, defaults: defaults(), durable: true, client: client)
        coordinator.connect()
        await coordinator.operation?.value
        try #require(coordinator.connection != nil, "Browser connection: \(coordinator.error ?? "cancelled")")
        coordinator.syncAssignedIssues(links: [])
        await coordinator.operation?.value
        #expect(coordinator.error == nil)
        let board = BoardService(store: store)
        let before = try board.snapshot()
        #expect(before.tasks.count == coordinator.issues.count)
        coordinator.syncAssignedIssues(links: Array(before.jiraLinks.values))
        await coordinator.operation?.value
        #expect(coordinator.error == nil)
        #expect(try board.snapshot().tasks.map(\.id).sorted() == before.tasks.map(\.id).sorted())
    }
}
