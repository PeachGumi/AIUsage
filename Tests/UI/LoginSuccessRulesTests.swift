import XCTest
import AppKit
import Combine
@testable import AIUsage

final class LoginSuccessRulesTests: XCTestCase {
    @MainActor
    func testAutomaticRefreshReceivesWakeFromWorkspaceAndActivationFromApplication() {
        var received: [Notification.Name] = []
        let subscription = AppDelegate.refreshNotifications.sink { received.append($0.name) }
        defer { subscription.cancel() }

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        XCTAssertEqual(received, [NSWorkspace.didWakeNotification, NSApplication.didBecomeActiveNotification])
    }
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

    func testPopoverUsesMeasuredContentUntilItWouldExceedScreen() {
        XCTAssertEqual(
            StatusItemController.preferredPopoverHeight(
                providerCount: 0,
                measuredProviderListHeight: 0,
                screenHeight: 1080),
            280)
        XCTAssertEqual(
            StatusItemController.preferredPopoverHeight(
                providerCount: 2,
                measuredProviderListHeight: 640,
                screenHeight: 1080),
            758)
        XCTAssertEqual(
            StatusItemController.preferredPopoverHeight(
                providerCount: 3,
                measuredProviderListHeight: 1_200,
                screenHeight: 1080),
            1056)
    }

    func testPopoverUsesSafeCardEstimateBeforeMeasurementArrives() {
        XCTAssertEqual(
            StatusItemController.preferredPopoverHeight(
                providerCount: 2,
                measuredProviderListHeight: 0,
                screenHeight: 1080),
            778)
    }

    func testPopoverAnchorsToStableRightEdgeOfStatusItem() {
        XCTAssertEqual(
            StatusItemController.popoverAnchorRect(
                buttonBounds: CGRect(x: 0, y: 0, width: 120, height: 22)),
            CGRect(x: 119, y: 0, width: 1, height: 22))
    }
}
