import XCTest
import AppKit
@testable import AIUsage

final class LoginWindowLifecycleTests: XCTestCase {
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
