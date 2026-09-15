import XCTest
import AppKit
@testable import AIUsage

final class LoginWindowLifecycleTests: XCTestCase {
    @MainActor
    private func controller() -> WebLoginWindowController {
        WebLoginWindowController(
            provider: .openCodeGo,
            startURL: URL(string: "https://opencode.ai/auth")!,
            dataStore: .nonPersistent(),
            onSuccess: { _ in })
    }

    @MainActor
    func testOpenCodeSignInAllowsTheGitHubOAuthChain() {
        let policy = controller()

        // The sign-in round trip: opencode.ai/auth → auth.opencode.ai (OpenAuth)
        // → github.com (OAuth consent and login) → back to auth.opencode.ai.
        XCTAssertEqual(policy.navigationPolicy(for: URL(string: "https://opencode.ai/auth")!), .allow)
        XCTAssertEqual(policy.navigationPolicy(for: URL(string: "https://auth.opencode.ai/github/authorize")!), .allow)
        XCTAssertEqual(
            policy.navigationPolicy(for: URL(string: "https://github.com/login/oauth/authorize?client_id=app")!),
            .allow)
        XCTAssertEqual(policy.navigationPolicy(for: URL(string: "https://github.com/login")!), .allow)
        XCTAssertEqual(
            policy.navigationPolicy(for: URL(string: "https://github.githubassets.com/assets/login.js")!),
            .allow)
    }

    @MainActor
    func testOpenCodeSignInStillCancelsForeignHosts() {
        let policy = controller()

        XCTAssertEqual(policy.navigationPolicy(for: URL(string: "https://evil.example/login")!), .cancel)
        XCTAssertEqual(policy.navigationPolicy(for: URL(string: "https://github.com.evil.example/login")!), .cancel)
        XCTAssertEqual(policy.navigationPolicy(for: URL(string: "http://github.com/login")!), .cancel)
    }

    @MainActor
    func testLoginWindowIsNotAlsoReleasedByAppKit() {
        // AppKit releases programmatically created windows on close when
        // isReleasedWhenClosed is true. The controller keeps its own reference,
        // so the extra release over-releases the window and crashes the app
        // right after the user closes the sign-in window.
        let window = WebLoginWindowController.makeWindow(
            contentView: NSView(frame: NSRect(x: 0, y: 0, width: 980, height: 760)))

        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertNotNil(window.contentView)
    }
}
