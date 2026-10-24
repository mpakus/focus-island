import Foundation
import Security

public enum IntegrationCredentialError: Error { case unavailable }

public protocol IntegrationCredentialStoring: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func remove() throws
}

public struct IntegrationKeychain: IntegrationCredentialStoring {
    private let service: String
    public init(service: String) { self.service = service }
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
        guard status == errSecSuccess, let data = result as? Data else { throw IntegrationCredentialError.unavailable }
        return data
    }
    public func save(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw IntegrationCredentialError.unavailable }
        } else if status != errSecSuccess { throw IntegrationCredentialError.unavailable }
    }
    public func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw IntegrationCredentialError.unavailable }
    }
}

public struct IntegrationHTTPResponse: Sendable {
    public var data: Data
    public var status: Int
    public var sessionID: String?
    public var retryAfter: String?
    public init(data: Data, status: Int = 200, sessionID: String? = nil, retryAfter: String? = nil) {
        self.data = data; self.status = status; self.sessionID = sessionID; self.retryAfter = retryAfter
    }
}

public enum IntegrationHTTP {
    public typealias Send = @Sendable (URLRequest) async throws -> IntegrationHTTPResponse

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    public static func send(_ request: URLRequest) async throws -> IntegrationHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 16 * 1_024 * 1_024 else { throw URLError(.badServerResponse) }
            data.append(byte)
        }
        try Task.checkCancellation()
        return IntegrationHTTPResponse(data: data, status: response.statusCode, sessionID: response.value(forHTTPHeaderField: "Mcp-Session-Id"), retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
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

}
