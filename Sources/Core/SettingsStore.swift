import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var selectedProviderInstanceID: UUID? {
        didSet { persistSelection() }
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

        let stored = Self.loadInstances(defaults: defaults)
        let migrated = stored == nil ? Self.migratedInstances(defaults: defaults) : nil
        registeredProviders = Self.sanitized(stored ?? migrated ?? [])
        metric = UsageMetric(rawValue: defaults.string(forKey: Keys.metric) ?? "") ?? .remaining
        selectedProviderInstanceID = Self.initialSelection(
            defaults: defaults,
            instances: registeredProviders)

        if stored == nil, migrated != nil {
            persistInstances()
            persistSelection()
        } else if let stored, registeredProviders != stored {
            persistInstances()
        }
    }

    var addableProviders: [ProviderID] {
        ProviderID.implemented.filter { provider in
            provider.supportsMultipleAccounts || instances(of: provider).isEmpty
        }
    }

    var selectedProvider: ProviderInstance? {
        selectedProviderInstanceID.flatMap(instance)
    }

    @discardableResult
    func addProvider(_ provider: ProviderID) -> ProviderInstance? {
        guard addableProviders.contains(provider) else { return nil }

        labelExistingSingleAccountIfNeeded(provider)
        let instance = ProviderInstance(
            id: nextInstanceID(for: provider),
            provider: provider,
            accountLabel: nextAccountLabel(for: provider))
        registeredProviders.append(instance)
        selectedProviderInstanceID = selectedProviderInstanceID ?? instance.id
        return instance
    }

    func removeProvider(_ instanceID: UUID) {
        guard let removed = registeredProviders.first(where: { $0.id == instanceID }) else { return }
        registeredProviders.removeAll { $0.id == instanceID }
        clearAutomaticLabelFromSoleAccount(of: removed.provider)
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

    func moveProvider(_ source: UUID, onto target: UUID) {
        guard let sourceIndex = registeredProviders.firstIndex(where: { $0.id == source }),
              let targetIndex = registeredProviders.firstIndex(where: { $0.id == target }),
              sourceIndex != targetIndex else { return }

        var providers = registeredProviders
        providers.move(
            fromOffsets: IndexSet(integer: sourceIndex),
            toOffset: sourceIndex < targetIndex ? targetIndex + 1 : targetIndex)
        registeredProviders = providers
    }

    private func labelExistingSingleAccountIfNeeded(_ provider: ProviderID) {
        let matches = registeredProviders.indices.filter { registeredProviders[$0].provider == provider }
        guard matches.count == 1,
              let index = matches.first,
              registeredProviders[index].accountLabel == nil else { return }
        registeredProviders[index] = registeredProviders[index].withAccountLabel("Account 1")
    }

    private func clearAutomaticLabelFromSoleAccount(of provider: ProviderID) {
        let matches = registeredProviders.indices.filter { registeredProviders[$0].provider == provider }
        guard matches.count == 1,
              let index = matches.first,
              registeredProviders[index].id == ProviderInstance.legacyID(for: provider),
              Self.automaticAccountOrdinal(registeredProviders[index].accountLabel) == 1 else { return }
        registeredProviders[index] = registeredProviders[index].withAccountLabel(nil)
    }

    private func nextInstanceID(for provider: ProviderID) -> UUID {
        let defaultID = ProviderInstance.legacyID(for: provider)
        return registeredProviders.contains(where: { $0.id == defaultID }) ? UUID() : defaultID
    }

    private func nextAccountLabel(for provider: ProviderID) -> String? {
        let siblings = instances(of: provider)
        guard !siblings.isEmpty else { return nil }

        let used = Set(siblings.compactMap { Self.automaticAccountOrdinal($0.accountLabel) })
        var ordinal = 1
        while used.contains(ordinal) { ordinal += 1 }
        return "Account \(ordinal)"
    }

    private func persistSelection() {
        if let id = selectedProviderInstanceID {
            defaults.set(id.uuidString, forKey: Keys.selectedInstanceID)
        } else {
            defaults.removeObject(forKey: Keys.selectedInstanceID)
        }
    }

    private func persistInstances() {
        guard let data = try? JSONEncoder().encode(registeredProviders) else { return }
        defaults.set(data, forKey: Keys.providerInstances)
    }

    private static func loadInstances(defaults: UserDefaults) -> [ProviderInstance]? {
        guard let data = defaults.data(forKey: Keys.providerInstances) else { return nil }
        guard let values = try? JSONDecoder().decode(
            [LossyDecoded<ProviderInstance>].self,
            from: data)
        else { return [] }
        return values.compactMap(\.value)
    }

    private struct LossyDecoded<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) {
            value = try? Value(from: decoder)
        }
    }

    private static func migratedInstances(defaults: UserDefaults) -> [ProviderInstance]? {
        legacyProviderIDs(from: defaults)?.map {
            ProviderInstance(id: ProviderInstance.legacyID(for: $0), provider: $0)
        }
    }

    private static func initialSelection(
        defaults: UserDefaults,
        instances: [ProviderInstance]
    ) -> UUID? {
        if let rawID = defaults.string(forKey: Keys.selectedInstanceID),
           let savedID = UUID(uuidString: rawID),
           instances.contains(where: { $0.id == savedID }) {
            return savedID
        }
        if let legacy = ProviderID(rawValue: defaults.string(forKey: Keys.legacySelectedProvider) ?? ""),
           let match = instances.first(where: { $0.provider == legacy }) {
            return match.id
        }
        return instances.first?.id
    }

    private static func sanitized(_ instances: [ProviderInstance]) -> [ProviderInstance] {
        let supported = Set(ProviderID.implemented)
        var seenIDs = Set<UUID>()
        var seenSingleAccountProviders = Set<ProviderID>()

        let filtered = instances.filter { instance in
            guard supported.contains(instance.provider),
                  seenIDs.insert(instance.id).inserted else { return false }
            guard !instance.provider.supportsMultipleAccounts else { return true }
            return instance.id == ProviderInstance.legacyID(for: instance.provider)
                && seenSingleAccountProviders.insert(instance.provider).inserted
        }
        let counts = Dictionary(grouping: filtered, by: \.provider).mapValues(\.count)
        return filtered.map { instance in
            guard counts[instance.provider] == 1,
                  instance.id == ProviderInstance.legacyID(for: instance.provider),
                  automaticAccountOrdinal(instance.accountLabel) == 1 else { return instance }
            return instance.withAccountLabel(nil)
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
            return sanitizedLegacyIDs(registrations)
        }
        if let order = defaults.stringArray(forKey: Keys.legacyProviderOrder), !order.isEmpty {
            return sanitizedLegacyIDs(order)
        }
        if let raw = defaults.string(forKey: Keys.legacySelectedProvider),
           let provider = ProviderID(rawValue: raw),
           ProviderID.implemented.contains(provider) {
            return [provider]
        }
        return nil
    }

    private static func sanitizedLegacyIDs(_ rawValues: [String]) -> [ProviderID] {
        let supported = Set(ProviderID.implemented)
        var seen = Set<ProviderID>()
        return rawValues
            .compactMap(ProviderID.init(rawValue:))
            .filter { supported.contains($0) && seen.insert($0).inserted }
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

@MainActor
enum ProviderInstanceCredentialStore {
    static func secret(for instance: ProviderInstance) throws -> String? {
        try AIUsageSecretStore.load(account: secretAccount(for: instance))
    }

    static func saveSecret(_ value: String, for instance: ProviderInstance) throws {
        try AIUsageSecretStore.save(value, account: secretAccount(for: instance))
    }

    static func deleteSecret(for instance: ProviderInstance) throws {
        try AIUsageSecretStore.delete(account: secretAccount(for: instance))
    }

    static func credentialPath(for instanceID: UUID) -> String? {
        let value = UserDefaults.standard.string(forKey: credentialPathKey(instanceID))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static func saveCredentialPath(_ path: String, for instanceID: UUID) {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            clearCredentialPath(for: instanceID)
        } else {
            UserDefaults.standard.set(value, forKey: credentialPathKey(instanceID))
        }
    }

    static func clearCredentialPath(for instanceID: UUID) {
        UserDefaults.standard.removeObject(forKey: credentialPathKey(instanceID))
    }

    private static func secretAccount(for instance: ProviderInstance) -> String {
        "provider.\(instance.provider.rawValue).\(instance.id.uuidString).credential"
    }

    private static func credentialPathKey(_ id: UUID) -> String {
        "providerInstance.\(id.uuidString).credentialPath"
    }
}
