import Foundation

enum CodexUsageParser {
    static func parse(data: Data, now: Date = Date()) throws -> ProviderSnapshot {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let rawWindows = [response.rateLimit?.primary, response.rateLimit?.secondary].compactMap { $0 }
        let windows = try rawWindows.compactMap(makeWindow)
        guard !windows.isEmpty else { throw CodexUsageError.invalidResponse }
        return ProviderSnapshot(
            provider: .codex,
            planName: response.planType?.capitalized,
            windows: windows,
            fetchedAt: now)
    }

    private static func makeWindow(_ raw: RawWindow) throws -> UsageWindow? {
        guard raw.resetAt > 0 else { throw CodexUsageError.invalidResponse }
        guard let kind = kind(seconds: raw.duration) else { return nil }
        return try UsageWindow(
            kind: kind,
            label: label(kind),
            usedPercent: raw.usedPercent,
            resetsAt: Date(timeIntervalSince1970: TimeInterval(raw.resetAt)),
            resetDescription: nil)
    }

    private static func kind(seconds: Int) -> UsageWindowKind? {
        switch seconds {
        case 18_000: .fiveHour
        case 604_800: .weekly
        default: nil
        }
    }

    private static func label(_ kind: UsageWindowKind) -> String {
        kind == .fiveHour ? "5-hour" : "Weekly"
    }

    private struct Response: Decodable {
        let planType: String?
        let rateLimit: RateLimit?

        enum CodingKeys: String, CodingKey {
            case planType = "plan_type"
            case rateLimit = "rate_limit"
        }
    }

    private struct RateLimit: Decodable {
        let primary: RawWindow?
        let secondary: RawWindow?

        enum CodingKeys: String, CodingKey {
            case primary = "primary_window"
            case secondary = "secondary_window"
        }
    }

    private struct RawWindow: Decodable {
        let usedPercent: Double
        let resetAt: Int
        let duration: Int

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case duration = "limit_window_seconds"
        }
    }
}

enum CodexUsageError: LocalizedError {
    case invalidResponse
    case unauthorized
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "OpenAI returned unexpected Codex usage data. The usage endpoint may have changed."
        case .unauthorized:
            "Codex login expired. Run codex login again, then Refresh."
        case let .http(status) where status == 429:
            "Codex is temporarily rate limiting usage requests. Try Refresh again later."
        case let .http(status) where (500...599).contains(status):
            "Codex usage service is temporarily unavailable (HTTP \(status)). Try again later."
        case let .http(status):
            "Codex usage request failed (HTTP \(status))."
        }
    }
}
