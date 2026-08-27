import XCTest
@testable import AIUsage

final class CodexAuthTests: XCTestCase {
    func testParsesOAuthTokenAndAccountID() throws {
        let data = Data(#"{"tokens":{"access_token":"access-value","account_id":"account-123"}}"#.utf8)

        let credentials = try CodexAuth.parse(data: data)

        XCTAssertEqual(credentials.accessToken, "access-value")
        XCTAssertEqual(credentials.accountID, "account-123")
    }

    func testRejectsAPIKeyOnlyAuth() {
        let data = Data(#"{"OPENAI_API_KEY":"placeholder"}"#.utf8)
        XCTAssertThrowsError(try CodexAuth.parse(data: data))
    }
}
