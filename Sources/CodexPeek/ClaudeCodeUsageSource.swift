import Darwin
import Foundation

enum ClaudeUsageSourceError: LocalizedError, Equatable {
    case notSignedIn, unreadable, rejected, rateLimited, unavailable, timedOut

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Claude is not signed in."
        case .unreadable: "Claude credentials could not be read."
        case .rejected: "Claude usage data was rejected."
        case .rateLimited: "Claude usage is rate limited."
        case .unavailable: "Claude usage is unavailable."
        case .timedOut: "Claude usage request timed out."
        }
    }
}

actor ClaudeCodeUsageSource {
    private static let gap: TimeInterval = 5 * 60
    private let cacheURL: URL
    private let now: @Sendable () -> Date
    private let readToken: @Sendable () async throws -> String
    private let fetch: @Sendable (String) async throws -> (Data, HTTPURLResponse)
    private var isRefreshing = false
    private var nextAllowedAttempt = Date.distantPast
    private var retryLocked = false

    init(
        cacheURL: URL = ClaudeCodeStatusLine.cacheURL,
        now: @escaping @Sendable () -> Date = Date.init,
        readToken: @escaping @Sendable () async throws -> String = { try await ClaudeCredential.token() },
        fetch: @escaping @Sendable (String) async throws -> (Data, HTTPURLResponse) = { try await ClaudeUsageHTTP.get($0) }
    ) {
        self.cacheURL = cacheURL
        self.now = now
        self.readToken = readToken
        self.fetch = fetch
    }

    /// Nil means a cooldown or an in-flight refresh, so no new request was started.
    /// `force` skips the five-minute gap and still cannot skip a 429 lock.
    func refresh(force: Bool = false) async throws -> ClaudeCodeUsageSnapshot? {
        let current = now()
        if isRefreshing || (current < nextAllowedAttempt && (!force || retryLocked)) { return nil }
        isRefreshing = true
        defer { isRefreshing = false }
        nextAllowedAttempt = current.addingTimeInterval(Self.gap)
        retryLocked = false
        let token = try await readToken()
        let (data, response) = try await fetch(token)
        switch response.statusCode {
        case 200:
            do {
                guard let snapshot = try ClaudeCodeStatusLine.captureOAuth(data, at: cacheURL, now: current) else {
                    throw ClaudeUsageSourceError.unavailable
                }
                return snapshot
            } catch let error as ClaudeUsageSourceError {
                throw error
            } catch { throw ClaudeUsageSourceError.rejected }
        case 401, 403:
            throw ClaudeUsageSourceError.notSignedIn
        case 429:
            nextAllowedAttempt = current.addingTimeInterval(Self.retryDelay(response, now: current))
            retryLocked = true
            throw ClaudeUsageSourceError.rateLimited
        default:
            throw ClaudeUsageSourceError.unavailable
        }
    }

    private static func retryDelay(_ response: HTTPURLResponse, now: Date) -> TimeInterval {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return gap }
        if let seconds = Double(value), seconds.isFinite { return max(seconds, gap) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return max(formatter.date(from: value)?.timeIntervalSince(now) ?? 0, gap)
    }
}

private enum ClaudeUsageHTTP {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    static func get(_ token: String) async throws -> (Data, HTTPURLResponse) {
        guard !token.isEmpty, !token.contains(where: \.isWhitespace) else { throw ClaudeUsageSourceError.unreadable }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexPeek", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ClaudeUsageSourceError.unavailable }
            return (data, http)
        } catch let error as ClaudeUsageSourceError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw ClaudeUsageSourceError.timedOut
        } catch { throw ClaudeUsageSourceError.unavailable }
    }
}

private enum ClaudeCredential {
    static func token() async throws -> String {
        let environment = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !environment.isEmpty { return environment }
        return try await Task.detached(priority: .userInitiated) { try readOffMainActor() }.value
    }

    private static func readOffMainActor() throws -> String {
        let url = ClaudeCodeTokenUsageSource.defaultProjectsRoot()
            .deletingLastPathComponent()
            .appendingPathComponent(".credentials.json")
        if let token = try fileToken(url) { return token }
        guard let token = accessToken(in: try keychainData()) else { throw ClaudeUsageSourceError.notSignedIn }
        return token
    }

    private static func fileToken(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { return accessToken(in: try Data(contentsOf: url)) } catch { throw ClaudeUsageSourceError.unreadable }
    }

    private static func accessToken(in data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Password JSON stays in memory for parsing. Never log or include it in an error.
    private static func keychainData() throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            let killAfter = Date().addingTimeInterval(0.2)
            while process.isRunning && Date() < killAfter { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw ClaudeUsageSourceError.timedOut
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { return Data() }
        return data
    }
}
