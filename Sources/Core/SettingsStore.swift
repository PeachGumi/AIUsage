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

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedProvider = ProviderID(rawValue: defaults.string(forKey: Keys.provider) ?? "") ?? .codex
        metric = UsageMetric(rawValue: defaults.string(forKey: Keys.metric) ?? "") ?? .remaining
    }

    private enum Keys {
        static let provider = "menuBarProvider"
        static let metric = "usageMetric"
    }
}
