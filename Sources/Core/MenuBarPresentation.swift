import Foundation

enum UsageMetric: String, CaseIterable, Codable, Sendable {
    case remaining
    case used
}

enum MenuBarPresentation {
    static func title(snapshot: ProviderSnapshot, metric: UsageMetric) -> String {
        let values = snapshot.windows.map { window in
            let compact = window.compactLabel ?? label(window.kind)
            return "\(compact):\(PercentFormatter.string(value(window, metric: metric)))%"
        }
        guard !values.isEmpty else { return snapshot.provider.shortName }
        return snapshot.provider.shortName + " " + values.joined(separator: " / ")
    }

    static func value(_ window: UsageWindow, metric: UsageMetric) -> Double {
        metric == .remaining ? window.remainingPercent : window.usedPercent
    }

    static func label(_ kind: UsageWindowKind) -> String {
        switch kind {
        case .fiveHour: "5h"
        case .weekly: "W"
        case .monthly: "M"
        }
    }
}

enum PercentFormatter {
    static func string(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        guard rounded != rounded.rounded() else { return String(Int(rounded)) }
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), rounded)
    }
}
