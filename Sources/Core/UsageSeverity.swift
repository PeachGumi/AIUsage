import Foundation

enum UsageSeverity: Equatable, Sendable {
    case healthy
    case warning
    case critical

    init(remainingPercent: Double) {
        if remainingPercent > 50 {
            self = .healthy
        } else if remainingPercent > 20 {
            self = .warning
        } else {
            self = .critical
        }
    }
}
