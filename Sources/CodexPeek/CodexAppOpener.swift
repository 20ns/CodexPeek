import AppKit
import Foundation

final class CodexAppOpener: @unchecked Sendable {
    private let executableLocator: CodexExecutableLocating
    private let workspaceStateStore: CodexWorkspaceStateStore
    private let codexAppURL: URL
    private let codexBundleIdentifier: String
    private let runningApplicationsProvider: (String) -> [NSRunningApplication]

    init(
        executableLocator: CodexExecutableLocating = DefaultCodexExecutableLocator(),
        workspaceStateStore: CodexWorkspaceStateStore = CodexWorkspaceStateStore(),
        codexAppURL: URL = URL(fileURLWithPath: "/Applications/Codex.app"),
        codexBundleIdentifier: String = "com.openai.codex",
        runningApplicationsProvider: @escaping (String) -> [NSRunningApplication] = { bundleIdentifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        }
    ) {
        self.executableLocator = executableLocator
        self.workspaceStateStore = workspaceStateStore
        self.codexAppURL = codexAppURL
        self.codexBundleIdentifier = codexBundleIdentifier
        self.runningApplicationsProvider = runningApplicationsProvider
    }

    func openCodex(relaunchIfRunning: Bool) async throws {
        if FileManager.default.fileExists(atPath: codexAppURL.path) {
            if relaunchIfRunning {
                try await restartCodexAppIfNeeded()
            } else if activateRunningCodexAppIfPresent() {
                return
            }

            _ = try workspaceStateStore.sanitizePersistedWorkspaceState()
            try launchCodexApp()
            return
        }

        let executableURL = try executableLocator.findExecutableURL()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app"]
        try process.run()
    }

    func logout(environment: [String: String] = ProcessInfo.processInfo.environment) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try self.runCodex(arguments: ["logout"], environment: environment)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func launchLoginInTerminal(environment: [String: String]) throws {
        let executableURL = try executableLocator.findExecutableURL()
        let path = environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        let codexHome = environment["CODEX_HOME"] ?? ""
        let command = [
            "clear",
            "echo 'CodexPeek account sign-in'",
            "echo",
            "env PATH=\(shellQuoted(path)) CODEX_HOME=\(shellQuoted(codexHome)) \(shellQuoted(executableURL.path)) login"
        ].joined(separator: "; ")

        try runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: [
                "-e", "tell application \"Terminal\"",
                "-e", "activate",
                "-e", "do script \(appleScriptQuoted(command))",
                "-e", "end tell"
            ],
            environment: ProcessInfo.processInfo.environment
        )
    }

    private func restartCodexAppIfNeeded() async throws {
        let runningApps = runningApplicationsProvider(codexBundleIdentifier)
        guard !runningApps.isEmpty else {
            return
        }

        for app in runningApps {
            _ = app.terminate()
        }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if runningApplicationsProvider(codexBundleIdentifier).isEmpty {
                return
            }
            try await Task.sleep(for: .milliseconds(150))
        }

        for app in runningApplicationsProvider(codexBundleIdentifier) {
            _ = app.forceTerminate()
        }

        let forcedDeadline = Date().addingTimeInterval(2)
        while Date() < forcedDeadline {
            if runningApplicationsProvider(codexBundleIdentifier).isEmpty {
                return
            }
            try await Task.sleep(for: .milliseconds(150))
        }

        throw CodexUsageError.processFailed("Codex app did not quit cleanly")
    }

    private func launchCodexApp() throws {
        let executableURL = codexAppURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("Codex")

        try runDetachedProcess(
            executableURL: executableURL,
            arguments: [],
            environment: ProcessInfo.processInfo.environment
        )
    }

    private func activateRunningCodexAppIfPresent() -> Bool {
        guard let app = runningApplicationsProvider(codexBundleIdentifier).first else {
            return false
        }

        return app.activate(options: [.activateAllWindows])
    }

    private func runCodex(arguments: [String], environment: [String: String]) throws {
        let executableURL = try executableLocator.findExecutableURL()
        try runProcess(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment
        )
    }

    private func runDetachedProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment

        try process.run()
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) throws {
        let process = Process()
        let stderrPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardError = stderrPipe
        process.environment = environment

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
            throw CodexUsageError.processFailed(stderr)
        }
    }

    private func shellQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    private func appleScriptQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
