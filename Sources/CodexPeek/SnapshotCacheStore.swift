import Foundation

final class SnapshotCacheStore: UsageSnapshotStoring, @unchecked Sendable {
    private let cacheURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        cacheURL: URL = SnapshotCacheStore.defaultCacheURL(),
        fileManager: FileManager = .default
    ) {
        self.cacheURL = cacheURL
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() throws -> CodexUsageSnapshot? {
        guard fileManager.fileExists(atPath: cacheURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: cacheURL)
        return try decoder.decode(CodexUsageSnapshot.self, from: data)
    }

    func save(_ snapshot: CodexUsageSnapshot) throws {
        try fileManager.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let data = try encoder.encode(snapshot)
        try data.write(to: cacheURL, options: .atomic)
    }

    static func defaultCacheURL() -> URL {
        defaultCacheURL(profileID: "default")
    }

    static func defaultCacheURL(profileID: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("CodexPeek", isDirectory: true)
            .appendingPathComponent("Snapshots", isDirectory: true)
            .appendingPathComponent("\(profileID).json")
    }
}
