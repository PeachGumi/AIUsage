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
}
