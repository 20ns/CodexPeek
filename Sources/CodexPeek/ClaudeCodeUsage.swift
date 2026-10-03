import Foundation

struct ClaudeCodeUsageSnapshot: Codable, Equatable, Sendable {
    var fiveHour: RateLimitWindowSnapshot?
    var sevenDay: RateLimitWindowSnapshot?
    var updatedAt: Date
    var isStale: Bool
}

enum ClaudeCodeStatusLine {
    private static let staleAfter: TimeInterval = 5 * 60
    /// 9999-12-31T23:59:59Z so `Int(reset.timeIntervalSince(now))` cannot trap.
    private static let maxEpoch: TimeInterval = 253_402_300_799
    private static let helperName = ".codexpeek-statusline"
    private static var defaultConfigDirectory: URL {
        ClaudeCodeTokenUsageSource.defaultProjectsRoot().deletingLastPathComponent()
    }

    static var cacheURL: URL {
        defaultConfigDirectory.appendingPathComponent("codexpeek-usage.json")
    }

    static func capture(_ data: Data, at url: URL = cacheURL, now: Date = Date()) throws -> ClaudeCodeUsageSnapshot? {
        guard let incoming = try incomingWindows(data) else { return nil }
        let stored = Cache(updatedAt: now, fiveHour: incoming.fiveHour, sevenDay: incoming.sevenDay)
        try writeCache(stored, to: url)
        return snapshot(stored, now: now)
    }

    static func load(from url: URL = cacheURL, now: Date = Date()) throws -> ClaudeCodeUsageSnapshot? {
        guard let stored = try readCache(url) else { return nil }
        return snapshot(stored, now: now)
    }

    static func install(executableURL: URL, configDirectory: URL = defaultConfigDirectory) throws {
        let settingsURL = configDirectory.appendingPathComponent("settings.json")
        let helperURL = configDirectory.appendingPathComponent(helperName)
        let current = try readSettings(settingsURL)
        let command = statusCommand(helperURL: helperURL, previous: current.command)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try installHelper(from: executableURL, to: helperURL)
        guard command != current.command else { return }
        if current.existed {
            let backup = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.codexpeek-backup")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.copyItem(at: settingsURL, to: backup)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
        }
        var root = current.root
        var status = root["statusLine"] as? [String: Any] ?? [:]
        if !(status["type"] is String) { status["type"] = "command" }
        status["command"] = command
        root["statusLine"] = status
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            .write(to: settingsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
    }

    static func isInstalled(configDirectory: URL = defaultConfigDirectory) throws -> Bool {
        let helperURL = configDirectory.appendingPathComponent(helperName)
        guard let command = try readSettings(configDirectory.appendingPathComponent("settings.json")).command else {
            return false
        }
        return isBridgeCommand(command, helperURL: helperURL)
            && FileManager.default.isExecutableFile(atPath: helperURL.path)
    }

    private struct Cache: Codable {
        var updatedAt: Date
        var fiveHour: Window?
        var sevenDay: Window?
        struct Window: Codable {
            var usedPercent: Int
            var windowDurationMins: Int
            var resetsAt: Date?
        }
    }

    private struct Incoming {
        var fiveHour: Cache.Window?
        var sevenDay: Cache.Window?
    }

    private struct SettingsFile {
        var root: [String: Any] = [:]
        var command: String?
        var existed = false
    }

    private enum Failure: LocalizedError, Equatable {
        case rejected, installFailed
        var errorDescription: String? {
            self == .rejected ? "Claude usage data was rejected." : "Claude local usage could not be installed."
        }
    }

    private static func incomingWindows(_ data: Data) throws -> Incoming? {
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: data) } catch { throw Failure.rejected }
        guard let root = json as? [String: Any] else { throw Failure.rejected }
        guard let rawLimits = root["rate_limits"], !(rawLimits is NSNull) else { return nil }
        guard let limits = rawLimits as? [String: Any] else { throw Failure.rejected }
        var incoming = Incoming()
        incoming.fiveHour = try window(limits["five_hour"], minutes: 300)
        incoming.sevenDay = try window(limits["seven_day"], minutes: 10080)
        return (incoming.fiveHour == nil && incoming.sevenDay == nil) ? nil : incoming
    }

    private static func window(_ raw: Any?, minutes: Int) throws -> Cache.Window? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let object = raw as? [String: Any] else { throw Failure.rejected }
        let resetValue = object["resets_at"]
        guard let percentValue = object["used_percentage"], !(percentValue is NSNull) else {
            if let resetValue, !(resetValue is NSNull) { _ = try epoch(resetValue) }
            return nil
        }
        return Cache.Window(
            usedPercent: try percent(percentValue),
            windowDurationMins: minutes,
            resetsAt: try epoch(resetValue)
        )
    }

    private static func percent(_ value: Any) throws -> Int {
        guard let number = finiteNumber(value), number >= 0 else { throw Failure.rejected }
        return Int(min(number, 100).rounded())
    }

    /// Missing or null is unknown. Present values must be a finite epoch through year 9999.
    private static func epoch(_ value: Any?) throws -> Date? {
        guard let value, !(value is NSNull) else { return nil }
        guard let seconds = finiteNumber(value), seconds >= 0, seconds <= maxEpoch else { throw Failure.rejected }
        return Date(timeIntervalSince1970: seconds)
    }
    private static func finiteNumber(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue.isFinite ? number.doubleValue : nil
    }
    private static func readCache(_ url: URL) throws -> Cache? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let cache: Cache
        do { cache = try decoder.decode(Cache.self, from: Data(contentsOf: url)) } catch { throw Failure.rejected }
        _ = try epoch(cache.updatedAt.timeIntervalSince1970)
        for (window, minutes) in [(cache.fiveHour, 300), (cache.sevenDay, 10080)] {
            guard let window else { continue }
            guard (0...100).contains(window.usedPercent), window.windowDurationMins == minutes else { throw Failure.rejected }
            _ = try epoch(window.resetsAt?.timeIntervalSince1970)
        }
        return cache
    }
    private static func writeCache(_ cache: Cache, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(cache).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func snapshot(_ cache: Cache, now: Date) -> ClaudeCodeUsageSnapshot? {
        func live(_ window: Cache.Window?) -> RateLimitWindowSnapshot? {
            guard let window, window.resetsAt.map({ $0 > now }) ?? true else { return nil }
            return RateLimitWindowSnapshot(usedPercent: window.usedPercent, windowDurationMins: window.windowDurationMins, resetsAt: window.resetsAt)
        }
        let five = live(cache.fiveHour)
        let seven = live(cache.sevenDay)
        guard five != nil || seven != nil else { return nil }
        return ClaudeCodeUsageSnapshot(
            fiveHour: five,
            sevenDay: seven,
            updatedAt: cache.updatedAt,
            isStale: !(0..<staleAfter).contains(now.timeIntervalSince(cache.updatedAt))
        )
    }
    private static func readSettings(_ url: URL) throws -> SettingsFile {
        guard FileManager.default.fileExists(atPath: url.path) else { return SettingsFile() }
        guard let root = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw Failure.installFailed
        }
        guard let rawStatus = root["statusLine"], !(rawStatus is NSNull) else {
            return SettingsFile(root: root, command: nil, existed: true)
        }
        guard let status = rawStatus as? [String: Any] else { throw Failure.installFailed }
        if let type = status["type"], !(type is NSNull), (type as? String) != "command" { throw Failure.installFailed }
        guard let rawCommand = status["command"], !(rawCommand is NSNull) else {
            return SettingsFile(root: root, command: nil, existed: true)
        }
        guard let command = rawCommand as? String else { throw Failure.installFailed }
        return SettingsFile(root: root, command: command, existed: true)
    }

    private static func installHelper(from source: URL, to destination: URL) throws {
        let files = FileManager.default
        do {
            try Data(contentsOf: source).write(to: destination, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        } catch {
            throw Failure.installFailed
        }
    }

    private static func statusCommand(helperURL: URL, previous: String?) -> String {
        let quoted = shellQuote(helperURL.path)
        guard let previous, !previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "\(quoted) --claude-statusline"
        }
        if isBridgeCommand(previous, helperURL: helperURL) { return previous }
        return "codexpeek_input=$(cat; printf x); codexpeek_input=${codexpeek_input%x}; printf '%s' \"$codexpeek_input\" | \(quoted) --claude-statusline --quiet; printf '%s' \"$codexpeek_input\" | (\n\(previous)\n)"
    }

    private static func isBridgeCommand(_ command: String, helperURL: URL) -> Bool {
        let helper = shellQuote(helperURL.path) + " --claude-statusline"
        return command == helper || command.hasPrefix("codexpeek_input=$(cat; printf x); codexpeek_input=${codexpeek_input%x}; printf '%s' \"$codexpeek_input\" | " + helper + " --quiet;")
    }

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
