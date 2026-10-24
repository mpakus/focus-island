import Foundation
import Testing
@testable import FocusCore

let clickUpTestConnection = ClickUpConnection(workspaceID: "100", workspaceName: "Example team", userID: "7", username: "Example")

final class ClickUpMemoryCredentials: IntegrationCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    init(expired: Bool = false) throws {
        data = try JSONEncoder().encode(ClickUpCredentials(clientID: "fixture", accessToken: "fixture", expiresAt: Date().addingTimeInterval(expired ? -1 : 3600), connection: clickUpTestConnection))
    }
    func load() -> Data? { lock.withLock { data } }
    func save(_ data: Data) { lock.withLock { self.data = data } }
    func remove() { lock.withLock { data = nil } }
}

actor ClickUpWireFixture {
    let mode: String
    var filterPages: [Int] = []
    var bulkSizes: [Int] = []
    var listCalls = 0
    var initialized = 0
    var expiredSession = false
    init(_ mode: String = "ok") { self.mode = mode }
    func send(_ request: URLRequest) throws -> IntegrationHTTPResponse {
        #expect(request.url == ClickUpOAuth.endpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        let object = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let method = object["method"] as? String
        if method == "notifications/initialized" { return IntegrationHTTPResponse(data: Data(), status: 202) }
        var result: [String: Any]
        if method == "initialize" { initialized += 1; result = ["protocolVersion": "2025-03-26"] }
        else {
            #expect(method == "tools/call")
            if mode == "expiredSession", !expiredSession { expiredSession = true; return IntegrationHTTPResponse(data: Data(), status: 404) }
            if mode == "rateLimit" { return IntegrationHTTPResponse(data: Data(), status: 429) }
            if mode == "unauthorized" { return IntegrationHTTPResponse(data: Data(), status: 401) }
            let params = try #require(object["params"] as? [String: Any])
            let args = try #require(params["arguments"] as? [String: Any])
            let payload: [String: Any]
            switch params["name"] as? String {
            case "clickup_get_workspace_hierarchy": payload = ["hierarchy": ["root": ["id": "100", "name": "Example team"]]]
            case "clickup_get_user": payload = ["id": 7, "username": "Example"]
            case "clickup_filter_tasks":
                let page = try #require(args["page"] as? Int); filterPages.append(page)
                #expect(args["assignees"] as? [String] == ["7"] && args["subtasks"] as? Bool == true && args["include_closed"] as? Bool == false)
                let ids = page == 0 || mode == "repeat" ? ["a", "b"] : ["b", "c", "d"]
                payload = ["tasks": ids.map { ["id": $0, "assignees": [["id": 7]]] }, "count": ids.count, "page": page,
                    "has_more": mode == "repeat" || page == 0, "next_page": page + 1, "warnings": mode == "warnings" ? ["partial"] : []]
            case "clickup_execute_operator":
                #expect(args["model"] as? String == "task" && args["operator"] as? String == "get_many" && args["operation_id"] as? String == "getBulkTasks")
                let ids = try #require((args["body"] as? [String: Any])?["ids"] as? [String]); bulkSizes.append(ids.count)
                if mode == "truncate" && ids.count > 1 { payload = ["truncated": true, "preview": "never import"] }
                else {
                    let rows = ids.map { id -> [String: Any] in
                        if mode == "missing" { return ["object_id": id, "status": "not_found_or_authorized"] }
                        return ["object_id": id, "status": "found", "data": ["id": id, "name": "Task \(id)", "workspace_id": mode == "wrongScope" ? "999" : "100", "subcategory": "20",
                            "status": ["id": id == "c" ? "done" : id == "d" ? "closed" : "open"], "users": [7, -42], "direct_parent": id == "b" ? "a" : NSNull(),
                            "time_mgmt": ["date_updated": "1792800000000"], "text_content": "Description", "states": ["is_deleted": false, "is_archived": false]]]
                    }
                    payload = ["tasks": mode == "partial" ? Array(rows.dropLast()) : rows]
                }
            case "clickup_get_list":
                listCalls += 1
                payload = ["id": "20", "name": "Example list", "statuses": ["open", "done", "closed"].map { ["id": $0, "status": "Custom \($0)", "type": $0] }]
            default: throw ClickUpError.invalidResponse
            }
            result = params["name"] as? String == "clickup_execute_operator"
                ? ["content": [["type": "text", "text": String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)]]]
                : ["structuredContent": payload]
        }
        let bytes = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": object["id"]!, "result": result])
        let data = Data("event: message\ndata: \(String(decoding: bytes, as: UTF8.self))\n\n".utf8)
        return IntegrationHTTPResponse(data: data, sessionID: "fixture-session")
    }
}

struct ClickUpClientTests {
    func client(_ mode: String = "ok") throws -> (ClickUpMCPClient, ClickUpWireFixture) {
        let wire = ClickUpWireFixture(mode)
        return (ClickUpMCPClient(credentials: try ClickUpMemoryCredentials(), send: { try await wire.send($0) }, browser: { _ in throw CancellationError() }), wire)
    }
    @Test func completePaginationDeduplicatesAndUsesStatusTypesForSubtasks() async throws {
        let (client, wire) = try client()
        #expect(try await client.connect() == clickUpTestConnection)
        let tasks = try await client.search(connection: clickUpTestConnection)
        #expect(tasks.map(\.id) == ["a", "b"])
        #expect(tasks[1].parentID == "a" && tasks[0].details == "Description")
        #expect(await wire.filterPages == [0, 1])
        #expect(await wire.bulkSizes == [4])
        #expect(await wire.listCalls == 1)
    }
    @Test(arguments: ["truncate", "expiredSession"])
    func retriesOnlyCompleteReadOperations(mode: String) async throws {
        let (client, wire) = try client(mode)
        #expect(try await client.search(connection: clickUpTestConnection).count == 2)
        if mode == "truncate" { #expect(await wire.bulkSizes == [4, 2, 1, 1, 2, 1, 1]) }
        else { #expect(await wire.initialized == 2) }
    }
    @Test(arguments: ["partial", "wrongScope", "repeat", "warnings", "missing", "rateLimit", "unauthorized"])
    func incompleteOrUnauthorizedReadsFailBeforeReturningTasks(mode: String) async throws {
        let (client, _) = try client(mode)
        let expected: ClickUpError = switch mode {
        case "missing": .unavailable
        case "rateLimit": .rateLimited
        case "unauthorized": .signInRequired
        default: .invalidResponse
        }
        await #expect(throws: expected) { try await client.search(connection: clickUpTestConnection) }
    }
    @Test func rateLimitsRetainSafeRetryTimes() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(ClickUpMCPClient.rateLimit("60", now: now) == .rateLimitedUntil(now.addingTimeInterval(60)))
        #expect(ClickUpMCPClient.rateLimit("untrusted text", now: now) == .rateLimited)
        #expect(ClickUpMCPClient.rateLimit(-1, now: now) == .rateLimited)
    }
    @Test func expiryAndForgetPreventFurtherReads() async throws {
        let wire = ClickUpWireFixture()
        let expired = ClickUpMCPClient(credentials: try ClickUpMemoryCredentials(expired: true), send: { try await wire.send($0) }, browser: { _ in throw CancellationError() })
        await #expect(throws: ClickUpError.signInRequired) { try await expired.connect() }
        let (client, _) = try client()
        try client.disconnect()
        await #expect(throws: ClickUpError.signInRequired) { try await client.search(connection: clickUpTestConnection) }
    }
}

private actor ClickUpReadGate {
    var waiting = false
    var pending: CheckedContinuation<Void, Never>?
    func pause() async { waiting = true; await withCheckedContinuation { pending = $0 } }
    func release() { pending?.resume(); pending = nil }
}

extension ClickUpClientTests {
    @Test func forgetInvalidatesAnInFlightCredentialRead() async throws {
        let gate = ClickUpReadGate(), wire = ClickUpWireFixture(), credentials = try ClickUpMemoryCredentials()
        let client = ClickUpMCPClient(credentials: credentials, send: { request in
            await gate.pause()
            return try await wire.send(request)
        }, browser: { _ in throw CancellationError() })
        let operation = Task { try await client.connect() }
        for _ in 0..<100 { if await gate.waiting { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(await gate.waiting)
        try client.disconnect()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(credentials.load() == nil)
    }
}
