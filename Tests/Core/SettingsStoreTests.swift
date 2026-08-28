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

    func testLegacyProviderOrderMigratesOnlyWhenNewRegistrationKeyIsMissing() {
        let suite = "AIUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["qwen", "codex", "openCodeGo"], forKey: "providerOrder")
        defaults.set("codex", forKey: "menuBarProvider")

        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.registeredProviders, [.qwen, .codex, .openCodeGo])
        XCTAssertEqual(store.selectedProvider, .codex)
        XCTAssertEqual(defaults.stringArray(forKey: "registeredProviders"), ["qwen", "codex", "openCodeGo"])
    }

    func testLegacySelectedProviderMigratesWhenNoLegacyOrderExists() {
        let suite = "AIUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("qwen", forKey: "menuBarProvider")

        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.registeredProviders, [.qwen])
        XCTAssertEqual(store.selectedProvider, .qwen)
    }

    func testExplicitEmptyRegistrationDoesNotResurrectLegacyProviders() {
        let suite = "AIUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([], forKey: "registeredProviders")
        defaults.set(["qwen", "codex", "openCodeGo"], forKey: "providerOrder")
        defaults.set("codex", forKey: "menuBarProvider")

        let store = SettingsStore(defaults: defaults)

        XCTAssertTrue(store.registeredProviders.isEmpty)
        XCTAssertNil(store.selectedProvider)
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

    func testDragLayoutUsesHysteresisAroundAdjacentSlotCenters() {
        let slots = [
            CGRect(x: 0, y: 0, width: 400, height: 100),
            CGRect(x: 0, y: 112, width: 400, height: 100),
            CGRect(x: 0, y: 224, width: 400, height: 100)
        ]

        XCTAssertEqual(
            ProviderDragLayout.nextIndex(draggedCenterY: 111, currentIndex: 0, slots: slots, hysteresis: 6),
            0)
        XCTAssertEqual(
            ProviderDragLayout.nextIndex(draggedCenterY: 113, currentIndex: 0, slots: slots, hysteresis: 6),
            1)
        XCTAssertEqual(
            ProviderDragLayout.nextIndex(draggedCenterY: 101, currentIndex: 1, slots: slots, hysteresis: 6),
            1)
        XCTAssertEqual(
            ProviderDragLayout.nextIndex(draggedCenterY: 99, currentIndex: 1, slots: slots, hysteresis: 6),
            0)
    }

    func testDragLayoutLocksCardTranslationToVerticalAxis() {
        XCTAssertEqual(
            ProviderDragLayout.verticalTranslation(CGSize(width: 91, height: -37)),
            CGSize(width: 0, height: -37))
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
        XCTAssertEqual(
            Set(ProviderID.implemented),
            Set([.openCodeGo, .codex, .qwen, .claude, .antigravity, .copilot, .cursor, .zai, .kimi]))
    }
}
