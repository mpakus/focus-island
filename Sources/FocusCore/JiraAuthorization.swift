import CryptoKit
import Foundation
import Security

public protocol JiraCredentialStoring: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func remove() throws
}

public struct JiraKeychain: JiraCredentialStoring {
    private let service: String
    public init(service: String = "dev.zhanabayev.focusisland.jira") { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "browser-authorization"]
    }
    public func load() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw JiraError.credentialsUnavailable }
        return data
    }
    public func save(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw JiraError.credentialsUnavailable }
        } else if status != errSecSuccess { throw JiraError.credentialsUnavailable }
    }
    public func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw JiraError.credentialsUnavailable }
    }
}

public struct JiraHTTPResponse: Sendable {
    public var data: Data
    public var status: Int
    public var sessionID: String?
    public init(data: Data, status: Int = 200, sessionID: String? = nil) {
        self.data = data; self.status = status; self.sessionID = sessionID
    }
}

public enum JiraHTTP {
    public typealias Send = @Sendable (URLRequest) async throws -> JiraHTTPResponse

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    public static func send(_ request: URLRequest) async throws -> JiraHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw JiraError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 16 * 1_024 * 1_024 else { throw JiraError.invalidResponse }
            data.append(byte)
        }
        try Task.checkCancellation()
        return JiraHTTPResponse(data: data, status: response.statusCode, sessionID: response.value(forHTTPHeaderField: "Mcp-Session-Id"))
    }

    static func request(_ url: URL, body: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("FocusIsland", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    static func object(_ response: JiraHTTPResponse) throws -> [String: Any] {
        if response.status == 401 { throw JiraError.signInRequired }
        if [403, 404].contains(response.status) { throw JiraError.unavailable }
        guard (200..<300).contains(response.status),
              let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else { throw JiraError.invalidResponse }
        return object
    }
}

struct JiraOAuthCredentials: Codable, Sendable {
    var clientID: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var tokenEndpoint: URL
    var cloudID: String?
}

enum JiraOAuth {
    static let resource = URL(string: "https://mcp.atlassian.com/v2/mcp")!
    static let scopes = "read:me offline_access read:jira:agent-interface search:jira:agent-interface"

    static func endpoint(_ value: Any?) throws -> URL {
        guard let string = value as? String, let url = URL(string: string), url.scheme == "https",
              ["auth.atlassian.com", "mcp.atlassian.com"].contains(url.host), url.port == nil,
              url.user == nil, url.password == nil, url.fragment == nil else { throw JiraError.invalidResponse }
        return url
    }

    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw JiraError.commandFailed }
        return base64(Data(bytes))
    }
    static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func code(from url: URL, state: String, callback: URL) throws -> String {
        guard url.scheme == callback.scheme, url.host == callback.host, url.path == callback.path,
              url.user == nil, url.password == nil, url.port == callback.port, url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state else { throw JiraError.invalidResponse }
        if items.contains(where: { $0.name == "error" && $0.value == "access_denied" }) { throw CancellationError() }
        guard items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw JiraError.invalidResponse }
        return code
    }

    static func authorize(callback: URL, send: JiraHTTP.Send, browser: @Sendable (URL) async throws -> URL) async throws -> JiraOAuthCredentials {
        let resourceMetadata = try JiraHTTP.object(await send(JiraHTTP.request(URL(string: "https://mcp.atlassian.com/.well-known/oauth-protected-resource/v2/mcp")!)))
        guard resourceMetadata["resource"] as? String == resource.absoluteString,
              let servers = resourceMetadata["authorization_servers"] as? [String], let server = servers.first else { throw JiraError.invalidResponse }
        let issuer = try endpoint(server)
        let metadataURL = URL(string: "https://\(issuer.host!)/.well-known/oauth-authorization-server\(issuer.path)")!
        let metadata = try JiraHTTP.object(await send(JiraHTTP.request(metadataURL)))
        guard metadata["issuer"] as? String == issuer.absoluteString,
              (metadata["code_challenge_methods_supported"] as? [String])?.contains("S256") == true,
              (metadata["token_endpoint_auth_methods_supported"] as? [String])?.contains("none") == true else { throw JiraError.invalidResponse }
        let registration = try JiraHTTP.object(await send(JiraHTTP.request(endpoint(metadata["registration_endpoint"]), body: [
            "client_name": "Focus Island", "application_type": "native", "redirect_uris": [callback.absoluteString],
            "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
            "token_endpoint_auth_method": "none", "scope": scopes,
        ])))
        guard let clientID = registration["client_id"] as? String, !clientID.isEmpty,
              registration["token_endpoint_auth_method"] as? String == "none" else { throw JiraError.invalidResponse }
        let verifier = try random(), state = try random()
        var authorization = URLComponents(url: try endpoint(metadata["authorization_endpoint"]), resolvingAgainstBaseURL: false)!
        authorization.queryItems = ["client_id": clientID, "redirect_uri": callback.absoluteString, "scope": scopes,
            "response_type": "code", "state": state, "code_challenge_method": "S256", "prompt": "consent",
            "code_challenge": base64(Data(SHA256.hash(data: Data(verifier.utf8)))), "resource": resource.absoluteString]
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        let result = try await browser(authorization.url!)
        try Task.checkCancellation()
        let tokenURL = try endpoint(metadata["token_endpoint"])
        return try await token(send: send, endpoint: tokenURL, clientID: clientID, body: [
            "grant_type": "authorization_code", "code": code(from: result, state: state, callback: callback),
            "redirect_uri": callback.absoluteString, "code_verifier": verifier,
        ])
    }

    static func token(send: JiraHTTP.Send, endpoint: URL, clientID: String, body: [String: String], previous: JiraOAuthCredentials? = nil) async throws -> JiraOAuthCredentials {
        let endpoint = try self.endpoint(endpoint.absoluteString)
        var request = try JiraHTTP.request(endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let values = body.merging(["client_id": clientID, "resource": resource.absoluteString]) { _, new in new }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = Data(values.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)
        let response = try await send(request)
        if response.status == 400 || response.status == 401 { throw JiraError.signInRequired }
        let object = try JiraHTTP.object(response)
        guard let access = object["access_token"] as? String, !access.isEmpty,
              (object["token_type"] as? String)?.lowercased() == "bearer",
              let expires = object["expires_in"] as? Double, expires > 0 else { throw JiraError.invalidResponse }
        try Task.checkCancellation()
        return JiraOAuthCredentials(clientID: clientID, accessToken: access,
            refreshToken: object["refresh_token"] as? String ?? previous?.refreshToken,
            expiresAt: Date().addingTimeInterval(expires), tokenEndpoint: endpoint, cloudID: previous?.cloudID)
    }
}
