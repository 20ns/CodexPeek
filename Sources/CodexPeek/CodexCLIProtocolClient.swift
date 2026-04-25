import Foundation

final class CodexCLIProtocolClient: CodexUsageLiveSource, @unchecked Sendable {
    private let executableLocator: CodexExecutableLocating
    private let arguments: [String]
    private let timeout: TimeInterval
    private let environment: [String: String]

    init(
        executableLocator: CodexExecutableLocating = DefaultCodexExecutableLocator(),
        arguments: [String] = ["app-server", "--listen", "stdio://"],
        timeout: TimeInterval = 6.0,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executableLocator = executableLocator
        self.arguments = arguments
        self.timeout = timeout
        self.environment = environment
    }

    func fetchUsageSnapshot() async throws -> CodexUsageSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try self.fetchUsageSnapshotSync())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func fetchUsageSnapshotSync() throws -> CodexUsageSnapshot {
        let executableURL = try executableLocator.findExecutableURL()
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = mergedEnvironment(executableURL: executableURL)

        let collector = ResponseCollector()
        let stderrBox = LockedDataBox()
        let readGroup = DispatchGroup()

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let handle = stdoutPipe.fileHandleForReading
            var buffer = Data()

            while true {
                let data = handle.availableData
                if data.isEmpty {
                    break
                }

                buffer.append(data)
                while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.prefix(upTo: newlineIndex)
                    buffer.removeSubrange(...newlineIndex)

                    guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else {
                        continue
                    }

                    collector.append(line: line)
                }
            }
            readGroup.leave()
        }

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBox.set(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }

        try process.run()

        let writer = stdinPipe.fileHandleForWriting
        try send(data: AppServerRequestBuilder.initializeData(), to: writer)
        _ = try collector.waitForEnvelope(
            id: 1,
            as: AppServerInitializeResponse.self,
            timeout: timeout
        )

        try send(data: AppServerRequestBuilder.initializedData(), to: writer)
        try send(data: AppServerRequestBuilder.accountReadData(), to: writer)
        let accountEnvelope = try collector.waitForEnvelope(
            id: 2,
            as: AppServerAccountReadResponse.self,
            timeout: timeout
        )

        try send(data: AppServerRequestBuilder.rateLimitsReadData(), to: writer)
        let rateLimitsEnvelope = try collector.waitForEnvelope(
            id: 3,
            as: AppServerRateLimitsResponse.self,
            timeout: timeout
        )

        writer.closeFile()
        process.terminate()
        _ = readGroup.wait(timeout: .now() + timeout)
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderrText = String(data: stderrBox.get(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
            if accountEnvelope.result == nil || rateLimitsEnvelope.result == nil {
                throw CodexUsageError.processFailed(stderrText)
            }
        }

        guard let accountResult = accountEnvelope.result else {
            throw CodexUsageError.invalidResponse("account/read returned no result")
        }

        guard let rateLimitsResult = rateLimitsEnvelope.result else {
            throw CodexUsageError.invalidResponse("account/rateLimits/read returned no result")
        }

        let rateLimitSnapshot = AppServerRateLimitSelector.selectCodexSnapshot(from: rateLimitsResult)
        let sparkSnapshot = AppServerRateLimitSelector.selectSparkSnapshot(from: rateLimitsResult)

        return CodexUsageSnapshot(
            account: mapAccount(accountResult.account),
            primary: mapWindow(rateLimitSnapshot.primary),
            secondary: mapWindow(rateLimitSnapshot.secondary),
            spark: sparkSnapshot.map(mapSparkSnapshot),
            source: .live,
            lastUpdatedAt: Date(),
            isStale: false
        )
    }

    private func send(data: Data, to handle: FileHandle) throws {
        try handle.write(contentsOf: data)
    }

    private func mergedEnvironment(executableURL: URL) -> [String: String] {
        var merged = environment
        let existingPath = merged["PATH"] ?? ""
        let executableDirectory = executableURL.deletingLastPathComponent().path
        let additionalPaths = [
            executableDirectory,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        let pathParts = (existingPath.split(separator: ":").map(String.init) + additionalPaths)
        let deduped = Array(NSOrderedSet(array: pathParts)) as? [String] ?? pathParts
        merged["PATH"] = deduped.joined(separator: ":")
        return merged
    }

    private func mapAccount(_ account: AppServerAccount?) -> CodexAccountSnapshot {
        guard let account else {
            return .empty
        }

        switch account {
        case .apiKey:
            return CodexAccountSnapshot(
                email: nil,
                authMode: .apikey,
                planType: .unknown
            )
        case .chatgpt(let email, let planType):
            return CodexAccountSnapshot(
                email: email,
                authMode: .chatgpt,
                planType: planType
            )
        }
    }

    private func mapWindow(_ window: AppServerRateLimitWindow?) -> RateLimitWindowSnapshot? {
        guard let window else {
            return nil
        }

        return RateLimitWindowSnapshot(
            usedPercent: window.usedPercent,
            windowDurationMins: window.windowDurationMins,
            resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    private func mapSparkSnapshot(_ snapshot: AppServerRateLimitSnapshot) -> SupplementalRateLimitSnapshot {
        SupplementalRateLimitSnapshot(
            limitID: snapshot.limitId ?? "spark",
            title: "5.3 Spark",
            primary: mapWindow(snapshot.primary),
            secondary: mapWindow(snapshot.secondary)
        )
    }
}

private final class LockedDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ data: Data) {
        lock.lock()
        self.data = data
        lock.unlock()
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private final class ResponseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var lines: [String] = []

    func append(line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
        semaphore.signal()
    }

    func waitForEnvelope<Result: Decodable>(
        id: Int,
        as type: Result.Type,
        timeout: TimeInterval
    ) throws -> AppServerTypedEnvelope<Result> {
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            if let envelope = try takeEnvelope(id: id, as: type) {
                return envelope
            }

            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                throw CodexUsageError.timedOut
            }

            if semaphore.wait(timeout: .now() + remaining) == .timedOut {
                throw CodexUsageError.timedOut
            }
        }
    }

    private func takeEnvelope<Result: Decodable>(
        id: Int,
        as type: Result.Type
    ) throws -> AppServerTypedEnvelope<Result>? {
        lock.lock()
        defer { lock.unlock() }

        for (index, line) in lines.enumerated() {
            let identifier = try AppServerLineParser.decodeIdentifier(from: line)
            guard identifier.id == id else {
                continue
            }

            lines.remove(at: index)
            return try AppServerLineParser.decode(type, from: line)
        }

        return nil
    }
}
