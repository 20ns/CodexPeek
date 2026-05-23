import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if shouldTerminateForExistingInstance() {
            NSApplication.shared.terminate(nil)
            return
        }

        let controller = AppController(accountStore: AccountProfileStore())
        self.controller = controller
        controller.start()
    }

    private func shouldTerminateForExistingInstance() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }

        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        let runningInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        let existingInstance = runningInstances.first { $0.processIdentifier != currentProcessID }

        if let existingInstance {
            if shouldReplace(existingInstance) {
                terminate(existingInstance)
                return false
            }

            existingInstance.activate(options: [])
            return true
        }

        return false
    }

    private func shouldReplace(_ existingInstance: NSRunningApplication) -> Bool {
        let currentBundleURL = Bundle.main.bundleURL.standardizedFileURL
        let currentExecutableURL = Bundle.main.executableURL?.standardizedFileURL

        if let existingBundleURL = existingInstance.bundleURL?.standardizedFileURL,
           existingBundleURL != currentBundleURL {
            return true
        }

        if let currentExecutableURL,
           let existingExecutableURL = existingInstance.executableURL?.standardizedFileURL,
           existingExecutableURL != currentExecutableURL {
            return true
        }

        guard let launchDate = existingInstance.launchDate,
              let executableURL = currentExecutableURL,
              let modifiedAt = try? executableURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return false
        }

        return modifiedAt > launchDate
    }

    private func terminate(_ existingInstance: NSRunningApplication) {
        _ = existingInstance.terminate()
        if waitUntilTerminated(existingInstance, timeout: 2) {
            return
        }

        _ = existingInstance.forceTerminate()
        _ = waitUntilTerminated(existingInstance, timeout: 1)
    }

    private func waitUntilTerminated(_ application: NSRunningApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !application.isTerminated && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return application.isTerminated
    }
}
