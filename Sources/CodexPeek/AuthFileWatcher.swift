import Foundation
import Darwin

final class AuthFileWatcher {
    private var watchedURL: URL?
    private var lastAuthData: Data?
    private var source: DispatchSourceFileSystemObject?
    private var pendingNotification: DispatchWorkItem?
    private var fileDescriptor: Int32 = -1

    deinit {
        stop()
    }

    func start(watching watchedURL: URL, onChange: @escaping @Sendable () -> Void) {
        stop()
        self.watchedURL = watchedURL
        lastAuthData = try? Data(contentsOf: watchedURL)

        // Watch the parent to catch atomic replacements, but only notify for auth changes.
        fileDescriptor = open(watchedURL.deletingLastPathComponent().path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.notifyAfterDebounce(onChange)
        }
        source.setCancelHandler { [fileDescriptor] in
            close(fileDescriptor)
        }
        source.resume()
        self.source = source
    }

    func stop() {
        pendingNotification?.cancel()
        pendingNotification = nil
        source?.cancel()
        source = nil
        fileDescriptor = -1
        watchedURL = nil
        lastAuthData = nil
    }

    private func notifyAfterDebounce(_ onChange: @escaping @Sendable () -> Void) {
        pendingNotification?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let watchedURL = self.watchedURL else { return }
            let data = try? Data(contentsOf: watchedURL)
            guard data != self.lastAuthData else { return }
            self.lastAuthData = data
            onChange()
        }
        pendingNotification = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: workItem)
    }
}
