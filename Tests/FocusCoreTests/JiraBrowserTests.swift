import CryptoKit
import Foundation
import Testing
@testable import FocusCore

final class MemoryJiraCredentials: JiraCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    var beforeSave: (@Sendable () -> Void)?
    var beforeRemove: (@Sendable () -> Void)?
    func load() -> Data? { lock.withLock { data } }
    func save(_ data: Data) { beforeSave?(); lock.withLock { self.data = data } }
    func remove() { beforeRemove?(); lock.withLock { data = nil } }
}

actor BrowserJiraFixture {
    var calls: [String] = []
    var repeatPage = false
    var expireSession = false
    var initializations = 0
    func expire() { expireSession = true }
    let cloudID = "00000000-0000-0000-0000-000000000001"
    func repeatPagination() { repeatPage = true }
    func send(_ request: URLRequest) throws -> JiraHTTPResponse {
        func response(_ value: Any) throws -> JiraHTTPResponse { JiraHTTPResponse(data: try JSONSerialization.data(withJSONObject: value)) }
        if request.url?.path == "/oauth/token" {
            let form = String(decoding: request.httpBody!, as: UTF8.self)
            #expect(form.contains("refresh_token=refresh"))
            return try response(["access_token": "renewed", "refresh_token": "rotated", "token_type": "Bearer", "expires_in": 3600])
        }
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer renewed")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let method = body["method"] as? String
        var result: [String: Any] = [:]
        if expireSession, method == "tools/call" {
            expireSession = false
            return JiraHTTPResponse(data: Data(), status: 404)
        }
        if method == "initialize" { initializations += 1; result = ["protocolVersion": "2025-03-26", "capabilities": [:]] }
        else if method == "notifications/initialized" { return JiraHTTPResponse(data: Data(), status: 202) }
        else {
            let params = try #require(body["params"] as? [String: Any]), name = try #require(params["name"] as? String)
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            calls.append(name)
            let data: Any
            switch name {
            case "getAccessibleAtlassianResources":
                data = ["resources": [["cloudId": cloudID, "url": "https://example.atlassian.net", "products": [["id": "jira"]]]]]
            case "executeRead":
                #expect(arguments["name"] as? String == "getJiraCurrentUser")
                data = ["emailAddress": "person@example.com"]
            case "searchJiraIssuesUsingJql":
                #expect(arguments["jql"] as? String == JiraCLIClient.jql)
                let second = arguments["nextPageToken"] as? String == "next"
                data = ["issues": [Self.issue(id: second ? "2" : "1")], "isLast": second && !repeatPage, "nextPageToken": "next"]
            case "getJiraIssue": data = Self.issue(id: arguments["issueIdOrKey"] as! String)
            default: throw JiraError.invalidResponse
            }
            let text = String(decoding: try JSONSerialization.data(withJSONObject: ["data": data]), as: UTF8.self)
            result = ["content": [["type": "text", "text": text]]]
        }
        let envelope: [String: Any] = ["jsonrpc": "2.0", "id": body["id"]!, "result": result]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
        return JiraHTTPResponse(data: Data("event: message\ndata: \(json)\n\n".utf8), sessionID: "test-session")
    }
    static func issue(id: String) -> [String: Any] {
        ["id": id, "key": "TEST-\(id)", "fields": ["summary": "Assigned issue", "description": "## Jira text", "status": ["name": "In Progress"], "updated": "2026-10-23T10:00:00.000Z"]]
    }
}

struct JiraBrowserTests {
    @Test func nativeAuthorizationUsesPKCEAndReadOnlyScopesWithoutAClientSecret() async throws {
        let fixture = OAuthFixture(), store = MemoryJiraCredentials()
        let tokens = try await JiraOAuthCallback.authorize(send: { try await fixture.send($0) }, browser: { url in
            let callback = try await fixture.browser(url)
            let (data, response) = try await URLSession.shared.data(from: callback)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: data, as: UTF8.self).contains("return to Focus Island"))
        })
        #expect(tokens.accessToken == "access" && tokens.refreshToken == "refresh")
        #expect(await fixture.exchanged)
        let client = JiraMCPClient(credentials: store, send: { try await fixture.send($0) }, browser: { _ in throw CancellationError() }, chooseSite: { $0[0] })
        await #expect(throws: CancellationError.self) { try await client.authorize() }
        #expect(store.load() == nil)
    }

    @Test func callbackRequiresExactDestinationUniqueStateAndCode() throws {
        let callback = URL(string: "http://127.0.0.1:43210/jira/callback")!
        #expect(try JiraOAuth.code(from: URL(string: "http://127.0.0.1:43210/jira/callback?state=expected&code=code")!, state: "expected", callback: callback) == "code")
        for value in ["http://127.0.0.1:43211/jira/callback?state=expected&code=code", "https://jira/callback?state=expected&code=code", "http://127.0.0.1:43210/jira/callback?state=wrong&code=code", "http://127.0.0.1:43210/jira/callback?state=expected&state=expected&code=code", "http://127.0.0.1:43210/jira/callback?state=expected&code=a&code=b"] {
            #expect(throws: JiraError.invalidResponse) { try JiraOAuth.code(from: URL(string: value)!, state: "expected", callback: callback) }
        }
        #expect(throws: CancellationError.self) { try JiraOAuth.code(from: URL(string: "http://127.0.0.1:43210/jira/callback?state=expected&error=access_denied")!, state: "expected", callback: callback) }
    }

    @Test @MainActor func loopbackIgnoresWrongStateAndClosesWhenCancelled() async throws {
        let server = try JiraOAuthCallback()
        let callback = try await server.start()
        defer { server.stop() }
        let task = Task {
            try await server.open(URL(string: "https://auth.atlassian.com/authorize?state=expected")!, browser: { _ in
                let (_, response) = try await URLSession.shared.data(from: URL(string: "\(callback)?state=wrong&code=wrong")!)
                #expect((response as? HTTPURLResponse)?.statusCode == 400)
                _ = try await URLSession.shared.data(from: URL(string: "\(callback)?state=expected&code=right")!)
            })
        }
        #expect(try await task.value.absoluteString.hasSuffix("state=expected&code=right"))
        let waiting = Task { try await server.open(URL(string: "https://auth.atlassian.com/authorize?state=expected")!, browser: { _ in }) }
        await Task.yield()
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }

    @Test func authorizationEndpointsCannotRedirectCredentialsToAnotherHost() throws {
        for url in ["https://evil.example/token", "http://auth.atlassian.com/token", "https://auth.atlassian.com.evil.example/token", "https://user@auth.atlassian.com/token"] {
            #expect(throws: JiraError.invalidResponse) { try JiraOAuth.endpoint(url) }
        }
        #expect(try JiraOAuth.endpoint("https://auth.atlassian.com/oauth/token").host == "auth.atlassian.com")
    }

    @Test func refreshPaginationAndMarkdownKeepExistingBoardContract() async throws {
        let store = MemoryJiraCredentials(), fixture = BrowserJiraFixture()
        let saved = JiraOAuthCredentials(clientID: "client", accessToken: "expired", refreshToken: "refresh", expiresAt: .distantPast, tokenEndpoint: URL(string: "https://auth.atlassian.com/oauth/token")!)
        store.save(try JSONEncoder().encode(saved))
        let client = JiraMCPClient(credentials: store, send: { try await fixture.send($0) }, browser: { _ in throw JiraError.commandFailed }, chooseSite: { $0[0] })
        let connection = try await client.connect()
        #expect(connection.email == "person@example.com")
        #expect(try await client.search(connection: connection).map(\.id) == ["1", "2"])
        #expect(try await client.issue(id: "1", connection: connection).fields.description?.plainText == "## Jira text")
        let tokens = try JSONDecoder().decode(JiraOAuthCredentials.self, from: #require(store.load()))
        #expect(tokens.refreshToken == "rotated" && tokens.cloudID == connection.cloudID)
        await fixture.expire()
        #expect(try await client.search(connection: connection).count == 2)
        #expect(await fixture.initializations == 2)
        await fixture.repeatPagination()
        await #expect(throws: JiraError.invalidResponse) { try await client.search(connection: connection) }
        try client.disconnect()
        #expect(store.load() == nil)
        await #expect(throws: JiraError.signInRequired) { try await client.search(connection: connection) }
    }

    @Test func disconnectCannotBeUndoneByACancelledCredentialSave() async throws {
        let store = MemoryJiraCredentials(), fixture = BrowserJiraFixture()
        let saved = JiraOAuthCredentials(clientID: "client", accessToken: "expired", refreshToken: "refresh", expiresAt: .distantPast, tokenEndpoint: URL(string: "https://auth.atlassian.com/oauth/token")!)
        store.save(try JSONEncoder().encode(saved))
        let saving = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        store.beforeSave = { saving.signal(); release.wait() }
        let client = JiraMCPClient(credentials: store, send: { try await fixture.send($0) }, browser: { _ in }, chooseSite: { $0[0] })
        let operation = Task { try await client.connect() }
        let started = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: saving.wait(timeout: .now() + 5) == .success) }
        }
        #expect(started)
        operation.cancel()
        let removing = DispatchSemaphore(value: 0)
        store.beforeRemove = { removing.signal() }
        let disconnect = Task.detached { try client.disconnect() }
        let removedWhileSaving = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: removing.wait(timeout: .now() + 0.2) == .success) }
        }
        release.signal()
        #expect(!removedWhileSaving)
        _ = try? await operation.value
        try await disconnect.value
        #expect(store.load() == nil)
    }

    @Test func malformedIssueAndMismatchedRPCResponsesAreRejected() throws {
        #expect(throws: JiraError.invalidResponse) { try JiraMCPClient.issue(["id": "1", "key": "TEST-1", "fields": ["summary": "Missing timestamp"]]) }
        #expect(throws: JiraError.invalidResponse) { try JiraMCPClient.rpcResult(Data(#"{"jsonrpc":"2.0","id":"other","result":{}}"#.utf8), id: "expected") }
    }
}

private actor OAuthFixture {
    var challenge: String?
    var exchanged = false
    func browser(_ url: URL) throws -> URL {
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
        #expect(url.host == "auth.atlassian.com")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("scope") == "read:me offline_access read:jira:agent-interface search:jira:agent-interface")
        #expect(value("resource") == "https://mcp.atlassian.com/v2/mcp")
        challenge = value("code_challenge")
        let callback = try #require(value("redirect_uri"))
        return URL(string: "\(callback)?state=\(try #require(value("state")))&code=authorized")!
    }
    func send(_ request: URLRequest) throws -> JiraHTTPResponse {
        let body: [String: Any]
        switch request.url?.path {
        case "/.well-known/oauth-protected-resource/v2/mcp":
            body = ["resource": "https://mcp.atlassian.com/v2/mcp", "authorization_servers": ["https://auth.atlassian.com/issuer"]]
        case "/.well-known/oauth-authorization-server/issuer":
            body = ["issuer": "https://auth.atlassian.com/issuer", "authorization_endpoint": "https://auth.atlassian.com/authorize", "token_endpoint": "https://auth.atlassian.com/oauth/token", "registration_endpoint": "https://auth.atlassian.com/register", "code_challenge_methods_supported": ["S256"], "token_endpoint_auth_methods_supported": ["none"]]
        case "/register":
            let input = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            #expect(input["client_name"] as? String == "Focus Island")
            #expect(input["token_endpoint_auth_method"] as? String == "none")
            let callback = try #require((input["redirect_uris"] as? [String])?.first.flatMap(URL.init(string:)))
            #expect(callback.host == "127.0.0.1" && callback.port != nil && callback.path == "/jira/callback")
            body = ["client_id": "client", "token_endpoint_auth_method": "none"]
        case "/oauth/token":
            let form = String(decoding: request.httpBody!, as: UTF8.self)
            let items = try #require(URLComponents(string: "https://test.invalid/?\(form)")?.queryItems)
            let verifier = try #require(items.first { $0.name == "code_verifier" }?.value)
            #expect(JiraOAuth.base64(Data(SHA256.hash(data: Data(verifier.utf8)))) == challenge)
            #expect(!form.contains("client_secret"))
            #expect(items.first { $0.name == "code" }?.value == "authorized")
            exchanged = true
            body = ["access_token": "access", "refresh_token": "refresh", "expires_in": 3600, "token_type": "Bearer"]
        default: throw JiraError.invalidResponse
        }
        return JiraHTTPResponse(data: try JSONSerialization.data(withJSONObject: body))
    }
}
