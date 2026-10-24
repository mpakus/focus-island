import Foundation
import Testing
@testable import FocusCore
@testable import OpenIslandApp

actor StubClickUpClient: ClickUpProviding {
    let connection = ClickUpConnection(workspaceID: "100", workspaceName: "Focus Island", userID: "7", username: "Demo account")
    var assigned = ["abc"]
    var fail = false
    var holding = false
    var waiting = false
    var pending: CheckedContinuation<Void, Never>?
    func configure(assigned: [String]? = nil, fail: Bool = false, holding: Bool = false) {
        if let assigned { self.assigned = assigned }; self.fail = fail; self.holding = holding
    }
    func release() { holding = false; pending?.resume(); pending = nil }
    static func fixture(_ id: String = "abc") -> ClickUpTask {
        ClickUpTask(id: id, workspaceID: "100", title: "Review onboarding flow", details: "Make the first session easy to follow.", customID: "CU-42", listID: "20", listName: "Product", parentID: nil, status: "In progress", statusType: "custom", assigneeIDs: ["7"], updatedAt: Date(timeIntervalSince1970: 1_792_800_000), archived: false)
    }
    func authorize() -> ClickUpConnection { connection }
    func connect() -> ClickUpConnection { connection }
    func search(connection: ClickUpConnection) async throws -> [ClickUpTask] {
        if fail { throw ClickUpError.invalidResponse }
        waiting = true
        if holding { await withCheckedContinuation { pending = $0 } }
        return assigned.map(Self.fixture)
    }
    func tasks(ids: [String], connection: ClickUpConnection) -> [ClickUpTaskResult] { ids.map { .task(Self.fixture($0)) } }
    nonisolated func disconnect() { }
}

@MainActor
struct ClickUpCoordinatorTests {
    @Test func manualSyncPreservesLocalProgressAndForgetKeepsCards() async throws {
        let store = try FocusStore.inMemory(), client = StubClickUpClient()
        let preferences = UserDefaults(suiteName: "ClickUp.\(UUID())")!
        let coordinator = ClickUpCoordinator(store: store, defaults: preferences, durable: true, client: client)
        coordinator.connect(authorize: true); await coordinator.operation?.value
        let board = BoardService(store: store)
        #expect(coordinator.connection != nil && coordinator.error == nil)
        #expect(try board.snapshot().tasks.isEmpty)
        coordinator.syncAssignedTasks(links: []); await coordinator.operation?.value
        var task = try #require(board.snapshot().tasks.first)
        task.note = "Local note"; try board.updateTask(task)
        try board.moveTask(id: task.id, to: .done, beforeTaskID: nil)
        await client.configure(assigned: ["def"])
        for _ in 0..<2 {
            coordinator.syncAssignedTasks(links: Array(try board.snapshot().clickUpLinks.values)); await coordinator.operation?.value
        }
        let result = try board.snapshot()
        #expect(result.tasks.count == 2 && result.clickUpLinks.count == 2)
        #expect(result.task(id: task.id)?.boardColumn == .done && result.task(id: task.id)?.note == "Local note")
        #expect(coordinator.lastRefresh != nil && coordinator.error == nil)
        coordinator.reconnect(); await coordinator.operation?.value
        #expect(coordinator.connection != nil)
        coordinator.disconnect()
        #expect(coordinator.connection == nil && preferences.data(forKey: ClickUpCoordinator.connectionKey) == nil)
        #expect(try board.snapshot().tasks == result.tasks)
    }

    @Test func failedDiscoveryAndFallbackStorageDoNotImport() async throws {
        let store = try FocusStore.inMemory(), client = StubClickUpClient()
        for durable in [true, false] {
            let coordinator = ClickUpCoordinator(store: store, defaults: UserDefaults(suiteName: UUID().uuidString)!, durable: durable, client: client)
            coordinator.connect(); await coordinator.operation?.value
            if durable {
                await client.configure(fail: true)
                coordinator.syncAssignedTasks(links: []); await coordinator.operation?.value
            }
            #expect(coordinator.error != nil)
            #expect(try BoardService(store: store).snapshot().tasks.isEmpty)
        }
    }

    @Test func forgetDuringReadDiscardsLateResults() async throws {
        let store = try FocusStore.inMemory(), client = StubClickUpClient()
        let coordinator = ClickUpCoordinator(store: store, defaults: UserDefaults(suiteName: UUID().uuidString)!, durable: true, client: client)
        coordinator.connect(); await coordinator.operation?.value
        await client.configure(holding: true)
        coordinator.syncAssignedTasks(links: [])
        let operation = coordinator.operation
        for _ in 0..<100 { if await client.waiting { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(await client.waiting)
        coordinator.disconnect(); await client.release(); await operation?.value
        #expect(coordinator.connection == nil && coordinator.error == nil && !coordinator.isBusy)
        #expect(try BoardService(store: store).snapshot().tasks.isEmpty)
    }
}
