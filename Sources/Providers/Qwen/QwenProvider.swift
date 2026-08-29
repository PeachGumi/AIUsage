import Foundation

@MainActor
final class QwenProvider: UsageProvider {
    let id: ProviderID = .qwen
    private let session: URLSession
    private let cookieSource: (URL) async throws -> String

    init(
        session: URLSession = MajorProviderHTTP.session(),
        cookieSource: ((URL) async throws -> String)? = nil
    ) {
        self.session = session
        if let cookieSource {
            self.cookieSource = cookieSource
        } else {
            let repository = QwenCookieRepository()
            self.cookieSource = { url in try await repository.header(for: url) }
        }
    }

    func fetch() async throws -> ProviderSnapshot {
        let homeCookie = try await cookieSource(URLs.userInfo)
        let token = try await fetchSecToken(cookie: homeCookie)
        let gatewayCookie = try await cookieSource(URLs.gateway)
        let subscription = try await call(api: APIs.subscription, data: commodity, token: token, cookie: gatewayCookie)
        let quota = try await call(api: APIs.quota, data: commodity, token: token, cookie: gatewayCookie)
        let usage = try await call(api: APIs.usage, data: commodity, token: token, cookie: gatewayCookie)
        return try QwenUsageParser.parse(subscription: subscription, quota: quota, usage: usage)
    }

    private func fetchSecToken(cookie: String) async throws -> String {
        var request = URLRequest(url: URLs.userInfo, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        return try Self.parseSecToken(await data(for: request))
    }

    private func call(api: String, data: [String: Any], token: String, cookie: String) async throws -> Data {
        try await self.data(for: Self.makeGatewayRequest(
            api: api,
            data: data,
            secToken: token,
            cookieHeader: cookie))
    }

    private func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw QwenUsageError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw QwenUsageError.http(http.statusCode) }
        return data
    }

    static func parseSecToken(_ data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QwenUsageError.invalidResponse
        }
        guard object["code"] as? String != "ConsoleNeedLogin" else { throw QwenUsageError.notLoggedIn }
        guard let token = (object["data"] as? [String: Any])?["secToken"] as? String,
              !token.isEmpty else { throw QwenUsageError.invalidResponse }
        return token
    }

    static func makeGatewayRequest(
        api: String,
        data: [String: Any],
        secToken: String,
        cookieHeader: String
    ) throws -> URLRequest {
        let wrapped = try wrappedData(data, api: api)
        let json = try JSONSerialization.data(withJSONObject: wrapped)
        guard let params = String(data: json, encoding: .utf8),
              var components = URLComponents(url: URLs.gateway, resolvingAgainstBaseURL: false)
        else { throw QwenUsageError.invalidResponse }
        components.queryItems = [
            URLQueryItem(name: "product", value: "sfm_bailian"),
            URLQueryItem(name: "action", value: "IntlBroadScopeAspnGateway"),
            URLQueryItem(name: "api", value: api),
        ]
        guard let gatewayURL = components.url else { throw QwenUsageError.invalidResponse }

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "product", value: "sfm_bailian"),
            URLQueryItem(name: "action", value: "IntlBroadScopeAspnGateway"),
            URLQueryItem(name: "sec_token", value: secToken),
            URLQueryItem(name: "region", value: "ap-southeast-1"),
            URLQueryItem(name: "params", value: params),
        ]
        guard let encodedBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B"),
              let bodyData = encodedBody.data(using: .utf8)
        else { throw QwenUsageError.invalidResponse }

        var request = URLRequest(url: gatewayURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.httpBody = bodyData
        return request
    }

    private static func wrappedData(_ data: [String: Any], api: String) throws -> [String: Any] {
        var payload = data
        payload["cornerstoneParam"] = [
            "domain": "home.qwencloud.com",
            "consoleSite": "QWENCLOUD",
            "console": "ONE_CONSOLE",
            "xsp_lang": "en",
            "protocol": "V2",
            "productCode": "p_efm",
        ]
        return ["Api": api, "Data": payload, "V": "1.0"]
    }

    private var commodity: [String: Any] {
        ["commodityCode": "sfm_tokenplansolo_public_intl"]
    }

    private enum APIs {
        static let subscription = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription"
        static let quota = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/quota-config"
        static let usage = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"
    }

    private enum URLs {
        static let userInfo = URL(string: "https://home.qwencloud.com/tool/user/info.json")!
        static let gateway = URL(string: "https://cs-data.qwencloud.com/data/api.json")!
    }
}
