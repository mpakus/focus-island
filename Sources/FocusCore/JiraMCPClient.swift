import Foundation

/// A fixed set of read operations; no model, local proxy, or executable is involved.
public actor JiraMCPClient: JiraProviding {
    private nonisolated let credentialLock = NSLock()
    private nonisolated let credentials: any IntegrationCredentialStoring
    private let send: IntegrationHTTP.Send
    private let browser: @Sendable (URL) async throws -> Void
    private let chooseSite: @Sendable ([JiraConnection]) async throws -> JiraConnection
    private var sessionID: String?
    private var initialized = false
    private var protocolVersion = "2025-03-26"

    public init(credentials: any IntegrationCredentialStoring = IntegrationKeychain(service: "dev.zhanabayev.focusisland.jira"), send: @escaping IntegrationHTTP.Send = IntegrationHTTP.send,
                browser: @escaping @Sendable (URL) async throws -> Void,
                chooseSite: @escaping @Sendable ([JiraConnection]) async throws -> JiraConnection) {
        self.credentials = credentials; self.send = send; self.browser = browser; self.chooseSite = chooseSite
    }

    public func authorize() async throws -> JiraConnection {
        let tokens = try await JiraOAuth.authorize(send: send, browser: browser)
        try Task.checkCancellation()
        try save(tokens)
        initialized = false; sessionID = nil
        return try await connect()
    }

    public nonisolated func disconnect() throws {
        try credentialLock.withLock { try credentials.remove() }
    }

    private func save(_ tokens: JiraOAuthCredentials) throws {
        try credentialLock.withLock {
            try Task.checkCancellation()
            try credentials.save(JSONEncoder().encode(tokens))
        }
    }

    private func tokens() async throws -> JiraOAuthCredentials {
        guard let data = try credentials.load(), var tokens = try? JSONDecoder().decode(JiraOAuthCredentials.self, from: data) else { throw JiraError.signInRequired }
        if tokens.expiresAt.timeIntervalSinceNow < 60 {
            guard let refresh = tokens.refreshToken else { throw JiraError.signInRequired }
            tokens = try await JiraOAuth.token(send: send, endpoint: tokens.tokenEndpoint, clientID: tokens.clientID,
                                              body: ["grant_type": "refresh_token", "refresh_token": refresh], previous: tokens)
            try Task.checkCancellation()
            try save(tokens)
        }
        return tokens
    }

    public func connect() async throws -> JiraConnection {
        let resources = try await call("getAccessibleAtlassianResources")
        let rows = (resources as? [String: Any])?["resources"] as? [[String: Any]] ?? resources as? [[String: Any]] ?? []
        let sites = try rows.compactMap { row -> JiraConnection? in
            if let products = row["products"] as? [[String: Any]], !products.contains(where: { $0["id"] as? String == "jira" }) { return nil }
            guard let id = row["cloudId"] as? String ?? row["id"] as? String, UUID(uuidString: id) != nil,
                  let site = row["url"] as? String else { throw JiraError.invalidResponse }
            return JiraConnection(site: try JiraConnection.canonicalSite(site), email: "", cloudID: id)
        }
        guard !sites.isEmpty else { throw JiraError.unavailable }
        var saved = try await tokens()
        var connection: JiraConnection
        if let prior = sites.first(where: { $0.cloudID == saved.cloudID }) { connection = prior }
        else if sites.count == 1 { connection = sites[0] }
        else { connection = try await chooseSite(sites) }
        guard sites.contains(connection) else { throw JiraError.invalidResponse }
        guard let user = try await call("executeRead", arguments: ["name": "getJiraCurrentUser", "cloudId": connection.cloudID]) as? [String: Any],
              let label = user["emailAddress"] as? String ?? user["displayName"] as? String, !label.isEmpty else { throw JiraError.invalidResponse }
        connection.email = label
        saved = try await tokens()
        saved.cloudID = connection.cloudID
        try Task.checkCancellation()
        try save(saved)
        return connection
    }

    public func search(connection: JiraConnection) async throws -> [JiraIssue] {
        try await verify(connection)
        var result: [JiraIssue] = [], seen = Set<String>(), pages = Set<String>()
        var next: String?
        repeat {
            var arguments: [String: Any] = ["cloudId": connection.cloudID, "jql": JiraCLIClient.jql,
                "maxResults": 100, "fields": ["summary", "status", "issuetype", "priority", "assignee"]]
            if let next { arguments["nextPageToken"] = next }
            guard let page = try await call("searchJiraIssuesUsingJql", arguments: arguments) as? [String: Any],
                  let issues = page["issues"] as? [[String: Any]], let last = page["isLast"] as? Bool else { throw JiraError.invalidResponse }
            for object in issues {
                let issue = try Self.issue(object, requireUpdatedAt: false)
                if seen.insert(issue.id).inserted { result.append(issue) }
            }
            if last { return result }
            guard let token = page["nextPageToken"] as? String, !token.isEmpty, pages.insert(token).inserted,
                  pages.count <= 1_000 else { throw JiraError.invalidResponse }
            next = token
        } while next != nil
        return result
    }

    public func issue(id: String, connection: JiraConnection) async throws -> JiraIssue {
        guard id.range(of: "^[0-9]+$", options: .regularExpression) != nil else { throw JiraError.invalidResponse }
        try await verify(connection)
        guard let object = try await call("getJiraIssue", arguments: ["cloudId": connection.cloudID, "issueIdOrKey": id,
            "fields": ["summary", "status", "issuetype", "priority", "assignee", "updated", "description", "project"]]) as? [String: Any] else { throw JiraError.invalidResponse }
        let issue = try Self.issue(object)
        guard issue.id == id else { throw JiraError.invalidResponse }
        return issue
    }

    private func verify(_ connection: JiraConnection) async throws {
        guard try await tokens().cloudID == connection.cloudID else { throw JiraError.accountChanged }
    }

    static func issue(_ object: [String: Any], requireUpdatedAt: Bool = true) throws -> JiraIssue {
        var object = object
        if var fields = object["fields"] as? [String: Any] {
            // MCP returns Markdown descriptions; preserve the text in the existing local snapshot format.
            if let text = fields["description"] as? String { fields["description"] = ["type": "doc", "content": [["type": "text", "text": text]]] }
            if let assignee = fields["assignee"] as? [String: Any], assignee["accountId"] == nil { fields.removeValue(forKey: "assignee") }
            object["fields"] = fields
        }
        let issue: JiraIssue
        do { issue = try JSONDecoder().decode(JiraIssue.self, from: JSONSerialization.data(withJSONObject: object)) }
        catch { throw JiraError.invalidResponse }
        try issue.validate(requireUpdatedAt: requireUpdatedAt)
        return issue
    }

    private enum TransportError: Error { case sessionExpired }

    private func call(_ name: String, arguments: [String: Any] = [:]) async throws -> Any {
        do { return try await callOnce(name, arguments: arguments) }
        catch TransportError.sessionExpired {
            initialized = false; sessionID = nil
            return try await callOnce(name, arguments: arguments)
        }
    }

    private func callOnce(_ name: String, arguments: [String: Any]) async throws -> Any {
        if !initialized {
            let result = try await rpc("initialize", params: ["protocolVersion": protocolVersion,
                "capabilities": [:], "clientInfo": ["name": "Focus Island", "version": "0.6.0"]])
            guard let version = result["protocolVersion"] as? String,
                  ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"].contains(version) else { throw JiraError.invalidResponse }
            protocolVersion = version
            _ = try await rpc("notifications/initialized", params: [:], notification: true)
            initialized = true
        }
        let result = try await rpc("tools/call", params: ["name": name, "arguments": arguments])
        guard result["isError"] as? Bool != true else {
            let structured = result["structuredContent"] as? [String: Any]
            if ["NOT_FOUND", "FORBIDDEN"].contains(structured?["error_code"] as? String ?? "") { throw JiraError.unavailable }
            throw JiraError.commandFailed
        }
        if let structured = result["structuredContent"] as? [String: Any],
           let issues = structured["issues"] as? [String: Any], let nodes = issues["nodes"] as? [[String: Any]] {
            if name == "getJiraIssue", nodes.count == 1 { return nodes[0] }
            if let info = issues["pageInfo"] as? [String: Any], let hasNext = info["hasNextPage"] as? Bool {
                var page: [String: Any] = ["issues": nodes, "isLast": !hasNext]
                page["nextPageToken"] = info["endCursor"]
                return page
            }
        }
        guard let contents = result["content"] as? [[String: Any]] else { throw JiraError.invalidResponse }
        for item in contents where item["type"] as? String == "text" {
            if let text = item["text"] as? String, let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) {
                return (value as? [String: Any])?["data"] ?? value
            }
        }
        throw JiraError.invalidResponse
    }

    private func rpc(_ method: String, params: [String: Any], notification: Bool = false) async throws -> [String: Any] {
        let id = UUID().uuidString
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if !notification { body["id"] = id }
        var request = try IntegrationHTTP.request(JiraOAuth.resource, body: body)
        request.setValue("Bearer \(try await tokens().accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        let response = try await send(request)
        if let id = response.sessionID { sessionID = id }
        if response.status == 401 { throw JiraError.signInRequired }
        if response.status == 404, sessionID != nil { throw TransportError.sessionExpired }
        if [403, 404].contains(response.status) { throw JiraError.unavailable }
        guard (200..<300).contains(response.status) else { throw JiraError.commandFailed }
        if notification { return [:] }
        return try Self.rpcResult(response.data, id: id)
    }

    static func rpcResult(_ data: Data, id: String) throws -> [String: Any] {
        var messages = [data]
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        messages += text.components(separatedBy: "\n\n").map { event in
            Data(event.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n").utf8)
        }
        for message in messages {
            if let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any], object["id"] as? String == id {
                guard object["jsonrpc"] as? String == "2.0", object["error"] == nil,
                      let result = object["result"] as? [String: Any] else { throw JiraError.commandFailed }
                return result
            }
        }
        throw JiraError.invalidResponse
    }
}
