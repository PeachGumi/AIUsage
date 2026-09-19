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
        return try load(fileURL: authFileURL(environment: environment, fileManager: fileManager))
    }

    static func authFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) -> URL
    {
        codexHome(environment: environment, fileManager: fileManager)
            .appendingPathComponent("auth.json", isDirectory: false)
    }

    /// Reads an explicitly selected auth.json for one provider instance. Any
    /// refresh writes remain owned by the official Codex CLI.
    static func load(fileURL: URL) throws -> CodexCredentials {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
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

enum CodexAuthRefresher {
    static func refresh(
        authFileURL: URL = CodexAuth.authFileURL(),
        executableURL: URL? = nil,
        timeout: Duration = .seconds(20),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) async throws
    {
        let executable = try executableURL ?? locateExecutable(
            environment: environment,
            fileManager: fileManager)
        let components = timeout.components
        let timeoutSeconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        try await Task.detached(priority: .utility) {
            try runAppServer(
                executableURL: executable,
                authFileURL: authFileURL,
                timeout: max(1, timeoutSeconds),
                environment: environment)
        }.value
    }

    private static func locateExecutable(
        environment: [String: String],
        fileManager: FileManager) throws -> URL
    {
        var candidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true)
                .appendingPathComponent("codex", isDirectory: false) }
        candidates += [
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/codex", isDirectory: false),
        ]
        guard let executable = candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
        }) else {
            throw CodexAuthRefreshError.executableNotFound
        }
        return executable
    }

    private static func runAppServer(
        executableURL: URL,
        authFileURL: URL,
        timeout: TimeInterval,
        environment: [String: String]) throws
    {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let timeoutState = TimeoutState()
        let processBox = ProcessBox(process)

        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var childEnvironment = environment
        childEnvironment["CODEX_HOME"] = authFileURL.deletingLastPathComponent().path
        childEnvironment["PATH"] = executableSearchPath(
            executableURL: executableURL,
            existingPath: environment["PATH"])
        process.environment = childEnvironment

        try process.run()
        let timeoutItem = DispatchWorkItem {
            timeoutState.markTimedOut()
            if processBox.process.isRunning {
                processBox.process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout,
            execute: timeoutItem)

        defer {
            timeoutItem.cancel()
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }

        try write(
            [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": ["name": "aiusage", "version": "1.0"],
                    "capabilities": ["experimentalApi": true],
                ],
            ],
            to: input.fileHandleForWriting)

        var buffer = Data()
        var didSendAccountRead = false
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard !line.isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let id = object["id"] as? Int
                else { continue }

                if object["error"] != nil {
                    throw CodexAuthRefreshError.protocolFailure
                }
                if id == 1, !didSendAccountRead {
                    guard object.keys.contains("result") else {
                        throw CodexAuthRefreshError.protocolFailure
                    }
                    try write(
                        ["jsonrpc": "2.0", "method": "initialized", "params": [:]],
                        to: input.fileHandleForWriting)
                    try write(
                        [
                            "jsonrpc": "2.0",
                            "id": 2,
                            "method": "account/read",
                            "params": ["refreshToken": true],
                        ],
                        to: input.fileHandleForWriting)
                    didSendAccountRead = true
                } else if id == 2 {
                    guard object.keys.contains("result") else {
                        throw CodexAuthRefreshError.protocolFailure
                    }
                    return
                }
            }
        }

        if timeoutState.didTimeOut {
            throw CodexAuthRefreshError.timedOut
        }
        process.waitUntilExit()
        throw process.terminationStatus == 0
            ? CodexAuthRefreshError.protocolFailure
            : CodexAuthRefreshError.processExited(process.terminationStatus)
    }

    private static func write(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private static func executableSearchPath(
        executableURL: URL,
        existingPath: String?) -> String
    {
        let paths = [
            executableURL.deletingLastPathComponent().path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            existingPath,
        ].compactMap { $0 }
        return Array(NSOrderedSet(array: paths))
            .compactMap { $0 as? String }
            .joined(separator: ":")
    }
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}

private final class TimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOut = false

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }
}

enum CodexAuthRefreshError: LocalizedError {
    case executableNotFound
    case processExited(Int32)
    case protocolFailure
    case timedOut

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Codex CLI was not found. Install or update Codex, then run codex login."
        case let .processExited(status):
            "Codex CLI ended before refreshing this login (status \(status))."
        case .protocolFailure:
            "Codex CLI could not refresh this login. Run codex login again."
        case .timedOut:
            "Codex CLI timed out while refreshing this login."
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
        case .notFound: "Codex login not found. Run codex login first or choose an account auth.json."
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
