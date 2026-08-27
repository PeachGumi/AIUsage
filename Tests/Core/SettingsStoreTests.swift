import XCTest
@testable import AIUsage

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testDefaultsAndPersistsMenuBarSelection() {
        let suite = "AIUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = SettingsStore(defaults: defaults)
        XCTAssertEqual(first.selectedProvider, .codex)
        XCTAssertEqual(first.metric, .remaining)

        first.selectedProvider = .qwen
        first.metric = .used

        let restored = SettingsStore(defaults: defaults)
        XCTAssertEqual(restored.selectedProvider, .qwen)
        XCTAssertEqual(restored.metric, .used)
    }
}
