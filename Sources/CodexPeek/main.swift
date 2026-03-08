import AppKit
import Darwin

if CommandLine.arguments.contains("--self-test") {
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
