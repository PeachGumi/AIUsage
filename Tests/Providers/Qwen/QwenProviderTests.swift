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

    func testLegacyFallbackOnlyAllowsExactHomeHTTPSHost() {
        XCTAssertTrue(QwenCookieRepository.isLegacyCompatible(
            URL(string: "https://home.qwencloud.com/tool/user/info.json")!))
        XCTAssertFalse(QwenCookieRepository.isLegacyCompatible(
            URL(string: "https://cs-data.qwencloud.com/data/api.json")!))
        XCTAssertFalse(QwenCookieRepository.isLegacyCompatible(
            URL(string: "https://sub.home.qwencloud.com/tool/user/info.json")!))
        XCTAssertFalse(QwenCookieRepository.isLegacyCompatible(
            URL(string: "http://home.qwencloud.com/tool/user/info.json")!))
    }

    func testCookiePathMatchingRequiresPathBoundary() {
        XCTAssertTrue(QwenCookieRepository.pathMatches(cookiePath: "/", requestPath: "/anything"))
        XCTAssertTrue(QwenCookieRepository.pathMatches(cookiePath: "/account", requestPath: "/account"))
        XCTAssertTrue(QwenCookieRepository.pathMatches(cookiePath: "/account", requestPath: "/account/usage"))
        XCTAssertTrue(QwenCookieRepository.pathMatches(cookiePath: "/account/", requestPath: "/account/usage"))
        XCTAssertFalse(QwenCookieRepository.pathMatches(cookiePath: "/account", requestPath: "/accounting"))
    }

    func testDomainMatchingDoesNotAcceptSuffixLookalikes() {
        XCTAssertTrue(QwenCookieRepository.domainMatches(
            cookieDomain: ".qwencloud.com", host: "home.qwencloud.com"))
        XCTAssertTrue(QwenCookieRepository.domainMatches(
            cookieDomain: "qwencloud.com", host: "qwencloud.com"))
        XCTAssertFalse(QwenCookieRepository.domainMatches(
            cookieDomain: "qwencloud.com", host: "qwencloud.com.evil.example"))
        XCTAssertFalse(QwenCookieRepository.domainMatches(
            cookieDomain: "qwencloud.com", host: "fakeqwencloud.com"))
    }

    func testLegacyHeaderRejectsHeaderInjectionAndMalformedNames() {
        XCTAssertTrue(QwenCookieRepository.isValidHeaderShape("session=abc; user_id=123"))
        XCTAssertFalse(QwenCookieRepository.isValidHeaderShape("session=abc\nInjected=value"))
        XCTAssertFalse(QwenCookieRepository.isValidHeaderShape("session=abc\rInjected=value"))
        XCTAssertFalse(QwenCookieRepository.isValidHeaderShape("=value"))
    }
}
