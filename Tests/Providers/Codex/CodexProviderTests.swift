import Foundation
import XCTest
@testable import AIUsage

@MainActor
final class CodexProviderTests: XCTestCase {
    func testBuildsIsolatedAccountScopedRequest() {
        let credentials = CodexCredentials(accessToken: "access-value", accountID: "account-123")

        let request = CodexProvider.makeRequest(credentials: credentials)
        let session = CodexProvider.makeSession()

        XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/wham/usage")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-value")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account-123")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertTrue(session.delegate is RejectRedirectDelegate)
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertNil(session.configuration.urlCredentialStorage)
    }

    func testRefreshesAuthenticationAndRetriesOnceAfterUnauthorizedResponse() async throws {
        let session = makeStubSession()
        let usage = Data(#"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":12,"reset_at":1787793027,"limit_window_seconds":18000},"secondary_window":null}}"#.utf8)
        StubURLProtocol.store.set { request in
            let status = request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token" ? 200 : 401
            return (
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                status == 200 ? usage : Data())
        }

        var accessToken = "expired-token"
        var refreshCount = 0
        let provider = CodexProvider(
            session: session,
            authLoader: { CodexCredentials(accessToken: accessToken, accountID: nil) },
            authRefresher: {
                refreshCount += 1
                accessToken = "fresh-token"
            })

        let snapshot = try await provider.fetch()

        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [12])
        XCTAssertEqual(refreshCount, 1)
    }

    func testAuthRefresherUsesSelectedProfileAndOfficialAppServerProtocol() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiusage-codex-refresh-\(UUID().uuidString)", isDirectory: true)
        let profile = root.appendingPathComponent("profile", isDirectory: true)
        let executable = root.appendingPathComponent("fake-codex", isDirectory: false)
        let authFile = profile.appendingPathComponent("auth.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: authFile)
        let script = #"""
        #!/bin/sh
        [ "$1" = "app-server" ] || exit 20
        [ "$2" = "--listen" ] || exit 21
        [ "$3" = "stdio://" ] || exit 22
        [ -f "$CODEX_HOME/auth.json" ] || exit 23
        IFS= read -r initialize || exit 24
        case "$initialize" in *'"method":"initialize"'*) ;; *) exit 25 ;; esac
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
        IFS= read -r initialized || exit 26
        case "$initialized" in *'"method":"initialized"'*) ;; *) exit 27 ;; esac
        IFS= read -r account || exit 28
        case "$account" in *'"method":"account/read"'*|*'"method":"account\/read"'*) ;; *) exit 29 ;; esac
        case "$account" in *'"refreshToken":true'*) ;; *) exit 30 ;; esac
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"account":{"type":"chatgpt","email":null,"planType":"plus"},"requiresOpenaiAuth":true}}'
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        try await CodexAuthRefresher.refresh(
            authFileURL: authFile,
            executableURL: executable,
            timeout: .seconds(5))
    }

    func testConfiguredProviderRefreshesItsSelectedAuthFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiusage-codex-profile-\(UUID().uuidString)", isDirectory: true)
        let authFile = root.appendingPathComponent("auth.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"tokens":{"access_token":"expired-token","account_id":"account-123"}}"#.utf8)
            .write(to: authFile)

        let session = makeStubSession()
        let usage = Data(#"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":9,"reset_at":1787793027,"limit_window_seconds":18000},"secondary_window":null}}"#.utf8)
        StubURLProtocol.store.set { request in
            let status = request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token" ? 200 : 401
            return (
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                status == 200 ? usage : Data())
        }

        var refreshedFile: URL?
        let provider = CodexProvider(
            session: session,
            authFileURL: authFile,
            authFileRefresher: { url in
                refreshedFile = url
                try Data(#"{"tokens":{"access_token":"fresh-token","account_id":"account-123"}}"#.utf8)
                    .write(to: url)
            })

        let snapshot = try await provider.fetch()

        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [9])
        XCTAssertEqual(refreshedFile?.standardizedFileURL, authFile.standardizedFileURL)
    }

    func testFetchClassifiesAuthenticationAndHTTPFailures() async throws {
        let session = makeStubSession()
        let provider = CodexProvider(
            session: session,
            authLoader: { CodexCredentials(accessToken: "test-token", accountID: nil) },
            authRefresher: { throw CodexUsageError.unauthorized })

        for status in [401, 403] {
            StubURLProtocol.store.set { request in
                (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data())
            }
            do {
                _ = try await provider.fetch()
                XCTFail("Expected unauthorized for HTTP \(status)")
            } catch let error as CodexUsageError {
                guard case .unauthorized = error else {
                    return XCTFail("Expected unauthorized, got \(error)")
                }
            }
        }

        for status in [429, 500, 503] {
            StubURLProtocol.store.set { request in
                (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data())
            }
            do {
                _ = try await provider.fetch()
                XCTFail("Expected HTTP error for \(status)")
            } catch let error as CodexUsageError {
                guard case let .http(received) = error else {
                    return XCTFail("Expected HTTP error, got \(error)")
                }
                XCTAssertEqual(received, status)
            }
        }
    }

    func testFetchPropagatesCommonTransportFailures() async throws {
        let session = makeStubSession()
        let provider = CodexProvider(
            session: session,
            authLoader: { CodexCredentials(accessToken: "test-token", accountID: nil) },
            authRefresher: { throw CodexUsageError.unauthorized })

        let codes: [URLError.Code] = [.timedOut, .notConnectedToInternet, .cannotFindHost, .secureConnectionFailed]
        for code in codes {
            StubURLProtocol.store.set { _ in throw URLError(code) }
            do {
                _ = try await provider.fetch()
                XCTFail("Expected URLError \(code)")
            } catch let error as URLError {
                XCTAssertEqual(error.code, code)
            }
        }
    }

    private func makeStubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    static let store = HandlerStore()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.store.handler()(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class HandlerStore: @unchecked Sendable {
    private let lock = NSLock()
    private var current: StubURLProtocol.Handler = { request in
        (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
    }

    func set(_ handler: @escaping StubURLProtocol.Handler) {
        lock.lock()
        current = handler
        lock.unlock()
    }

    func handler() -> StubURLProtocol.Handler {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
}
