import XCTest
@testable import AIUsage

final class LoginSuccessRulesTests: XCTestCase {
    func testOpenCodeRequiresConsoleOrWorkspacePageOnExpectedHost() {
        XCTAssertTrue(LoginSuccessRules.isSuccess(
            provider: .openCodeGo,
            url: URL(string: "https://opencode.ai/workspace/wrk_example/go")!))
        XCTAssertTrue(LoginSuccessRules.isSuccess(
            provider: .openCodeGo,
            url: URL(string: "https://opencode.ai/console/")!))
        XCTAssertFalse(LoginSuccessRules.isSuccess(
            provider: .openCodeGo,
            url: URL(string: "https://opencode.ai/")!))
        XCTAssertFalse(LoginSuccessRules.isSuccess(
            provider: .openCodeGo,
            url: URL(string: "https://auth.opencode.ai/auth")!))
        XCTAssertFalse(LoginSuccessRules.isSuccess(
            provider: .openCodeGo,
            url: URL(string: "http://opencode.ai/console/")!))
    }

    func testQwenRequiresBillingPageOnExpectedHost() {
        XCTAssertTrue(LoginSuccessRules.isSuccess(
            provider: .qwen,
            url: URL(string: "https://home.qwencloud.com/billing/subscription/token-plan-individual")!))
        XCTAssertFalse(LoginSuccessRules.isSuccess(
            provider: .qwen,
            url: URL(string: "https://home.qwencloud.com/")!))
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

    func testPopoverExpandsUntilItWouldExceedScreen() {
        XCTAssertEqual(
            StatusItemController.preferredPopoverHeight(providerCount: 0, screenHeight: 1080),
            280)
        XCTAssertEqual(
            StatusItemController.preferredPopoverHeight(providerCount: 3, screenHeight: 1080),
            688)
        XCTAssertEqual(
            StatusItemController.preferredPopoverHeight(providerCount: 4, screenHeight: 1080),
            878)
        XCTAssertEqual(
            StatusItemController.preferredPopoverHeight(providerCount: 5, screenHeight: 1080),
            1056)
    }
}
