import Foundation

enum QwenUsageParser {
    static func parse(
        subscription: Data,
        quota: Data,
        usage: Data,
        now: Date = Date()) throws -> ProviderSnapshot
    {
        let subscriptionPayload = try decode(SubscriptionPayload.self, from: subscription)
        // Fail closed: an envelope that reports a failure, or a subscription
        // that is not explicitly active, must never be presented as usage.
        guard subscriptionPayload.status.uppercased() == "ACTIVE" else {
            throw QwenUsageError.noActiveSubscription
        }
        let quotas = try decode([String: QuotaPayload].self, from: quota)
        let usagePayload = try decode(UsagePayload.self, from: usage)
        guard let planQuota = quotas[subscriptionPayload.specCode],
              planQuota.fiveHour > 0,
              planQuota.weekly > 0
        else { throw QwenUsageError.invalidResponse }

        let windows = try makeWindows(usagePayload)
        return ProviderSnapshot(
            provider: .qwen,
            planName: planName(subscriptionPayload),
            windows: windows,
            fetchedAt: now)
    }

    private static func makeWindows(_ usage: UsagePayload) throws -> [UsageWindow] {
        [
            try UsageWindow(
                kind: .fiveHour,
                label: "5-hour",
                usedPercent: usage.fiveHourFraction * 100,
                resetsAt: resetDate(usage.fiveHourResetMS),
                resetDescription: nil),
            try UsageWindow(
                kind: .weekly,
                label: "Weekly",
                usedPercent: usage.weeklyFraction * 100,
                resetsAt: resetDate(usage.weeklyResetMS),
                resetDescription: nil),
        ]
    }

    private static func resetDate(_ milliseconds: Double) -> Date? {
        milliseconds > 0 ? Date(timeIntervalSince1970: milliseconds / 1000) : nil
    }

    private static func planName(_ subscription: SubscriptionPayload) -> String {
        let plan = subscription.specCode.capitalized
        return "Token Plan \(plan) · \(subscription.remainingDays) days left"
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        if successfulEnvelopeHasNoPayload(data) { throw QwenUsageError.noActiveSubscription }
        do {
            return try JSONDecoder().decode(Envelope<T>.self, from: data).data.dataV2.data.payload
        } catch let error as QwenUsageError {
            throw error
        } catch {
            throw QwenUsageError.invalidResponse
        }
    }

    private static func successfulEnvelopeHasNoPayload(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outer = root["data"] as? [String: Any],
              let dataV2 = outer["DataV2"] as? [String: Any],
              let inner = dataV2["data"] as? [String: Any]
        else { return false }
        return inner["success"] as? Bool == true && inner["data"] == nil
    }

    private struct Envelope<Payload: Decodable>: Decodable {
        let data: Outer<Payload>
    }

    private struct Outer<Payload: Decodable>: Decodable {
        let dataV2: Middle<Payload>

        enum CodingKeys: String, CodingKey { case dataV2 = "DataV2" }
    }

    private struct Middle<Payload: Decodable>: Decodable {
        let data: Inner<Payload>
    }

    private struct Inner<Payload: Decodable>: Decodable {
        let payload: Payload

        enum CodingKeys: String, CodingKey { case payload = "data" }
    }

    private struct SubscriptionPayload: Decodable {
        let specCode: String
        let status: String
        let remainingDays: Int
    }

    private struct QuotaPayload: Decodable {
        let fiveHour: Double
        let weekly: Double

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case weekly
        }
    }

    private struct UsagePayload: Decodable {
        let fiveHourFraction: Double
        let weeklyFraction: Double
        let fiveHourResetMS: Double
        let weeklyResetMS: Double

        enum CodingKeys: String, CodingKey {
            case fiveHourFraction = "per5HourPercentage"
            case weeklyFraction = "per1WeekPercentage"
            case fiveHourResetMS = "per5HourResetTime"
            case weeklyResetMS = "per1WeekResetTime"
        }
    }
}

enum QwenUsageError: LocalizedError, Equatable {
    case notLoggedIn
    case noActiveSubscription
    case invalidResponse
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: "Qwen Cloud login is required."
        case .noActiveSubscription: "No active Qwen Token Plan usage was returned."
        case .invalidResponse: "Qwen Cloud returned invalid usage data."
        case let .http(status): "Qwen Cloud request failed (HTTP \(status))."
        }
    }
}
