import Foundation
import Testing
@testable import FocusCore

/// Private recorded live responses stay outside the repository; the ordinary suite uses synthetic fixtures.
struct ClickUpRecordedLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FOCUS_ISLAND_CLICKUP_RECORDINGS"] != nil))
    func productionDecoderImportsRecordedAssignmentsIntoDisposableBoard() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["FOCUS_ISLAND_CLICKUP_RECORDINGS"]))
        let wire = try ClickUpRecordedTransport(directory)
        let client = ClickUpMCPClient(credentials: try ClickUpMemoryCredentials(), send: { try await wire.send($0) }, browser: { _ in throw CancellationError() })
        let connection = try await client.connect()
        let tasks = try await client.search(connection: connection)
        #expect(!tasks.isEmpty)
        let store = try FocusStore.inMemory(), service = ClickUpTaskService(store: store), board = BoardService(store: store)
        let ids = try service.importTasks(tasks, connection: connection)
        var task = try #require(board.snapshot().task(id: ids[0]))
        task.note = "Disposable verification"; try board.updateTask(task)
        try board.moveTask(id: task.id, to: .done, beforeTaskID: nil)
        for _ in 0..<2 {
            let again = try await client.search(connection: connection)
            #expect(try service.importTasks(again, connection: connection) == ids)
            for remote in again {
                let link = try #require(board.snapshot().clickUpLinks.values.first { $0.remoteTaskID == remote.id })
                try service.refresh(remote, link: link)
            }
        }
        #expect(try board.snapshot().tasks.count == tasks.count)
        #expect(try board.snapshot().task(id: task.id)?.boardColumn == .done && board.snapshot().task(id: task.id)?.note == task.note)
        try service.detach(taskID: task.id)
        try client.disconnect()
        #expect(try board.snapshot().tasks.count == tasks.count)
    }
}

private actor ClickUpRecordedTransport {
    let directory: URL
    let rows: [String: [String: Any]]
    let lists: [String: [String: Any]]
    init(_ directory: URL) throws {
        self.directory = directory
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var rows: [String: [String: Any]] = [:], lists: [String: [String: Any]] = [:]
        for file in files {
            if file.lastPathComponent.hasPrefix("verified_batch_") {
                let result = try Self.payload(file)
                for row in try #require(result["tasks"] as? [[String: Any]]) { rows[try #require(row["object_id"] as? String)] = row }
            } else if file.lastPathComponent.hasPrefix("verified_list_") {
                let list = try Self.payload(file); lists[try #require(list["id"] as? String)] = list
            }
        }
        self.rows = rows; self.lists = lists
    }
    static func payload(_ file: URL) throws -> [String: Any] {
        let result = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        if let structured = result["structuredContent"] as? [String: Any] { return structured }
        let text = try #require((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    func send(_ request: URLRequest) throws -> IntegrationHTTPResponse {
        let object = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        if object["method"] as? String == "notifications/initialized" { return IntegrationHTTPResponse(data: Data(), status: 202) }
        let result: [String: Any]
        if object["method"] as? String == "initialize" { result = ["protocolVersion": "2025-03-26"] }
        else {
            let params = try #require(object["params"] as? [String: Any]), args = try #require(params["arguments"] as? [String: Any])
            let payload: [String: Any]
            switch params["name"] as? String {
            case "clickup_get_user": payload = try Self.payload(directory.appendingPathComponent("user.json"))
            case "clickup_get_workspace_hierarchy": payload = try Self.payload(directory.appendingPathComponent("hierarchy.json"))
            case "clickup_filter_tasks": payload = try Self.payload(directory.appendingPathComponent("page.json"))
            case "clickup_execute_operator":
                let ids = try #require((args["body"] as? [String: Any])?["ids"] as? [String])
                payload = ["tasks": try ids.map { try #require(rows[$0]) }]
            case "clickup_get_list":
                let id = try #require(args["list_id"] as? String)
                payload = try #require(lists[id])
            default: throw ClickUpError.invalidResponse
            }
            result = ["structuredContent": payload]
        }
        return IntegrationHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": object["id"]!, "result": result]))
    }
}
