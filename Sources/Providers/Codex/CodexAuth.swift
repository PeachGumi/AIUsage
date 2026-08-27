import Foundation

struct CodexCredentials: Equatable, Sendable {
    let accessToken: String
    let accountID: String?
}

enum CodexAuth {
    static func parse(data: Data) throws -> CodexCredentials {
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else {
            throw CodexAuthError.invalidFile
        }
        guard let token = document.tokens?.accessToken.nonEmpty else {
            throw CodexAuthError.missingOAuthToken
        }
        return CodexCredentials(accessToken: token, accountID: document.tokens?.accountID?.nonEmpty)
    }

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) throws -> CodexCredentials
    {
        let home = codexHome(environment: environment, fileManager: fileManager)
        let file = home.appendingPathComponent("auth.json", isDirectory: false)
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            throw CodexAuthError.notFound
        }
        return try parse(data: data)
    }

    private static func codexHome(environment: [String: String], fileManager: FileManager) -> URL {
        guard let override = environment["CODEX_HOME"]?.nonEmpty else {
            return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        }
        return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
    }

    private struct Document: Decodable {
        let tokens: Tokens?
    }

    private struct Tokens: Decodable {
        let accessToken: String
        let accountID: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountID = "account_id"
        }
    }
}

enum CodexAuthError: LocalizedError, ProviderAuthenticationError {
    case notFound
    case invalidFile
    case missingOAuthToken

    var requiresAuthentication: Bool { true }

    var errorDescription: String? {
        switch self {
        case .notFound: "Codex login not found. Run codex login first."
        case .invalidFile: "Codex auth.json could not be read. Run codex login again if the problem continues."
        case .missingOAuthToken: "Codex auth.json has no OAuth access token. Run codex login again."
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
