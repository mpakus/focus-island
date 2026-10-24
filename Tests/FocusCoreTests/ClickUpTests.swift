import CryptoKit
import Foundation
import Testing
@testable import FocusCore

struct ClickUpTests {
    @Test func browserAuthorizationUsesReadScopePKCEAndAnExactLoopbackCallback() async throws {
        let fixture = ClickUpAuthorizationFixture()
        let tokens = try await ClickUpOAuth.authorize(send: { try await fixture.send($0) }, browser: { url in
            let callback = try await fixture.browser(url)
            let (_, response) = try await URLSession.shared.data(from: callback)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
        })
        #expect(tokens.accessToken == "access")
        #expect(tokens.expiresAt > .now)
        #expect(await fixture.exchanged)
    }

    @Test func callbackRejectsWrongIssuerDestinationAndDuplicateParameters() throws {
        let base = "http://127.0.0.1:43210/clickup/callback"
        let callback = URL(string: base)!
        let valid = base + "?state=expected&code=code&iss=https%3A%2F%2Fmcp.clickup.com"
        #expect(try ClickUpOAuth.code(from: URL(string: valid)!, state: "expected", callback: callback) == "code")
        for value in [valid.replacingOccurrences(of: "43210", with: "43211"), valid.replacingOccurrences(of: "expected", with: "other"),
                      valid.replacingOccurrences(of: "mcp.clickup.com", with: "evil.example"), valid + "&code=other",
                      valid + "&state=expected", valid + "&iss=https%3A%2F%2Fmcp.clickup.com", valid + "#fragment"] {
            #expect(throws: ClickUpError.invalidResponse) { try ClickUpOAuth.code(from: URL(string: value)!, state: "expected", callback: callback) }
        }
        let denied = valid.replacingOccurrences(of: "code=code", with: "error=access_denied")
        #expect(throws: CancellationError.self) { try ClickUpOAuth.code(from: URL(string: denied)!, state: "expected", callback: callback) }
    }

    @Test func untrustedDiscoveryStopsBeforeRegistrationOrBrowser() async throws {
        await #expect(throws: ClickUpError.invalidResponse) {
            try await ClickUpOAuth.authorize(callback: URL(string: "http://127.0.0.1:43210/clickup/callback")!, send: { _ in
                IntegrationHTTPResponse(data: Data(#"{"resource":"https://mcp.clickup.com","authorization_servers":["https://evil.example"]}"#.utf8))
            }, browser: { _ in Issue.record("Untrusted discovery opened the browser"); throw CancellationError() })
        }
    }
}

private actor ClickUpAuthorizationFixture {
    var challenge: String?
    var exchanged = false
    func browser(_ url: URL) throws -> URL {
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) throws -> String { try #require(items.first { $0.name == name }?.value) }
        #expect(url.host == "mcp.clickup.com" && url.path == "/oauth/authorize")
        #expect(try value("scope") == "read")
        #expect(try value("resource") == "https://mcp.clickup.com")
        #expect(try value("code_challenge_method") == "S256")
        challenge = try value("code_challenge")
        return URL(string: try value("redirect_uri") + "?state=\(value("state"))&code=authorized&iss=https%3A%2F%2Fmcp.clickup.com")!
    }

    func send(_ request: URLRequest) throws -> IntegrationHTTPResponse {
        let result: [String: Any]
        switch request.url?.path {
        case "/.well-known/oauth-protected-resource":
            result = ["resource": ClickUpOAuth.issuer, "authorization_servers": [ClickUpOAuth.issuer]]
        case "/.well-known/oauth-authorization-server":
            result = ["issuer": ClickUpOAuth.issuer, "authorization_endpoint": ClickUpOAuth.issuer + "/oauth/authorize",
                      "token_endpoint": ClickUpOAuth.issuer + "/oauth/token", "registration_endpoint": ClickUpOAuth.issuer + "/oauth/register",
                      "code_challenge_methods_supported": ["S256"], "token_endpoint_auth_methods_supported": ["none"], "scopes_supported": ["read", "write"]]
        case "/oauth/register":
            let input = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            #expect(input["client_name"] as? String == "Focus Island")
            #expect(input["scope"] as? String == "read")
            #expect(input["grant_types"] as? [String] == ["authorization_code"])
            let callback = try #require((input["redirect_uris"] as? [String])?.first.flatMap(URL.init(string:)))
            #expect(callback.host == "127.0.0.1" && callback.port != nil && callback.path == "/clickup/callback")
            result = ["client_id": "client", "token_endpoint_auth_method": "none"]
        case "/oauth/token":
            let form = String(decoding: request.httpBody!, as: UTF8.self)
            let items = try #require(URLComponents(string: "https://test.invalid/?\(form)")?.queryItems)
            let verifier = try #require(items.first { $0.name == "code_verifier" }?.value)
            #expect(ClickUpOAuth.base64(Data(SHA256.hash(data: Data(verifier.utf8)))) == challenge)
            #expect(items.first { $0.name == "code" }?.value == "authorized")
            #expect(!form.contains("client_secret"))
            exchanged = true
            result = ["access_token": "access", "expires_in": 3600, "token_type": "Bearer", "scope": "read"]
        default: throw ClickUpError.invalidResponse
        }
        return IntegrationHTTPResponse(data: try JSONSerialization.data(withJSONObject: result))
    }
}
