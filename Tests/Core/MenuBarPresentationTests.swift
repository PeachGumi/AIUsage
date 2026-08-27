import XCTest
@testable import AIUsage

final class MenuBarPresentationTests: XCTestCase {
    func testRendersAllWindowsForSelectedProviderUsingRemainingValues() throws {
        let snapshot = ProviderSnapshot(
            provider: .openCodeGo,
            planName: "OpenCode Go",
            windows: [
                try UsageWindow(kind: .fiveHour, label: "5-hour", usedPercent: 0.2, resetsAt: nil, resetDescription: nil),
                try UsageWindow(kind: .weekly, label: "Weekly", usedPercent: 0.1, resetsAt: nil, resetDescription: nil),
                try UsageWindow(kind: .monthly, label: "Monthly", usedPercent: 32.1, resetsAt: nil, resetDescription: nil),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1))

        XCTAssertEqual(
            MenuBarPresentation.title(snapshot: snapshot, metric: .remaining),
            "GO 5h:99.8% / W:99.9% / M:67.9%")
    }

    func testRendersUsedValuesWhenConfigured() throws {
        let snapshot = ProviderSnapshot(
            provider: .codex,
            planName: "Plus",
            windows: [try UsageWindow(kind: .fiveHour, label: "5-hour", usedPercent: 82, resetsAt: nil, resetDescription: nil)],
            fetchedAt: Date())

        XCTAssertEqual(MenuBarPresentation.title(snapshot: snapshot, metric: .used), "CX 5h:82%")
    }
}
