import Foundation

@MainActor
final class CodexProvider: UsageProvider {
    let id: ProviderID = .codex
    private let session: URLSession
    private let authLoader: () throws -> CodexCredentials

    init(
        session: URLSession = CodexProvider.makeSession(),
        authLoader: @escaping () throws -> CodexCredentials = { try CodexAuth.load() })
    {
        self.session = session
        self.authLoader = authLoader
    }

    func fetch() async throws -> ProviderSnapshot {
        let request = Self.makeRequest(credentials: try authLoader())
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CodexUsageError.invalidResponse }
        guard http.statusCode != 401, http.statusCode != 403 else { throw CodexUsageError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw CodexUsageError.http(http.statusCode) }
        return try CodexUsageParser.parse(data: data)
    }

    static func makeRequest(credentials: CodexCredentials) -> URLRequest {
        let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AIUsage/1.0", forHTTPHeaderField: "User-Agent")
        if let accountID = credentials.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return request
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(
            configuration: configuration,
            delegate: RejectRedirectDelegate(),
            delegateQueue: nil)
    }
}

final class RejectRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void)
    {
        completionHandler(nil)
    }
}
