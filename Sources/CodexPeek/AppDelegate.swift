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
            existingInstance.activate(options: [])
            return true
        }

        return false
    }
}
