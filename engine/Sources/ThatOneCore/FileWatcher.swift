import CoreServices
import Foundation

/// Reports file-level changes under `roots` (created, modified, renamed, removed) via FSEvents.
public final class FileWatcher {
    public struct Change: Equatable {
        public let path: String
        public let removedOrRenamed: Bool
        public init(path: String, removedOrRenamed: Bool) { self.path = path; self.removedOrRenamed = removedOrRenamed }
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "thatone.filewatcher")
    private let handler: ([Change]) -> Void

    public init(roots: [URL], latency: TimeInterval = 0.3, handler: @escaping ([Change]) -> Void) {
        self.handler = handler
        // The stream retains the watcher until it is released in stop(), so a callback that is already running can
        // never see a freed object.
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in _ = Unmanaged<FileWatcher>.fromOpaque(info!).retain(); return info },
            release: { info in Unmanaged<FileWatcher>.fromOpaque(info!).release() },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            let me = Unmanaged<FileWatcher>.fromOpaque(info!).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as! [String]
            var changes: [Change] = []
            for i in 0..<count {
                let f = flags[i]
                guard f & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0 else { continue }
                let gone = f & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) != 0
                changes.append(Change(path: list[i], removedOrRenamed: gone))
            }
            if !changes.isEmpty { me.handler(changes) }
        }
        stream = FSEventStreamCreate(
            nil, callback, &context, roots.map { $0.path } as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                     | kFSEventStreamCreateFlagNoDefer))
    }

    /// false when FSEvents refused to create or start the stream.
    @discardableResult
    public func start() -> Bool {
        guard let stream else { return false }
        FSEventStreamSetDispatchQueue(stream, queue)
        return FSEventStreamStart(stream)
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}
