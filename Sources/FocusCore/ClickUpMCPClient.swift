import Foundation

public actor ClickUpMCPClient: ClickUpProviding {
    private let credentials: Credentials
    private let send: IntegrationHTTP.Send
    private let browser: @Sendable (URL) async throws -> Void
    private var sessionID: String?
    private var initialized = false
    private var activeToken: String?
    private var protocolVersion = "2025-03-26"

    public init(credentials: any IntegrationCredentialStoring = IntegrationKeychain(service: "dev.zhanabayev.focusisland.clickup"),
                send: @escaping IntegrationHTTP.Send = IntegrationHTTP.send,
                browser: @escaping @Sendable (URL) async throws -> Void) {
        self.credentials = Credentials(store: credentials); self.send = send; self.browser = browser
    }

    public func authorize() async throws -> ClickUpConnection {
        let revision = credentials.revision
        let token = try await ClickUpOAuth.authorize(send: send, browser: browser)
        try credentials.save(token, revision: revision)
        return try await connect()
    }

    public nonisolated func disconnect() throws { try credentials.remove() }

    public func connect() async throws -> ClickUpConnection {
        let revision = credentials.revision
        let hierarchy = try await call(.hierarchy, ["max_depth": "0", "limit": 1])
        guard let root = (hierarchy["hierarchy"] as? [String: Any])?["root"] as? [String: Any],
              let workspaceID = root["id"] as? String, let name = root["name"] as? String else { throw ClickUpError.invalidResponse }
        let user = try await call(.user, ["workspace_id": workspaceID])
        guard let userID = Self.numericID(user["id"]), let username = user["username"] as? String else { throw ClickUpError.invalidResponse }
        let connection = ClickUpConnection(workspaceID: workspaceID, workspaceName: name, userID: userID, username: username)
        try connection.validate()
        var tokens = try credentials.load()
        tokens.connection = connection
        try credentials.save(tokens, revision: revision)
        return connection
    }

    public func search(connection: ClickUpConnection) async throws -> [ClickUpTask] {
        try verify(connection)
        var ids: [String] = [], seen = Set<String>(), page = 0
        while true {
            let result = try await call(.filter, ["workspace_id": connection.workspaceID, "assignees": [connection.userID],
                "subtasks": true, "include_closed": false, "order_by": "id", "page": page, "fields": ["assignees"]])
            guard let tasks = result["tasks"] as? [[String: Any]], let more = result["has_more"] as? Bool,
                  result["page"] as? Int == page, result["count"] as? Int == tasks.count,
                  (result["warnings"] == nil || result["warnings"] is NSNull || (result["warnings"] as? [Any])?.isEmpty == true) else { throw ClickUpError.invalidResponse }
            let priorCount = ids.count
            for task in tasks {
                guard let id = task["id"] as? String, ClickUpTask.validID(id),
                      let assignees = task["assignees"] as? [[String: Any]],
                      assignees.contains(where: { Self.numericID($0["id"]) == connection.userID }) else { throw ClickUpError.invalidResponse }
                if seen.insert(id).inserted { ids.append(id) }
            }
            if !more { break }
            guard let next = result["next_page"] as? Int, next == page + 1, next <= 1_000, ids.count > priorCount else { throw ClickUpError.invalidResponse }
            page = next
        }
        var result: [ClickUpTask] = []
        for item in try await tasks(ids: ids, connection: connection) {
            guard case let .task(task) = item else { throw ClickUpError.unavailable }
            if task.unfinished && task.assigneeIDs.contains(connection.userID) { result.append(task) }
        }
        return result
    }

    public func tasks(ids: [String], connection: ClickUpConnection) async throws -> [ClickUpTaskResult] {
        try verify(connection)
        guard ids.allSatisfy(ClickUpTask.validID), Set(ids).count == ids.count else { throw ClickUpError.invalidResponse }
        var result: [ClickUpTaskResult] = [], lists: [String: [String: Any]] = [:]
        for start in stride(from: 0, to: ids.count, by: 10) {
            let batch = Array(ids[start..<min(start + 10, ids.count)])
            let rows = try await readBatch(batch, connection: connection)
            for row in rows {
                guard let id = row["object_id"] as? String, let state = row["status"] as? String else { throw ClickUpError.invalidResponse }
                if state == "not_found_or_authorized" { result.append(.unavailable(id)); continue }
                guard state == "found", let data = row["data"] as? [String: Any], data["id"] as? String == id,
                      data["workspace_id"] as? String == connection.workspaceID,
                      let listID = data["subcategory"] as? String, ClickUpConnection.isNumericID(listID),
                      let states = data["states"] as? [String: Any], let deleted = states["is_deleted"] as? Bool else { throw ClickUpError.invalidResponse }
                if deleted { result.append(.unavailable(id)); continue }
                if lists[listID] == nil {
                    do {
                        let list = try await call(.list, ["workspace_id": connection.workspaceID, "list_id": listID])
                        guard list["id"] as? String == listID else { throw ClickUpError.invalidResponse }
                        lists[listID] = list
                    } catch ClickUpError.unavailable { result.append(.unavailable(id)); continue }
                }
                result.append(.task(try Self.task(data, list: lists[listID]!, connection: connection)))
            }
        }
        try verify(connection)
        return result
    }

    // ClickUp truncates large operator responses. Split reads; never import a truncated preview.
    private func readBatch(_ ids: [String], connection: ClickUpConnection) async throws -> [[String: Any]] {
        guard let workspaceID = Int(connection.workspaceID) else { throw ClickUpError.invalidResponse }
        let object = try await call(.bulk, ["model": "task", "operator": "get_many", "operation_id": "getBulkTasks",
            "workspace_id": connection.workspaceID, "body": ["ids": ids, "workspaceId": workspaceID], "query": Self.projection])
        if object["truncated"] as? Bool == true {
            guard ids.count > 1 else { throw ClickUpError.invalidResponse }
            let middle = ids.count / 2
            let first = try await readBatch(Array(ids[..<middle]), connection: connection)
            return try await first + readBatch(Array(ids[middle...]), connection: connection)
        }
        guard let rows = object["tasks"] as? [[String: Any]], rows.count == ids.count,
              Set(rows.compactMap { $0["object_id"] as? String }) == Set(ids) else { throw ClickUpError.invalidResponse }
        return rows
    }

    static let projection = "{tasks:tasks[].{object_id:object_id,status:status,data:data.{id:id,name:name,custom_id:custom_id,text_content:text_content,status:status,workspace_id:workspace_id,subcategory:subcategory,direct_parent:direct_parent,time_mgmt:time_mgmt.{date_updated:date_updated},users:users[?type==`assigned`].userid,states:states.{is_deleted:is_deleted,is_archived:is_archived}}}}"

    static func task(_ data: [String: Any], list: [String: Any], connection: ClickUpConnection) throws -> ClickUpTask {
        guard let id = data["id"] as? String, let title = data["name"] as? String,
              let workspaceID = data["workspace_id"] as? String, let listID = data["subcategory"] as? String,
              let listName = list["name"] as? String, let status = data["status"] as? [String: Any],
              let statusID = status["id"] as? String, let statuses = list["statuses"] as? [[String: Any]],
              let configured = statuses.first(where: { $0["id"] as? String == statusID }),
              let label = configured["status"] as? String, let type = configured["type"] as? String,
              let users = data["users"] as? [Any], let time = data["time_mgmt"] as? [String: Any],
              let timestamp = time["date_updated"] as? String, let milliseconds = Double(timestamp),
              let states = data["states"] as? [String: Any], let archived = states["is_archived"] as? Bool,
              data["text_content"] == nil || data["text_content"] is NSNull || data["text_content"] is String else { throw ClickUpError.invalidResponse }
        // Bulk task metadata can include negative IDs for additional assignees.
        let assignees = users.compactMap { value -> String? in
            guard let number = value as? NSNumber, String(cString: number.objCType) != "c",
                  number.stringValue.range(of: "^-?[0-9]+$", options: .regularExpression) != nil else { return nil }
            return number.stringValue
        }
        guard assignees.count == users.count else { throw ClickUpError.invalidResponse }
        let task = ClickUpTask(id: id, workspaceID: workspaceID, title: title,
            details: (data["text_content"] as? String).map { String($0.prefix(50_000)) }, customID: data["custom_id"] as? String,
            listID: listID, listName: listName, parentID: data["direct_parent"] as? String, status: label, statusType: type,
            assigneeIDs: assignees.sorted(), updatedAt: Date(timeIntervalSince1970: milliseconds / 1_000), archived: archived)
        try task.validate(workspaceID: connection.workspaceID)
        return task
    }

    private static func numericID(_ value: Any?) -> String? {
        if let value = value as? String, ClickUpConnection.isNumericID(value) { return value }
        guard let number = value as? NSNumber, String(cString: number.objCType) != "c",
              ClickUpConnection.isNumericID(number.stringValue) else { return nil }
        return number.stringValue
    }

    private func verify(_ connection: ClickUpConnection) throws {
        try Task.checkCancellation()
        try connection.validate()
        guard let saved = try credentials.load().connection, saved.workspaceID == connection.workspaceID,
              saved.userID == connection.userID else { throw ClickUpError.accountChanged }
    }

    private enum Tool: String {
        case user = "clickup_get_user", hierarchy = "clickup_get_workspace_hierarchy", filter = "clickup_filter_tasks"
        case bulk = "clickup_execute_operator", list = "clickup_get_list"
    }
    private enum TransportError: Error { case sessionExpired }

    private func call(_ tool: Tool, _ arguments: [String: Any]) async throws -> [String: Any] {
        do { return try await callOnce(tool, arguments) }
        catch TransportError.sessionExpired {
            initialized = false; sessionID = nil
            return try await callOnce(tool, arguments)
        }
    }
    private func callOnce(_ tool: Tool, _ arguments: [String: Any]) async throws -> [String: Any] {
        let tokens = try credentials.load()
        if activeToken != tokens.accessToken { initialized = false; sessionID = nil; activeToken = tokens.accessToken }
        if !initialized {
            let result = try await rpc("initialize", ["protocolVersion": protocolVersion, "capabilities": [:],
                "clientInfo": ["name": "Focus Island", "version": "0.7.0"]])
            guard let version = result["protocolVersion"] as? String,
                  ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"].contains(version) else { throw ClickUpError.invalidResponse }
            protocolVersion = version
            _ = try await rpc("notifications/initialized", [:], notification: true)
            initialized = true
        }
        let result = try await rpc("tools/call", ["name": tool.rawValue, "arguments": arguments])
        var payload = result["structuredContent"] as? [String: Any]
        if payload == nil {
            for item in result["content"] as? [[String: Any]] ?? [] {
                if let text = item["text"] as? String, let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] { payload = object; break }
            }
        }
        if result["isError"] as? Bool == true || payload?["error"] != nil {
            let code = payload?["code"] as? String ?? payload?["error_code"] as? String
            if code == "RATE_LIMIT_EXCEEDED" { throw Self.rateLimit(payload?["retryAfter"]) }
            if ["NOT_FOUND", "FORBIDDEN"].contains(code ?? "") { throw ClickUpError.unavailable }
            throw ClickUpError.commandFailed
        }
        guard let payload else { throw ClickUpError.invalidResponse }
        return payload
    }

    private func rpc(_ method: String, _ params: [String: Any], notification: Bool = false) async throws -> [String: Any] {
        let revision = credentials.revision
        let id = UUID().uuidString
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if !notification { body["id"] = id }
        var request = try IntegrationHTTP.request(ClickUpOAuth.endpoint, body: body)
        request.setValue("Bearer \(try credentials.load().accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        let response = try await send(request)
        try credentials.check(revision)
        if response.status == 401 { throw ClickUpError.signInRequired }
        if response.status == 429 { throw Self.rateLimit(response.retryAfter) }
        if response.status == 404, sessionID != nil { throw TransportError.sessionExpired }
        if [403, 404].contains(response.status) { throw ClickUpError.unavailable }
        guard (200..<300).contains(response.status) else { throw ClickUpError.commandFailed }
        if let id = response.sessionID { sessionID = id }
        if notification { return [:] }
        var messages = [response.data]
        messages += String(decoding: response.data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n").map { event in
                Data(event.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n").utf8)
            }
        for message in messages {
            if let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any], object["id"] as? String == id {
                guard object["jsonrpc"] as? String == "2.0", object["error"] == nil,
                      let result = object["result"] as? [String: Any] else { throw ClickUpError.commandFailed }
                return result
            }
        }
        throw ClickUpError.invalidResponse
    }

    static func rateLimit(_ retryAfter: Any?, now: Date = .now) -> ClickUpError {
        let seconds = (retryAfter as? Double) ?? (retryAfter as? String).flatMap(Double.init)
        if let seconds, seconds.isFinite, seconds >= 0, seconds <= 604_800 {
            return .rateLimitedUntil(now.addingTimeInterval(seconds))
        }
        if let value = retryAfter as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            if let date = formatter.date(from: value), date > now { return .rateLimitedUntil(date) }
        }
        return .rateLimited
    }

    private final class Credentials: @unchecked Sendable {
        let store: any IntegrationCredentialStoring
        private let lock = NSLock()
        private var generation = UUID()
        var revision: UUID { lock.withLock { generation } }
        init(store: any IntegrationCredentialStoring) { self.store = store }
        func load() throws -> ClickUpCredentials {
            try lock.withLock {
                guard let data = try store.load(), let token = try? JSONDecoder().decode(ClickUpCredentials.self, from: data),
                      token.expiresAt.timeIntervalSinceNow > 30, !token.accessToken.isEmpty else { throw ClickUpError.signInRequired }
                return token
            }
        }
        func check(_ revision: UUID) throws {
            try lock.withLock { try Task.checkCancellation(); guard generation == revision else { throw CancellationError() } }
        }
        func save(_ token: ClickUpCredentials, revision: UUID) throws {
            try lock.withLock {
                try Task.checkCancellation()
                guard generation == revision else { throw CancellationError() }
                try store.save(JSONEncoder().encode(token))
            }
        }
        func remove() throws { try lock.withLock { generation = UUID(); try store.remove() } }
    }
}
