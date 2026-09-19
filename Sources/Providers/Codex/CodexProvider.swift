import Foundation

@MainActor
final class CodexProvider: UsageProvider {
    let id: ProviderID = .codex
    private let session: URLSession
    private let authLoader: () throws -> CodexCredentials
    private let authRefresher: () async throws -> Void

    init(
        session: URLSession,
        authLoader: @escaping () throws -> CodexCredentials,
        authRefresher: @escaping () async throws -> Void)
    {
        self.session = session
        self.authLoader = authLoader
        self.authRefresher = authRefresher
    }

    convenience init(
        session: URLSession = CodexProvider.makeSession(),
        authFileURL: URL = CodexAuth.authFileURL(),
        authFileRefresher: @escaping (URL) async throws -> Void = { url in
            try await CodexAuthRefresher.refresh(authFileURL: url)
        })
    {
        self.init(
            session: session,
            authLoader: { try CodexAuth.load(fileURL: authFileURL) },
            authRefresher: { try await authFileRefresher(authFileURL) })
    }

    func fetch() async throws -> ProviderSnapshot {
        var result = try await requestUsage()
        if result.response.statusCode == 401 {
            do {
                try await authRefresher()
            } catch {
                throw CodexUsageError.unauthorized
            }
            result = try await requestUsage()
        }

        let data = result.data
        let http = result.response
        guard http.statusCode != 401, http.statusCode != 403 else { throw CodexUsageError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw CodexUsageError.http(http.statusCode) }
        return try CodexUsageParser.parse(data: data)
    }

    private func requestUsage() async throws -> (data: Data, response: HTTPURLResponse) {
        let request = Self.makeRequest(credentials: try authLoader())
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CodexUsageError.invalidResponse }
        return (data, http)
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
