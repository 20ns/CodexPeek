import Foundation
import Darwin

final class AuthFileWatcher {
    private let watchedURL: URL
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    init(watchedURL: URL = URL(fileURLWithPath: NSString(string: "~/.codex").expandingTildeInPath)) {
        self.watchedURL = watchedURL
    }

    deinit {
        stop()
    }

    func start(onChange: @escaping @Sendable () -> Void) {
        stop()

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
    }
}
