import XCTest
@testable import AIUsage

@MainActor
final class QwenProviderTests: XCTestCase {
    func testHTTPAuthenticationFailuresRequireSignInButTransientFailuresDoNot() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QwenStatusURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        for status in [401, 403, 429, 500, 503] {
            let provider = QwenProvider(session: session, cookieSource: { _ in "status=\(status)" })
            do {
                _ = try await provider.fetch()
                XCTFail("Expected HTTP failure for \(status)")
            } catch let error as QwenUsageError {
                XCTAssertEqual(error, .http(status))
                XCTAssertEqual(error.requiresAuthentication, status == 401 || status == 403)
            }
        }
    }

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

    func testQwenSessionRejectsRedirectsAndSharedCredentialState() {
        let session = QwenProvider.makeSession()

        XCTAssertTrue(session.delegate is RejectRedirectDelegate)
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertFalse(session.configuration.httpShouldSetCookies)
        XCTAssertNil(session.configuration.urlCredentialStorage)
    }

    func testMajorProviderSessionRejectsRedirectsAndSharedCredentialState() {
        let session = MajorProviderHTTP.session()

        XCTAssertTrue(session.delegate is RejectRedirectDelegate)
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertEqual(session.configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertFalse(session.configuration.httpShouldSetCookies)
        XCTAssertNil(session.configuration.urlCredentialStorage)
    }

    func testParsesSecTokenAndRecognizesExpiredSession() throws {
        let valid = Data(#"{"code":"Success","data":{"secToken":"secure-token"}}"#.utf8)
        let expired = Data(#"{"code":"ConsoleNeedLogin"}"#.utf8)

        XCTAssertEqual(try QwenProvider.parseSecToken(valid), "secure-token")
        XCTAssertThrowsError(try QwenProvider.parseSecToken(expired))
    }

    func testExplicitCookieHeaderIsNeverAllowedOverHTTP() throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "home.qwencloud.com",
            .path: "/",
            .name: "session",
            .value: "abc",
        ]))

        XCTAssertTrue(QwenCookieRepository.browserWouldSend(
            cookie: cookie,
            to: URL(string: "https://home.qwencloud.com/tool/user/info.json")!))
        XCTAssertFalse(QwenCookieRepository.browserWouldSend(
            cookie: cookie,
            to: URL(string: "http://home.qwencloud.com/tool/user/info.json")!))
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

private final class QwenStatusURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let status = Int(request.value(forHTTPHeaderField: "Cookie")?.dropFirst("status=".count) ?? "") ?? 500
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
