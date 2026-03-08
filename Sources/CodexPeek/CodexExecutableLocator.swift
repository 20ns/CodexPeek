import Foundation

final class DefaultCodexExecutableLocator: CodexExecutableLocating, @unchecked Sendable {
    private let environment: [String: String]
    private let fileManager: FileManager

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.fileManager = fileManager
    }

    func findExecutableURL() throws -> URL {
        if let explicitPath = environment["CODEX_CLI_PATH"] {
            let expanded = NSString(string: explicitPath).expandingTildeInPath
            if isExecutable(at: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }

        let searchPaths = Set(pathComponents() + [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            NSString(string: "~/.local/bin").expandingTildeInPath
        ])

        for path in searchPaths where !path.isEmpty {
            let candidate = URL(fileURLWithPath: path).appendingPathComponent("codex")
            if isExecutable(at: candidate.path) {
                return candidate
            }
        }

        throw CodexUsageError.codexExecutableNotFound
    }

    private func isExecutable(at path: String) -> Bool {
        fileManager.isExecutableFile(atPath: path)
    }

    private func pathComponents() -> [String] {
        (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
    }
}
