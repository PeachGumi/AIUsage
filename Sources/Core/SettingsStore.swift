import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var selectedProviderInstanceID: UUID? {
        didSet {
            if let selectedProviderInstanceID {
                defaults.set(selectedProviderInstanceID.uuidString, forKey: Keys.selectedInstanceID)
            } else {
                defaults.removeObject(forKey: Keys.selectedInstanceID)
            }
        }
    }

    @Published var metric: UsageMetric {
        didSet { defaults.set(metric.rawValue, forKey: Keys.metric) }
    }

    /// Explicitly registered account/card instances in dashboard order.
    /// ProviderID is no longer the identity of a card: duplicate providers are
    /// valid and each instance owns an independent UUID/account slot.
    @Published private(set) var registeredProviders: [ProviderInstance] {
        didSet { persistInstances() }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedInstances = Self.loadInstances(defaults: defaults)
        let migratedInstances: [ProviderInstance]?
        if storedInstances == nil {
            migratedInstances = Self.legacyProviderIDs(from: defaults)?.map {
                ProviderInstance(provider: $0)
            }
        } else {
            migratedInstances = nil
        }

        registeredProviders = Self.sanitized(storedInstances ?? migratedInstances ?? [])
        metric = UsageMetric(rawValue: defaults.string(forKey: Keys.metric) ?? "") ?? .remaining

        if let rawID = defaults.string(forKey: Keys.selectedInstanceID),
           let savedID = UUID(uuidString: rawID),
           registeredProviders.contains(where: { $0.id == savedID }) {
            selectedProviderInstanceID = savedID
        } else if let legacySelected = ProviderID(rawValue: defaults.string(forKey: Keys.legacySelectedProvider) ?? ""),
                  let match = registeredProviders.first(where: { $0.provider == legacySelected }) {
            selectedProviderInstanceID = match.id
        } else {
            selectedProviderInstanceID = registeredProviders.first?.id
        }

        // Persist the new representation exactly once after migration. An
        // explicitly stored empty new array remains empty and never resurrects
        // old providerOrder/menuBarProvider values.
        if storedInstances == nil, migratedInstances != nil {
            persistInstances()
            if let selectedProviderInstanceID {
                defaults.set(selectedProviderInstanceID.uuidString, forKey: Keys.selectedInstanceID)
            }
        }
    }

    /// Every implemented provider is always addable. Adding the same ProviderID
    /// repeatedly intentionally creates independent account/card instances.
    var addableProviders: [ProviderID] { ProviderID.implemented }

    var selectedProvider: ProviderInstance? {
        guard let selectedProviderInstanceID else { return nil }
        return registeredProviders.first { $0.id == selectedProviderInstanceID }
    }

    @discardableResult
    func addProvider(_ provider: ProviderID) -> ProviderInstance? {
        guard ProviderID.implemented.contains(provider) else { return nil }
        let instance = ProviderInstance(provider: provider)
        registeredProviders.append(instance)
        if selectedProviderInstanceID == nil { selectedProviderInstanceID = instance.id }
        return instance
    }

    func removeProvider(_ instanceID: UUID) {
        guard registeredProviders.contains(where: { $0.id == instanceID }) else { return }
        registeredProviders.removeAll { $0.id == instanceID }
        if selectedProviderInstanceID == instanceID {
            selectedProviderInstanceID = registeredProviders.first?.id
        }
    }

    func renameProvider(_ instanceID: UUID, accountLabel: String?) {
        guard let index = registeredProviders.firstIndex(where: { $0.id == instanceID }) else { return }
        registeredProviders[index] = registeredProviders[index].withAccountLabel(accountLabel)
    }

    func instance(_ id: UUID) -> ProviderInstance? {
        registeredProviders.first { $0.id == id }
    }

    func instances(of provider: ProviderID) -> [ProviderInstance] {
        registeredProviders.filter { $0.provider == provider }
    }

    /// Reorders registered cards for a drag from `from` offsets to `to`
    /// (List/ForEach move semantics).
    func moveProvider(from: IndexSet, to: Int) {
        var providers = registeredProviders
        providers.move(fromOffsets: from, toOffset: to)
        registeredProviders = providers
    }

    /// Moves a dragged provider instance onto the visual position of another
    /// card. `Array.move` uses an insertion offset, so forward moves need +1.
    func moveProvider(fromIndex source: Int, ontoIndex target: Int) {
        guard registeredProviders.indices.contains(source),
              registeredProviders.indices.contains(target),
              source != target else { return }
        let destination = source < target ? target + 1 : target
        moveProvider(from: IndexSet(integer: source), to: destination)
    }

    /// Identity-based variant used while cards continuously move under a drag.
    func moveProvider(_ source: UUID, onto target: UUID) {
        guard let sourceIndex = registeredProviders.firstIndex(where: { $0.id == source }),
              let targetIndex = registeredProviders.firstIndex(where: { $0.id == target }) else { return }
        moveProvider(fromIndex: sourceIndex, ontoIndex: targetIndex)
    }

    private func persistInstances() {
        guard let data = try? JSONEncoder().encode(registeredProviders) else { return }
        defaults.set(data, forKey: Keys.providerInstances)
    }

    private static func loadInstances(defaults: UserDefaults) -> [ProviderInstance]? {
        guard let data = defaults.data(forKey: Keys.providerInstances) else { return nil }
        // A corrupt new-format value is treated as an explicit empty value,
        // never as permission to resurrect potentially stale legacy accounts.
        return (try? JSONDecoder().decode([ProviderInstance].self, from: data)) ?? []
    }

    /// Keep implemented types and unique instance UUIDs. Duplicate ProviderIDs
    /// are deliberately preserved because they represent different accounts.
    private static func sanitized(_ instances: [ProviderInstance]) -> [ProviderInstance] {
        let implemented = Set(ProviderID.implemented)
        var seen = Set<UUID>()
        return instances.filter { implemented.contains($0.provider) && seen.insert($0.id).inserted }
    }

    /// Migration chain for builds that represented one card by ProviderID.
    /// Prefer the latest registeredProviders key, then the older providerOrder,
    /// then the old menuBarProvider selection as evidence of prior registration.
    private static func legacyProviderIDs(from defaults: UserDefaults) -> [ProviderID]? {
        if let registrations = defaults.stringArray(forKey: Keys.legacyRegisteredProviders) {
            return Self.sanitizedLegacyIDs(registrations)
        }
        if let order = defaults.stringArray(forKey: Keys.legacyProviderOrder), !order.isEmpty {
            return Self.sanitizedLegacyIDs(order)
        }
        if let selected = defaults.string(forKey: Keys.legacySelectedProvider),
           let provider = ProviderID(rawValue: selected),
           ProviderID.implemented.contains(provider) {
            return [provider]
        }
        return nil
    }

    private static func sanitizedLegacyIDs(_ rawValues: [String]) -> [ProviderID] {
        let implemented = Set(ProviderID.implemented)
        let valid = rawValues.compactMap(ProviderID.init(rawValue:)).filter(implemented.contains)
        var seen = Set<ProviderID>()
        return valid.filter { seen.insert($0).inserted }
    }

    private enum Keys {
        static let selectedInstanceID = "menuBarProviderInstanceID"
        static let metric = "usageMetric"
        static let providerInstances = "providerInstances.v1"

        // Legacy single-instance-per-provider keys.
        static let legacyRegisteredProviders = "registeredProviders"
        static let legacyProviderOrder = "providerOrder"
        static let legacySelectedProvider = "menuBarProvider"
    }
}
