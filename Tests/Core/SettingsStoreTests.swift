import XCTest
import Foundation
@testable import AIUsage

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testFreshInstallStartsWithNoRegisteredAccounts() {
        withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            XCTAssertTrue(store.registeredProviders.isEmpty)
            XCTAssertNil(store.selectedProviderInstanceID)
            XCTAssertEqual(store.metric, .remaining)
            XCTAssertEqual(Set(store.addableProviders), Set(ProviderID.implemented))
        }
    }

    func testSameProviderCanBeAddedUnlimitedTimesWithUniqueIdentity() {
        withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            let first = store.addProvider(.codex)!
            let second = store.addProvider(.codex)!
            let third = store.addProvider(.codex)!

            XCTAssertEqual(store.registeredProviders.map(\.provider), [.codex, .codex, .codex])
            XCTAssertEqual(Set(store.registeredProviders.map(\.id)).count, 3)
            XCTAssertEqual(first.id, ProviderInstance.legacyID(for: .codex))
            XCTAssertNotEqual(second.id, first.id)
            XCTAssertNotEqual(third.id, first.id)
            XCTAssertEqual(store.instance(first.id)?.accountLabel, "Account 1")
            XCTAssertEqual(store.instance(second.id)?.accountLabel, "Account 2")
            XCTAssertEqual(store.instance(third.id)?.accountLabel, "Account 3")
            XCTAssertTrue(store.addableProviders.contains(.codex))
        }
    }

    func testFirstFreshAccountUsesStableDefaultSlot() {
        withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            for provider in ProviderID.implemented where provider != .antigravity {
                let instance = store.addProvider(provider)!
                XCTAssertEqual(instance.id, ProviderInstance.legacyID(for: provider))
            }
        }
    }

    func testReAddingProviderRestoresStableDefaultSlotWhileSiblingRemains() {
        withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            let defaultAccount = store.addProvider(.codex)!
            let explicitAccount = store.addProvider(.codex)!

            store.removeProvider(defaultAccount.id)
            XCTAssertEqual(store.instances(of: .codex).map(\.id), [explicitAccount.id])

            let restored = store.addProvider(.codex)!
            XCTAssertEqual(restored.id, ProviderInstance.legacyID(for: .codex))
            XCTAssertNotEqual(restored.id, explicitAccount.id)
            XCTAssertEqual(store.instance(restored.id)?.accountLabel, "Account 1")
            XCTAssertEqual(store.instance(explicitAccount.id)?.accountLabel, "Account 2")
        }
    }

    func testAntigravityIsLimitedToOneOfficialLocalSession() {
        withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            let first = store.addProvider(.antigravity)

            XCTAssertEqual(first?.id, ProviderInstance.legacyID(for: .antigravity))
            XCTAssertFalse(store.addableProviders.contains(.antigravity))
            XCTAssertNil(store.addProvider(.antigravity))
            XCTAssertEqual(store.instances(of: .antigravity).count, 1)
        }
    }

    func testPersistedNonDefaultAntigravityInstanceIsSanitizedOut() throws {
        try withDefaultsThrowing { defaults in
            let instances = [
                ProviderInstance(id: ProviderInstance.legacyID(for: .antigravity), provider: .antigravity),
                ProviderInstance(provider: .antigravity, accountLabel: "Old OAuth experiment"),
            ]
            defaults.set(try JSONEncoder().encode(instances), forKey: "providerInstances.v1")

            let store = SettingsStore(defaults: defaults)
            XCTAssertEqual(store.instances(of: .antigravity).count, 1)
            XCTAssertEqual(store.instances(of: .antigravity).first?.id, ProviderInstance.legacyID(for: .antigravity))
        }
    }

    func testAddingDuplicateAfterRemovalReusesFreeAutomaticLabelWithoutCollision() {
        withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            let first = store.addProvider(.codex)!
            let second = store.addProvider(.codex)!
            _ = store.addProvider(.codex)!

            store.removeProvider(first.id)
            let replacement = store.addProvider(.codex)!

            XCTAssertEqual(store.instance(second.id)?.accountLabel, "Account 2")
            XCTAssertEqual(store.instance(replacement.id)?.accountLabel, "Account 1")
            let labels = store.instances(of: .codex).compactMap(\.accountLabel)
            XCTAssertEqual(Set(labels).count, labels.count)
        }
    }

    func testAutomaticLabelAllocationRespectsUserEnteredAccountNumber() {
        withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            let first = store.addProvider(.cursor)!
            store.renameProvider(first.id, accountLabel: "Account 2")

            let second = store.addProvider(.cursor)!
            XCTAssertEqual(store.instance(first.id)?.accountLabel, "Account 2")
            XCTAssertEqual(store.instance(second.id)?.accountLabel, "Account 1")
        }
    }

    func testDuplicateAccountsPersistWithSelectionOrderAndLabels() {
        withDefaults { defaults in
            let firstStore = SettingsStore(defaults: defaults)
            let first = firstStore.addProvider(.qwen)!
            let second = firstStore.addProvider(.qwen)!
            firstStore.renameProvider(second.id, accountLabel: "Work")
            firstStore.selectedProviderInstanceID = second.id
            firstStore.metric = .used
            firstStore.moveProvider(second.id, onto: first.id)

            let restored = SettingsStore(defaults: defaults)
            XCTAssertEqual(restored.registeredProviders.map(\.id), [second.id, first.id])
            XCTAssertEqual(restored.registeredProviders.map(\.provider), [.qwen, .qwen])
            XCTAssertEqual(restored.instance(second.id)?.accountLabel, "Work")
            XCTAssertEqual(restored.selectedProviderInstanceID, second.id)
            XCTAssertEqual(restored.metric, .used)
        }
    }

    func testPersistedSoleDefaultAccountDropsStaleAutomaticLabel() throws {
        try withDefaultsThrowing { defaults in
            let instance = ProviderInstance(
                id: ProviderInstance.legacyID(for: .codex),
                provider: .codex,
                accountLabel: "Account 1")
            defaults.set(try JSONEncoder().encode([instance]), forKey: "providerInstances.v1")

            let store = SettingsStore(defaults: defaults)

            XCTAssertNil(store.instance(instance.id)?.accountLabel)
        }
    }

    func testRemovingOneDuplicateLeavesSiblingAccountAndSelection() {
        withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            let first = store.addProvider(.openCodeGo)!
            let second = store.addProvider(.openCodeGo)!
            store.selectedProviderInstanceID = second.id

            store.removeProvider(second.id)
            XCTAssertEqual(store.registeredProviders.map(\.id), [first.id])
            XCTAssertNil(store.instance(first.id)?.accountLabel)
            XCTAssertEqual(store.selectedProviderInstanceID, first.id)

            store.removeProvider(first.id)
            XCTAssertTrue(store.registeredProviders.isEmpty)
            XCTAssertNil(store.selectedProviderInstanceID)
        }
    }

    func testDragIdentityWorksAcrossDuplicateProviderTypes() {
        withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            let a = store.addProvider(.codex)!
            let b = store.addProvider(.codex)!
            let c = store.addProvider(.qwen)!

            store.moveProvider(a.id, onto: b.id)
            XCTAssertEqual(store.registeredProviders.map(\.id), [b.id, a.id, c.id])

            store.moveProvider(a.id, onto: c.id)
            XCTAssertEqual(store.registeredProviders.map(\.id), [b.id, c.id, a.id])
        }
    }

    func testLegacyRegisteredProvidersMigrateToStableInstances() {
        withDefaults { defaults in
            defaults.set(["qwen", "codex", "qwen", "bogus"], forKey: "registeredProviders")
            defaults.set("codex", forKey: "menuBarProvider")

            let store = SettingsStore(defaults: defaults)

            XCTAssertEqual(store.registeredProviders.map(\.provider), [.qwen, .codex])
            XCTAssertEqual(store.registeredProviders[0].id, ProviderInstance.legacyID(for: .qwen))
            XCTAssertEqual(store.registeredProviders[1].id, ProviderInstance.legacyID(for: .codex))
            XCTAssertEqual(store.selectedProviderInstanceID, ProviderInstance.legacyID(for: .codex))
            XCTAssertNotNil(defaults.data(forKey: "providerInstances.v1"))
        }
    }

    func testLegacyProviderOrderAndSelectedProviderMigrateWhenRegistrationKeyMissing() {
        withDefaults { defaults in
            defaults.set(["qwen", "codex", "openCodeGo"], forKey: "providerOrder")
            defaults.set("openCodeGo", forKey: "menuBarProvider")

            let store = SettingsStore(defaults: defaults)

            XCTAssertEqual(store.registeredProviders.map(\.provider), [.qwen, .codex, .openCodeGo])
            XCTAssertEqual(store.selectedProviderInstanceID, ProviderInstance.legacyID(for: .openCodeGo))
        }
    }

    func testExplicitNewFormatEmptyDoesNotResurrectLegacyProviders() throws {
        try withDefaultsThrowing { defaults in
            defaults.set(try JSONEncoder().encode([ProviderInstance]()), forKey: "providerInstances.v1")
            defaults.set(["qwen", "codex"], forKey: "registeredProviders")
            defaults.set("codex", forKey: "menuBarProvider")

            let store = SettingsStore(defaults: defaults)
            XCTAssertTrue(store.registeredProviders.isEmpty)
            XCTAssertNil(store.selectedProviderInstanceID)
        }
    }

    func testCorruptNewFormatDoesNotResurrectLegacyProviders() {
        withDefaults { defaults in
            defaults.set(Data("not-json".utf8), forKey: "providerInstances.v1")
            defaults.set(["qwen", "codex"], forKey: "registeredProviders")

            let store = SettingsStore(defaults: defaults)
            XCTAssertTrue(store.registeredProviders.isEmpty)
        }
    }

    func testLossyNewFormatKeepsValidInstancesWhenOneEntryIsInvalid() throws {
        try withDefaultsThrowing { defaults in
            let validID = UUID()
            let invalidID = UUID()
            let malformedID = UUID()
            let records: [[String: Any]] = [
                [
                    "id": validID.uuidString,
                    "provider": "codex",
                    "accountLabel": "Work",
                ],
                [
                    "id": invalidID.uuidString,
                    "provider": "futureProvider",
                    "accountLabel": "Unknown",
                ],
                [
                    "id": malformedID.uuidString,
                    "provider": "qwen",
                    "accountLabel": 42,
                ],
            ]
            defaults.set(
                try JSONSerialization.data(withJSONObject: records),
                forKey: "providerInstances.v1")
            defaults.set(["qwen"], forKey: "registeredProviders")

            let store = SettingsStore(defaults: defaults)

            XCTAssertEqual(store.registeredProviders.map(\.id), [validID])
            XCTAssertEqual(store.instance(validID)?.accountLabel, "Work")
        }
    }

    func testDecodedAccountLabelsUseTheSameNormalizationAsNewInstances() throws {
        try withDefaultsThrowing { defaults in
            let id = UUID()
            let rawLabel = "  \(String(repeating: "x", count: 90))  "
            let record: [[String: Any]] = [[
                "id": id.uuidString,
                "provider": "codex",
                "accountLabel": rawLabel,
            ]]
            defaults.set(
                try JSONSerialization.data(withJSONObject: record),
                forKey: "providerInstances.v1")

            let store = SettingsStore(defaults: defaults)

            XCTAssertEqual(store.instance(id)?.accountLabel, String(repeating: "x", count: 80))
        }
    }

    func testDuplicateUUIDIsSanitizedButDuplicateProviderIDIsPreserved() throws {
        try withDefaultsThrowing { defaults in
            let id = UUID()
            let instances = [
                ProviderInstance(id: id, provider: .qwen, accountLabel: "First"),
                ProviderInstance(id: id, provider: .qwen, accountLabel: "Duplicate identity"),
                ProviderInstance(provider: .qwen, accountLabel: "Different account")
            ]
            defaults.set(try JSONEncoder().encode(instances), forKey: "providerInstances.v1")

            let store = SettingsStore(defaults: defaults)
            XCTAssertEqual(store.registeredProviders.count, 2)
            XCTAssertEqual(store.registeredProviders.map(\.provider), [.qwen, .qwen])
            XCTAssertEqual(Set(store.registeredProviders.map(\.id)).count, 2)
        }
    }

    func testDragLayoutUsesHysteresisAroundAdjacentSlotCenters() {
        let slots = [
            CGRect(x: 0, y: 0, width: 400, height: 100),
            CGRect(x: 0, y: 112, width: 400, height: 100),
            CGRect(x: 0, y: 224, width: 400, height: 100)
        ]

        XCTAssertEqual(ProviderDragLayout.nextIndex(draggedCenterY: 111, currentIndex: 0, slots: slots, hysteresis: 6), 0)
        XCTAssertEqual(ProviderDragLayout.nextIndex(draggedCenterY: 113, currentIndex: 0, slots: slots, hysteresis: 6), 1)
        XCTAssertEqual(ProviderDragLayout.nextIndex(draggedCenterY: 101, currentIndex: 1, slots: slots, hysteresis: 6), 1)
        XCTAssertEqual(ProviderDragLayout.nextIndex(draggedCenterY: 99, currentIndex: 1, slots: slots, hysteresis: 6), 0)
    }

    func testDragLayoutLocksCardTranslationToVerticalAxis() {
        XCTAssertEqual(
            ProviderDragLayout.verticalTranslation(CGSize(width: 91, height: -37)),
            CGSize(width: 0, height: -37))
    }

    func testRequiredProvidersAreImplemented() {
        XCTAssertEqual(
            Set(ProviderID.implemented),
            Set([.openCodeGo, .codex, .qwen, .claude, .antigravity, .copilot, .cursor, .zai, .kimi]))
    }

    func testOnlyValidatedProvidersAreNonExperimental() {
        XCTAssertEqual(Set(ProviderID.implemented.filter { !$0.isExperimental }), ProviderID.validatedProviders)
        XCTAssertEqual(
            Set(ProviderID.implemented.filter(\.isExperimental)),
            Set([.qwen, .claude, .cursor, .zai, .kimi]))
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "AIUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    private func withDefaultsThrowing(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "AIUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
