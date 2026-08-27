import XCTest
@testable import AIUsage

final class QwenCookieRepositoryTests: XCTestCase {
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
