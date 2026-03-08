import AppKit
import Foundation

final class CodexAppOpener: @unchecked Sendable {
    private let executableLocator: CodexExecutableLocating

    init(executableLocator: CodexExecutableLocating = DefaultCodexExecutableLocator()) {
        self.executableLocator = executableLocator
    }

    func openCodex() {
        let appURL = URL(fileURLWithPath: "/Applications/Codex.app")
        if FileManager.default.fileExists(atPath: appURL.path) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
            return
        }

        do {
            let executableURL = try executableLocator.findExecutableURL()
            let process = Process()
            process.executableURL = executableURL
            process.arguments = ["app"]
            try process.run()
        } catch {
            NSSound.beep()
        }
    }

    func logout() async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try self.runCodex(arguments: ["logout"])
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runCodex(arguments: [String]) throws {
        let executableURL = try executableLocator.findExecutableURL()
        let process = Process()
        let stderrPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
            throw CodexUsageError.processFailed(stderr)
        }
    }
}
