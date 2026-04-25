import Foundation
import Darwin

final class AuthFileWatcher {
    private var watchedURL: URL?
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    deinit {
        stop()
    }

    func start(watching watchedURL: URL, onChange: @escaping @Sendable () -> Void) {
        stop()
        self.watchedURL = watchedURL

        fileDescriptor = open(watchedURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            return
        }

        let queue = DispatchQueue.global(qos: .utility)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )

        source.setEventHandler(handler: onChange)
        source.setCancelHandler { [fileDescriptor] in
            close(fileDescriptor)
        }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
        watchedURL = nil
    }
}
