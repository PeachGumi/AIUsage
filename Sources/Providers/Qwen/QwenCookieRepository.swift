import Foundation
import WebKit

/// Serves browser-equivalent Cookie headers per destination URL: WebKit's own
/// matching decides host, domain, path, Secure, and expiry. Cookies are never
/// merged across registrable domains because each destination is asked
/// separately.
@MainActor
final class QwenCookieRepository {
    static let shared = QwenCookieRepository()

    private let dataStore: WKWebsiteDataStore
    private let defaults: UserDefaults
    private let legacyURL: URL

    init(
        dataStore: WKWebsiteDataStore = .default(),
        defaults: UserDefaults = .standard,
        legacyURL: URL? = nil)
    {
        self.dataStore = dataStore
        self.defaults = defaults
        self.legacyURL = legacyURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QwenUsage/saved_cookies.txt")
    }

    /// Cookie header exactly as a browser would send it to `url`.
    func header(for url: URL) async throws -> String {
        let cookies = await cookies(matching: url)
        let header = cookies
            .sorted { ($0.name, $0.path) < ($1.name, $1.path) }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        if !header.isEmpty { return header }
        // One-time fallback: the legacy QwenUsage header only for hosts it was
        // originally captured for.
        guard Self.isLegacyCompatible(url), !defaults.bool(forKey: Keys.ignoreLegacy),
              let legacy = try? String(contentsOf: legacyURL, encoding: .utf8),
              Self.isValidHeaderShape(legacy)
        else { throw QwenUsageError.notLoggedIn }
        return legacy
    }

    func markLoginSucceeded() {
        defaults.set(false, forKey: Keys.ignoreLegacy)
    }

    func logout() async {
        defaults.set(true, forKey: Keys.ignoreLegacy)
        for cookie in await allCookies() where Self.isQwenFamily(cookie.domain) {
            await delete(cookie)
        }
    }

    private func cookies(matching url: URL) async -> [HTTPCookie] {
        await allCookies().filter { Self.browserWouldSend(cookie: $0, to: url) }
    }

    private func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    private func delete(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.delete(cookie) { continuation.resume() }
        }
    }

    /// Mirrors RFC 6265 sending rules closely enough to never cross registrable
    /// domains: domain-match, host-only match, Secure, and expiry.
    nonisolated static func browserWouldSend(cookie: HTTPCookie, to url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        guard url.scheme == "https" || !cookie.isSecure else { return false }
        guard Self.domainMatches(cookieDomain: cookie.domain.lowercased(), host: host) else { return false }
        guard url.path.hasPrefix(cookie.path.isEmpty ? "/" : cookie.path) else { return false }
        if let expires = cookie.expiresDate { return expires > Date() }
        return true
    }

    nonisolated static func domainMatches(cookieDomain: String, host: String) -> Bool {
        let domain = cookieDomain.hasPrefix(".") ? String(cookieDomain.dropFirst()) : cookieDomain
        return domain == host || host.hasSuffix("." + domain)
    }

    nonisolated static func isQwenFamily(_ domain: String) -> Bool {
        let normalized = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized == "qwencloud.com" || normalized.hasSuffix(".qwencloud.com") ||
            normalized == "qianwenai.com" || normalized.hasSuffix(".qianwenai.com")
    }

    nonisolated private static func isLegacyCompatible(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "home.qwencloud.com" || host.hasSuffix(".qwencloud.com")
    }

    /// Reject obviously malformed legacy files: only name=value pairs.
    nonisolated static func isValidHeaderShape(_ header: String) -> Bool {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return false }
        return trimmed.split(separator: ";").allSatisfy { pair in
            let part = pair.trimmingCharacters(in: .whitespaces)
            guard let equals = part.firstIndex(of: "="), equals != part.startIndex else { return false }
            let name = part[..<equals]
            return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        }
    }

    private enum Keys { static let ignoreLegacy = "qwen.ignoreLegacyCookie" }
}
