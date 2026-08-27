import XCTest
@testable import AIUsage

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testFreshInstallStartsWithNoRegisteredProviders() {
        let suite = "AIUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)

        XCTAssertTrue(store.registeredProviders.isEmpty)
        XCTAssertNil(store.selectedProvider)
        XCTAssertEqual(store.metric, .remaining)
        XCTAssertEqual(Set(store.addableProviders), Set(ProviderID.implemented))
    }

    func testAddingProvidersSelectsFirstAndPersistsRegistrationOrder() {
        let suite = "AIUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = SettingsStore(defaults: defaults)
        first.addProvider(.qwen)
        first.addProvider(.codex)
        first.metric = .used

        XCTAssertEqual(first.registeredProviders, [.qwen, .codex])
        XCTAssertEqual(first.selectedProvider, .qwen)
        XCTAssertFalse(first.addableProviders.contains(.qwen))

        first.moveProvider(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(first.registeredProviders, [.codex, .qwen])

        let restored = SettingsStore(defaults: defaults)
        XCTAssertEqual(restored.registeredProviders, [.codex, .qwen])
        XCTAssertEqual(restored.selectedProvider, .qwen)
        XCTAssertEqual(restored.metric, .used)
    }

    func testDroppingEarlierProviderOnLaterCardPlacesItAtThatCardPosition() {
        let suite = "AIUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.addProvider(.openCodeGo)
        store.addProvider(.qwen)
        store.addProvider(.codex)

        store.moveProvider(fromIndex: 0, ontoIndex: 2)

        XCTAssertEqual(store.registeredProviders, [.qwen, .codex, .openCodeGo])
    }

    func testDroppingLaterProviderOnEarlierCardPlacesItAtThatCardPosition() {
        let suite = "AIUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.addProvider(.openCodeGo)
        store.addProvider(.qwen)
        store.addProvider(.codex)

        store.moveProvider(fromIndex: 2, ontoIndex: 0)

        XCTAssertEqual(store.registeredProviders, [.codex, .openCodeGo, .qwen])
    }

    func testSuccessiveDragHoverMovesFollowProviderIdentity() {
        let suite = "AIUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.addProvider(.openCodeGo)
        store.addProvider(.qwen)
        store.addProvider(.codex)

        store.moveProvider(.openCodeGo, onto: .qwen)
        XCTAssertEqual(store.registeredProviders, [.qwen, .openCodeGo, .codex])

        store.moveProvider(.openCodeGo, onto: .codex)
        XCTAssertEqual(store.registeredProviders, [.qwen, .codex, .openCodeGo])
    }

    func testRemovingSelectedProviderFallsBackThenBecomesEmpty() {
        let suite = "AIUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        store.addProvider(.openCodeGo)
        store.addProvider(.codex)
        store.selectedProvider = .codex

        store.removeProvider(.codex)
        XCTAssertEqual(store.registeredProviders, [.openCodeGo])
        XCTAssertEqual(store.selectedProvider, .openCodeGo)

        store.removeProvider(.openCodeGo)
        XCTAssertTrue(store.registeredProviders.isEmpty)
        XCTAssertNil(store.selectedProvider)
    }

    func testRegistrationSanitizesInvalidAndDuplicateEntries() {
        let suite = "AIUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["qwen", "bogus", "qwen"], forKey: "registeredProviders")
        defaults.set("codex", forKey: "menuBarProvider")

        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.registeredProviders, [.qwen])
        XCTAssertEqual(store.selectedProvider, .qwen)
    }

    func testRequiredProvidersAreImplemented() {
        XCTAssertEqual(Set(ProviderID.implemented), Set([.openCodeGo, .codex, .qwen]))
    }
}
