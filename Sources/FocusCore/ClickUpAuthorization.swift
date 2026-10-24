import CryptoKit
import Foundation
import Security

struct ClickUpCredentials: Codable, Sendable {
    var clientID: String
    var accessToken: String
    var expiresAt: Date
    var connection: ClickUpConnection?
}

enum ClickUpOAuth {
    static let issuer = "https://mcp.clickup.com"
    static let resource = URL(string: issuer)!
    static let endpoint = URL(string: issuer + "/mcp")!

    static func object(_ response: IntegrationHTTPResponse) throws -> [String: Any] {
        if response.status == 401 { throw ClickUpError.signInRequired }
        if [403, 404].contains(response.status) { throw ClickUpError.unavailable }
        if response.status == 429 { throw ClickUpError.rateLimited }
        guard (200..<300).contains(response.status),
              let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else { throw ClickUpError.invalidResponse }
        return object
    }

    @MainActor static func authorize(send: IntegrationHTTP.Send, browser: @escaping @Sendable (URL) async throws -> Void) async throws -> ClickUpCredentials {
        let server = try OAuthCallback(path: "/clickup/callback")
        defer { server.stop() }
        do {
            let callback = try await server.start()
            return try await authorize(callback: callback, send: send, browser: { try await server.open($0, browser: browser) })
        } catch OAuthCallbackError.timedOut { throw ClickUpError.authorizationTimedOut }
        catch OAuthCallbackError.failed { throw ClickUpError.commandFailed }
    }

    static func authorize(callback: URL, send: IntegrationHTTP.Send, browser: @Sendable (URL) async throws -> URL) async throws -> ClickUpCredentials {
        let protected = try object(await send(IntegrationHTTP.request(URL(string: issuer + "/.well-known/oauth-protected-resource")!)))
        guard protected["resource"] as? String == issuer,
              protected["authorization_servers"] as? [String] == [issuer] else { throw ClickUpError.invalidResponse }
        let metadata = try object(await send(IntegrationHTTP.request(URL(string: issuer + "/.well-known/oauth-authorization-server")!)))
        guard metadata["issuer"] as? String == issuer,
              metadata["authorization_endpoint"] as? String == issuer + "/oauth/authorize",
              metadata["token_endpoint"] as? String == issuer + "/oauth/token",
              metadata["registration_endpoint"] as? String == issuer + "/oauth/register",
              (metadata["code_challenge_methods_supported"] as? [String])?.contains("S256") == true,
              (metadata["token_endpoint_auth_methods_supported"] as? [String])?.contains("none") == true,
              (metadata["scopes_supported"] as? [String])?.contains("read") == true else { throw ClickUpError.invalidResponse }
        let registration = try object(await send(IntegrationHTTP.request(URL(string: issuer + "/oauth/register")!, body: [
            "client_name": "Focus Island", "application_type": "native", "redirect_uris": [callback.absoluteString],
            "grant_types": ["authorization_code"], "response_types": ["code"], "token_endpoint_auth_method": "none", "scope": "read",
        ])))
        guard let clientID = registration["client_id"] as? String, !clientID.isEmpty,
              registration["token_endpoint_auth_method"] as? String == "none" else { throw ClickUpError.invalidResponse }
        let verifier = try random(), state = try random()
        var authorization = URLComponents(string: issuer + "/oauth/authorize")!
        authorization.queryItems = ["client_id": clientID, "redirect_uri": callback.absoluteString, "scope": "read",
            "response_type": "code", "state": state, "code_challenge_method": "S256", "resource": issuer,
            "code_challenge": base64(Data(SHA256.hash(data: Data(verifier.utf8))))].map { URLQueryItem(name: $0.key, value: $0.value) }
        let result = try await browser(authorization.url!)
        try Task.checkCancellation()
        let code = try code(from: result, state: state, callback: callback)
        var request = try IntegrationHTTP.request(URL(string: issuer + "/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = Data(["grant_type": "authorization_code", "code": code, "code_verifier": verifier,
            "redirect_uri": callback.absoluteString, "client_id": clientID, "resource": issuer]
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)
        let response = try await send(request)
        if [400, 401].contains(response.status) { throw ClickUpError.signInRequired }
        let token = try object(response)
        guard let access = token["access_token"] as? String, !access.isEmpty,
              (token["token_type"] as? String)?.lowercased() == "bearer",
              let expires = token["expires_in"] as? Double, expires.isFinite, expires > 0,
              token["scope"] == nil || token["scope"] as? String == "read" else { throw ClickUpError.invalidResponse }
        try Task.checkCancellation()
        return ClickUpCredentials(clientID: clientID, accessToken: access, expiresAt: Date().addingTimeInterval(expires))
    }

    static func code(from url: URL, state: String, callback: URL) throws -> String {
        guard url.scheme == callback.scheme, url.host == callback.host, url.path == callback.path, url.port == callback.port,
              url.user == nil, url.password == nil, url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.filter({ $0.name == "state" }).count == 1, items.first(where: { $0.name == "state" })?.value == state,
              items.filter({ $0.name == "iss" }).count == 1, items.first(where: { $0.name == "iss" })?.value == issuer else { throw ClickUpError.invalidResponse }
        if items.contains(where: { $0.name == "error" && $0.value == "access_denied" }) { throw CancellationError() }
        guard !items.contains(where: { $0.name == "error" }), items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw ClickUpError.invalidResponse }
        return code
    }

    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ClickUpError.commandFailed }
        return base64(Data(bytes))
    }
    static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
