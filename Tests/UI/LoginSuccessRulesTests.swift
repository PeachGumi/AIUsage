import XCTest
@testable import AIUsage

final class LoginSuccessRulesTests: XCTestCase {
    func testOpenCodeRequiresWorkspacePageOnExpectedHost() {
        XCTAssertTrue(LoginSuccessRules.isSuccess(
            provider: .openCodeGo,
            url: URL(string: "https://opencode.ai/workspace/wrk_example/go")!))
        XCTAssertFalse(LoginSuccessRules.isSuccess(
            provider: .openCodeGo,
            url: URL(string: "https://auth.opencode.ai/auth")!))
    }

    func testQwenRejectsLoginAndPassportPages() {
        XCTAssertTrue(LoginSuccessRules.isSuccess(
            provider: .qwen,
            url: URL(string: "https://home.qwencloud.com/billing/subscription/token-plan-individual")!))
        XCTAssertFalse(LoginSuccessRules.isSuccess(
            provider: .qwen,
            url: URL(string: "https://home.qwencloud.com/login")!))
        XCTAssertFalse(LoginSuccessRules.isSuccess(
            provider: .qwen,
            url: URL(string: "https://passport.qwencloud.com/signin")!))
    }

    func testWebsiteDataCleanupMatchesOnlyDomainAndSubdomains() {
        XCTAssertTrue(AppDelegate.websiteDataRecordName("qwencloud.com", matches: "qwencloud.com"))
        XCTAssertTrue(AppDelegate.websiteDataRecordName("home.qwencloud.com", matches: "qwencloud.com"))
        XCTAssertTrue(AppDelegate.websiteDataRecordName(".home.qwencloud.com", matches: ".qwencloud.com"))

        XCTAssertFalse(AppDelegate.websiteDataRecordName("fakeqwencloud.com", matches: "qwencloud.com"))
        XCTAssertFalse(AppDelegate.websiteDataRecordName("qwencloud.com.evil.example", matches: "qwencloud.com"))
        XCTAssertFalse(AppDelegate.websiteDataRecordName("notopencode.ai", matches: "opencode.ai"))
    }
}
