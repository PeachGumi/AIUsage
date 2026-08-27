import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var selectedProvider: ProviderID {
        didSet { defaults.set(selectedProvider.rawValue, forKey: Keys.provider) }
    }

    @Published var metric: UsageMetric {
        didSet { defaults.set(metric.rawValue, forKey: Keys.metric) }
    }

    /// Card order in the dashboard window, user-arrangeable by dragging.
    @Published private(set) var providerOrder: [ProviderID] {
        didSet { defaults.set(providerOrder.map(\.rawValue), forKey: Keys.order) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedProvider = ProviderID(rawValue: defaults.string(forKey: Keys.provider) ?? "") ?? .codex
        metric = UsageMetric(rawValue: defaults.string(forKey: Keys.metric) ?? "") ?? .remaining
        providerOrder = Self.sanitized(defaults.stringArray(forKey: Keys.order) ?? [])
    }

    /// Reorders cards for a drag from `from` offsets to `to` (List/ForEach move semantics).
    func moveProvider(from: IndexSet, to: Int) {
        var order = providerOrder
        order.move(fromOffsets: from, toOffset: to)
        providerOrder = order
    }

    /// Drops unknown raw values, removes duplicates, and appends any provider
    /// missing from a stale saved order so every provider always has a card.
    private static func sanitized(_ rawValues: [String]) -> [ProviderID] {
        let valid = rawValues.compactMap(ProviderID.init(rawValue:))
        var seen = Set<ProviderID>()
        let unique = valid.filter { seen.insert($0).inserted }
        return unique + ProviderID.allCases.filter { !seen.contains($0) }
    }

    private enum Keys {
        static let provider = "menuBarProvider"
        static let metric = "usageMetric"
        static let order = "providerOrder"
    }
}
