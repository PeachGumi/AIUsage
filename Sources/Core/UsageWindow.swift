import Foundation

enum UsageWindowKind: String, CaseIterable, Codable, Sendable {
    case fiveHour
    case weekly
    case monthly
}

struct UsageWindow: Identifiable, Equatable, Sendable {
    let kind: UsageWindowKind
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
    let resetDescription: String?

    var id: UsageWindowKind { kind }
    var remainingPercent: Double { 100 - usedPercent }

    init(
        kind: UsageWindowKind,
        label: String,
        usedPercent: Double,
        resetsAt: Date?,
        resetDescription: String?) throws
    {
        guard usedPercent.isFinite, (0...100).contains(usedPercent) else {
            throw UsageModelError.invalidPercentage
        }
        self.kind = kind
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
    }
}

enum UsageModelError: LocalizedError {
    case invalidPercentage

    var errorDescription: String? {
        "Usage percentage must be finite and between 0 and 100."
    }
}
