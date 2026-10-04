import AppKit
import Darwin

if CommandLine.arguments.contains("--claude-statusline") {
    do {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        if let snapshot = try ClaudeCodeStatusLine.capture(data), !CommandLine.arguments.contains("--quiet") {
            let windows = [snapshot.fiveHour.map { "5h: \($0.usedPercent)%" }, snapshot.sevenDay.map { "7d: \($0.usedPercent)%" }].compactMap { $0 }
            print("Claude • " + windows.joined(separator: " • "))
        }
    } catch {
        // Keep terminal output quiet; the app shows the last valid reading and its age.
        exit(1)
    }
} else if CommandLine.arguments.contains("--setup-claude-statusline") {
    do {
        guard let executableURL = Bundle.main.executableURL else { exit(1) }
        try ClaudeCodeStatusLine.install(executableURL: executableURL)
        print("Claude local usage enabled. Readings appear after Claude Code activity.")
    } catch {
        fputs("Could not enable Claude local usage: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
} else if CommandLine.arguments.contains("--backfill-claude") {
    do {
        let base = AccountProfileStore.baseSupportURL()
        let source = ClaudeCodeTokenUsageSource(indexStore: TokenUsageSessionIndexStore(
            cacheURL: base.appendingPathComponent("claude-token-index.json")
        ))
        let start = Date()
        let report = try source.usageReport()
        try TokenUsageReportCacheStore(cacheURL: base.appendingPathComponent("claude-token-report.json")).save(report)
        print("Claude backfill: \(String(format: "%.3f", Date().timeIntervalSince(start)))s")
        print("7d \(UIFormatters.costString(report.week.estimatedCostUSD)) • 30d \(UIFormatters.costString(report.month.estimatedCostUSD)) • all-time \(UIFormatters.costString(report.allTime.estimatedCostUSD))")
        let cachedStart = Date()
        let cached = try source.usageReport()
        let result = cached.allTime == report.allTime ? "totals match" : "active session logs changed during verification"
        print("Cached scan: \(String(format: "%.3f", Date().timeIntervalSince(cachedStart)))s; \(result)")
    } catch {
        fputs("Claude backfill failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
} else if CommandLine.arguments.contains("--refresh-claude-usage") {
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0
    Task.detached {
        do {
            if let snapshot = try await ClaudeCodeUsageSource().refresh(force: true) {
                let five = snapshot.fiveHour.map { "\($0.usedPercent)%" } ?? "unavailable"
                let week = snapshot.sevenDay.map { "\($0.usedPercent)%" } ?? "unavailable"
                print("5h \(five)")
                print("7d \(week)")
            } else {
                fputs("Claude usage refresh is cooling down.\n", stderr)
                exitCode = 1
            }
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exitCode = 1
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(exitCode)
} else if CommandLine.arguments.contains("--self-test") {
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0

    Task.detached {
        do {
            try await SelfTestRunner().run()
        } catch {
            fputs("Self-test failed: \(error.localizedDescription)\n", stderr)
            exitCode = 1
        }
        semaphore.signal()
    }

    semaphore.wait()
    exit(exitCode)
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
