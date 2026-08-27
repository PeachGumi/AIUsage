import XCTest
@testable import AIUsage

@MainActor
final class QwenProviderTests: XCTestCase {
    func testGatewayRequestEncodesCredentialsAndJSONAsFormData() throws {
        let request = try QwenProvider.makeGatewayRequest(
            api: "example.api/path",
            data: ["commodityCode": "plan & tier"],
            secToken: "token+value",
            cookieHeader: "session=cookie")
        let body = String(data: request.httpBody!, encoding: .utf8)!

        XCTAssertEqual(request.url?.host, "cs-data.qwencloud.com")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=cookie")
        XCTAssertTrue(body.contains("sec_token=token%2Bvalue"))
        XCTAssertFalse(body.contains("plan & tier"))
    }

    func testParsesSecTokenAndRecognizesExpiredSession() throws {
        let valid = Data(#"{"code":"Success","data":{"secToken":"secure-token"}}"#.utf8)
        let expired = Data(#"{"code":"ConsoleNeedLogin"}"#.utf8)

        XCTAssertEqual(try QwenProvider.parseSecToken(valid), "secure-token")
        XCTAssertThrowsError(try QwenProvider.parseSecToken(expired))
    }
}
