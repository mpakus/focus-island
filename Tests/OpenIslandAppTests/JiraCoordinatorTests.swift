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

    func setFailure() { failSearch = true }
    func hold() { holdIssue = true }
    func release() { pending?.resume(); pending = nil }

    static func fixture(title: String = "Assigned Jira issue") throws -> JiraIssue {
        let object: [String: Any] = ["id": "10001", "key": "TEST-1", "fields": ["summary": title, "updated": "2026-10-23T10:00:00.000Z", "status": ["name": "In Progress"], "description": ["type": "doc", "content": [["type": "paragraph", "content": [["type": "text", "text": "Source description"]]]]]]]
        return try JSONDecoder().decode(JiraIssue.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func connect() async throws -> JiraConnection { requests.append("connect"); return connection }
    func search(connection: JiraConnection) async throws -> [JiraIssue] {
        requests.append("search")
        if failSearch { throw JiraError.commandFailed }
        return [try Self.fixture()]
    }
    func issue(id: String, connection: JiraConnection) async throws -> JiraIssue {
        requests.append("read")
        issueStarted = true
        if holdIssue { await withCheckedContinuation { pending = $0 } }
        return try Self.fixture(title: "Refreshed issue")
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

    @Test func disconnectDuringImportDiscardsLateResult() async throws {
        let store = try FocusStore.inMemory()
        let client = StubJiraClient()
        let coordinator = JiraCoordinator(store: store, defaults: defaults(), durable: true, client: client)
        coordinator.connect()
        await coordinator.operation?.value
        await client.hold()
        coordinator.importIssues(ids: ["10001"], column: .todo, projectPath: nil)
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
}
