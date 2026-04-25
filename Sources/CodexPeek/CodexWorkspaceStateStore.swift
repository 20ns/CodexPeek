import Foundation

struct CodexWorkspaceStateSanitizationResult: Equatable {
    var removedWorkspacePaths: [String]

    var didChange: Bool {
        !removedWorkspacePaths.isEmpty
    }
}

final class CodexWorkspaceStateStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let globalStateURL: URL

    init(
        fileManager: FileManager = .default,
        globalStateURL: URL = URL(fileURLWithPath: NSString(string: "~/.codex/.codex-global-state.json").expandingTildeInPath)
    ) {
        self.fileManager = fileManager
        self.globalStateURL = globalStateURL
    }

    func sanitizePersistedWorkspaceState() throws -> CodexWorkspaceStateSanitizationResult {
        guard fileManager.fileExists(atPath: globalStateURL.path) else {
            return CodexWorkspaceStateSanitizationResult(removedWorkspacePaths: [])
        }

        let data = try Data(contentsOf: globalStateURL)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexUsageError.invalidResponse("invalid Codex global state")
        }

        var removedPaths = Set<String>()

        if let savedRoots = object["electron-saved-workspace-roots"] as? [Any] {
            let result = sanitizePathArray(savedRoots)
            object["electron-saved-workspace-roots"] = result.paths
            removedPaths.formUnion(result.removedPaths)
        }

        if let activeRoots = object["active-workspace-roots"] as? [Any] {
            let result = sanitizePathArray(activeRoots)
            object["active-workspace-roots"] = result.paths
            removedPaths.formUnion(result.removedPaths)
        }

        if let labels = object["electron-workspace-root-labels"] as? [String: Any] {
            let filtered = labels.filter { workspacePathExists($0.key) }
            removedPaths.formUnion(labels.keys.filter { !workspacePathExists($0) })
            object["electron-workspace-root-labels"] = filtered
        }

        if var atomState = object["electron-persisted-atom-state"] as? [String: Any] {
            if let collapsedGroups = atomState["sidebar-collapsed-groups"] as? [String: Any] {
                let filtered = collapsedGroups.filter { workspacePathExists($0.key) }
                removedPaths.formUnion(collapsedGroups.keys.filter { !workspacePathExists($0) })
                atomState["sidebar-collapsed-groups"] = filtered
            }
            object["electron-persisted-atom-state"] = atomState
        }

        let result = CodexWorkspaceStateSanitizationResult(
            removedWorkspacePaths: removedPaths.sorted()
        )
        guard result.didChange else {
            return result
        }

        let sanitizedData = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try sanitizedData.write(to: globalStateURL, options: .atomic)
        return result
    }

    private func sanitizePathArray(_ rawPaths: [Any]) -> (paths: [String], removedPaths: Set<String>) {
        var sanitizedPaths: [String] = []
        var removedPaths = Set<String>()

        for rawPath in rawPaths {
            guard let path = rawPath as? String else {
                continue
            }

            if workspacePathExists(path) {
                sanitizedPaths.append(path)
            } else {
                removedPaths.insert(path)
            }
        }

        return (sanitizedPaths, removedPaths)
    }

    private func workspacePathExists(_ path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }
}
