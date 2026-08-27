import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var selectedProvider: ProviderID? {
        didSet {
            if let selectedProvider {
                defaults.set(selectedProvider.rawValue, forKey: Keys.provider)
            } else {
                defaults.removeObject(forKey: Keys.provider)
            }
        }
    }

    @Published var metric: UsageMetric {
        didSet { defaults.set(metric.rawValue, forKey: Keys.metric) }
    }

    /// Providers explicitly added by the user, in dashboard display order.
    /// A fresh install intentionally starts empty; supported providers are a
    /// catalog, not an implicit subscription list.
    @Published private(set) var registeredProviders: [ProviderID] {
        didSet { defaults.set(registeredProviders.map(\.rawValue), forKey: Keys.registeredProviders) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let registered = Self.sanitized(defaults.stringArray(forKey: Keys.registeredProviders) ?? [])
        registeredProviders = registered
        metric = UsageMetric(rawValue: defaults.string(forKey: Keys.metric) ?? "") ?? .remaining

        let savedSelection = ProviderID(rawValue: defaults.string(forKey: Keys.provider) ?? "")
        selectedProvider = savedSelection.flatMap { registered.contains($0) ? $0 : nil } ?? registered.first
    }

    var addableProviders: [ProviderID] {
        ProviderID.implemented.filter { !registeredProviders.contains($0) }
    }

    func addProvider(_ provider: ProviderID) {
        guard ProviderID.implemented.contains(provider), !registeredProviders.contains(provider) else { return }
        registeredProviders.append(provider)
        if selectedProvider == nil { selectedProvider = provider }
    }

    func removeProvider(_ provider: ProviderID) {
        guard registeredProviders.contains(provider) else { return }
        registeredProviders.removeAll { $0 == provider }
        if selectedProvider == provider {
            selectedProvider = registeredProviders.first
        }
    }

    /// Reorders registered cards for a drag from `from` offsets to `to`
    /// (List/ForEach move semantics).
    func moveProvider(from: IndexSet, to: Int) {
        var providers = registeredProviders
        providers.move(fromOffsets: from, toOffset: to)
        registeredProviders = providers
    }

    /// Moves a dragged provider onto the visual position of another card.
    /// `Array.move` uses an insertion offset, so forward moves need +1.
    func moveProvider(fromIndex source: Int, ontoIndex target: Int) {
        guard registeredProviders.indices.contains(source),
              registeredProviders.indices.contains(target),
              source != target else { return }
        let destination = source < target ? target + 1 : target
        moveProvider(from: IndexSet(integer: source), to: destination)
    }

    /// Drops unknown, not-yet-implemented, and duplicate values. Missing
    /// providers are deliberately not appended: only explicit registrations
    /// belong here.
    private static func sanitized(_ rawValues: [String]) -> [ProviderID] {
        let implemented = Set(ProviderID.implemented)
        let valid = rawValues.compactMap(ProviderID.init(rawValue:)).filter(implemented.contains)
        var seen = Set<ProviderID>()
        return valid.filter { seen.insert($0).inserted }
    }

    private enum Keys {
        static let provider = "menuBarProvider"
        static let metric = "usageMetric"
        static let registeredProviders = "registeredProviders"
    }
}
