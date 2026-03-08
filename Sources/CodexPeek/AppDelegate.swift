import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let repository = UsageRepository(
            liveSource: CodexCLIProtocolClient(),
            sessionLogSource: CodexSessionLogUsageSource(),
            cacheStore: SnapshotCacheStore(),
            accountInfoSource: AuthJSONAccountInfoSource()
        )

        let controller = AppController(repository: repository)
        self.controller = controller
        controller.start()
    }
}
