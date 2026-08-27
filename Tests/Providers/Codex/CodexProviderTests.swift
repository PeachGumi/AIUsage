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

    func testFetchClassifiesAuthenticationAndHTTPFailures() async throws {
        let session = makeStubSession()
        let provider = CodexProvider(
            session: session,
            authLoader: { CodexCredentials(accessToken: "test-token", accountID: nil) })

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
            authLoader: { CodexCredentials(accessToken: "test-token", accountID: nil) })

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
