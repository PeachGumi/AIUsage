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

    func testProviderOrderDefaultsToEnumOrderAndPersistsAcrossInstances() {
        let suite = "AIUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.providerOrder, ProviderID.allCases)

        store.moveProvider(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(store.providerOrder.first, ProviderID.allCases[2])

        let restored = SettingsStore(defaults: defaults)
        XCTAssertEqual(restored.providerOrder, store.providerOrder)
    }

    func testProviderOrderSanitizesInvalidAndMissingEntries() {
        let suite = "AIUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["qwen", "bogus", "qwen"], forKey: "providerOrder")

        let store = SettingsStore(defaults: defaults)
        // Invalid entries dropped, duplicates removed, missing providers appended.
        XCTAssertEqual(store.providerOrder, [.qwen, .openCodeGo, .codex])
    }
}
