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
                ProviderInstance(id: ProviderInstance.legacyID(for: $0), provider: $0)
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

        if storedInstances == nil, migratedInstances != nil {
            persistInstances()
            if let selectedProviderInstanceID {
                defaults.set(selectedProviderInstanceID.uuidString, forKey: Keys.selectedInstanceID)
            }
        }
    }

    /// Most provider integrations support a stable default/ambient account plus
    /// explicitly configured duplicate accounts. Antigravity is intentionally
    /// limited to one local official session until its documented status-line
    /// interface is wired up for safe multi-account ingestion.
    var addableProviders: [ProviderID] {
        ProviderID.implemented.filter { provider in
            provider != .antigravity || !registeredProviders.contains(where: { $0.provider == .antigravity })
        }
    }

    var selectedProvider: ProviderInstance? {
        guard let selectedProviderInstanceID else { return nil }
        return registeredProviders.first { $0.id == selectedProviderInstanceID }
    }

    @discardableResult
    func addProvider(_ provider: ProviderID) -> ProviderInstance? {
        guard addableProviders.contains(provider) else { return nil }
        let matching = registeredProviders.indices.filter { registeredProviders[$0].provider == provider }

        // Keep a single account visually clean. As soon as a second account is
        // added, give the original a deterministic local label so two identical
        // provider names are immediately distinguishable.
        if matching.count == 1,
           let first = matching.first,
           registeredProviders[first].accountLabel == nil {
            registeredProviders[first] = registeredProviders[first].withAccountLabel("Account 1")
        }

        let label: String?
        if matching.isEmpty {
            label = nil
        } else {
            // Count-based numbering can collide after a card is removed. Reuse
            // the lowest free automatic ordinal instead, while respecting both
            // generated labels and a user-entered label such as "Account 2".
            let usedOrdinals = Set(
                registeredProviders
                    .filter { $0.provider == provider }
                    .compactMap { Self.automaticAccountOrdinal($0.accountLabel) })
            var ordinal = 1
            while usedOrdinals.contains(ordinal) { ordinal += 1 }
            label = "Account \(ordinal)"
        }

        // The first card is a stable default slot. This preserves old migration
        // identities and lets AppDelegate permit ambient client credentials only
        // for that one slot. Additional cards always receive independent UUIDs.
        let id = matching.isEmpty ? ProviderInstance.legacyID(for: provider) : UUID()
        let instance = ProviderInstance(id: id, provider: provider, accountLabel: label)
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

    func moveProvider(from: IndexSet, to: Int) {
        var providers = registeredProviders
        providers.move(fromOffsets: from, toOffset: to)
        registeredProviders = providers
    }

    func moveProvider(fromIndex source: Int, ontoIndex target: Int) {
        guard registeredProviders.indices.contains(source),
              registeredProviders.indices.contains(target),
              source != target else { return }
        let destination = source < target ? target + 1 : target
        moveProvider(from: IndexSet(integer: source), to: destination)
    }

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
        return (try? JSONDecoder().decode([ProviderInstance].self, from: data)) ?? []
    }

    private static func sanitized(_ instances: [ProviderInstance]) -> [ProviderInstance] {
        let implemented = Set(ProviderID.implemented)
        var seen = Set<UUID>()
        var keptAntigravity = false
        return instances.filter { instance in
            guard implemented.contains(instance.provider), seen.insert(instance.id).inserted else { return false }
            if instance.provider == .antigravity {
                guard !keptAntigravity,
                      instance.id == ProviderInstance.legacyID(for: .antigravity) else { return false }
                keptAntigravity = true
            }
            return true
        }
    }

    private static func automaticAccountOrdinal(_ label: String?) -> Int? {
        guard let label,
              label.hasPrefix("Account "),
              let ordinal = Int(label.dropFirst("Account ".count)),
              ordinal > 0,
              label == "Account \(ordinal)" else { return nil }
        return ordinal
    }

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
        static let legacyRegisteredProviders = "registeredProviders"
        static let legacyProviderOrder = "providerOrder"
        static let legacySelectedProvider = "menuBarProvider"
    }
}
