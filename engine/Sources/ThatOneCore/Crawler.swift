import Foundation

public final class Crawler {
    public struct ScanResult: Equatable {
        public var enqueued = 0
        public var purgeQueued = 0
        public init(enqueued: Int = 0, purgeQueued: Int = 0) { self.enqueued = enqueued; self.purgeQueued = purgeQueued }
    }

    private let store: Store
    private let queue: JobQueue
    private let exclusions: Exclusions
    private let enabledKinds: () -> Set<String>
    private let unavailableKinds: () -> Set<String>

    public init(store: Store, queue: JobQueue, exclusions: Exclusions = Exclusions(),
                enabledKinds: @escaping () -> Set<String> = { Kinds.defaultEnabled },
                unavailableKinds: @escaping () -> Set<String> = { [] }) {
        self.store = store
        self.queue = queue
        self.exclusions = exclusions
        self.enabledKinds = enabledKinds
        self.unavailableKinds = unavailableKinds
    }

    /// A supported kind that is switched on.
    private func isIndexable(_ path: String) -> Bool { Kinds.detect(path).map { enabledKinds().contains($0) } ?? false }

    /// Queues new or changed images under each root, and a purge job for every recorded path it no longer sees
    /// (deleted, moved away, or newly excluded). The indexer does the actual forgetting.
    public func scan(roots: [String]) throws -> ScanResult {
        var result = ScanResult()
        let unavailable = unavailableKinds()            // kinds this process cannot read (audio and video in the CLI): what it holds stays put
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        for rawRoot in roots {
            let root = RealPath.of(rawRoot)
            // An unplugged drive or a folder we may not read looks exactly like an empty one. Leave its index alone.
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: root) else { continue }
            var seen = Set<String>()
            var unreadable: [String] = []
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys, options: [.skipsPackageDescendants],
                errorHandler: { url, _ in unreadable.append(url.path); return true })
            else { continue }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isDirectory == true {
                    if exclusions.isExcludedDirectory(named: url.lastPathComponent)
                        || exclusions.isExcluded(path: url.path + "/x", root: root) {
                        enumerator.skipDescendants()
                    } else if !FileManager.default.isReadableFile(atPath: url.path)
                                || !FileManager.default.isExecutableFile(atPath: url.path) {
                        unreadable.append(url.path)    // listed but not enterable: what is inside is unknown, not gone
                    }
                    continue
                }
                guard values.isRegularFile == true, isIndexable(url.path),
                      !exclusions.isExcluded(path: url.path, root: root) else { continue }
                let path = url.path
                seen.insert(path)
                let size = Int64(values.fileSize ?? 0)
                let mtime = Int64(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
                if let record = try store.fileRecord(path: path), record.size == size, record.mtime == mtime { continue }
                try queue.enqueue(path: path, priority: mtime)
                result.enqueued += 1
            }
            for known in try store.filePaths(under: root)
                where !seen.contains(known) && !unreadable.contains(where: { known.hasPrefix($0 + "/") })
                    && !(Kinds.detect(known).map { unavailable.contains($0) } ?? false) {
                try queue.enqueue(path: known, priority: Int64.min)
                result.purgeQueued += 1
            }
        }
        return result
    }

    /// Queues new or changed Apple Photos assets and a purge job for every recorded `photos:` path that is no longer
    /// there (deleted, hidden, excluded, or outside what limited access allows). A library that cannot be read is never
    /// mistaken for an empty one: no authorization, or an enumeration error, changes nothing.
    public func scanAssets(provider: AssetProvider, retryInCloud: Bool = false) throws -> ScanResult {
        var result = ScanResult()
        switch provider.authorization() {
        case .authorized, .limited: break
        case .notDetermined, .denied, .restricted: return result
        }
        let assets: [AssetInfo]
        do { assets = try provider.enumerate() } catch { return result }
        // An unmounted or migrating library can look empty. Rows already recorded are never purged on that evidence.
        if assets.isEmpty, try !store.filePaths(withPrefix: PhotosPath.scheme).isEmpty { return result }
        var seen = Set<String>()
        for asset in assets {
            let path = asset.path
            if exclusions.isExcluded(path: path) { continue }
            seen.insert(path)
            if let record = try store.fileRecord(path: path), record.size == asset.pixels, record.mtime == asset.mtime,
               !(retryInCloud && record.note == AssetNotes.inCloud) { continue }
            try queue.enqueue(path: path, priority: asset.mtime)
            result.enqueued += 1
        }
        for known in try store.filePaths(withPrefix: PhotosPath.scheme) where !seen.contains(known) {
            try queue.enqueue(path: known, priority: Int64.min)
            result.purgeQueued += 1
        }
        return result
    }

    /// Applies FSEvents changes: queues files that appeared or changed, and a purge job for paths that went away.
    public func handle(_ changes: [FileWatcher.Change], roots: [String]) throws {
        let realRoots = roots.map(RealPath.of)
        for change in changes {
            guard let root = realRoots.first(where: { change.path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) else { continue }
            if FileManager.default.fileExists(atPath: change.path) {
                guard isIndexable(change.path), !exclusions.isExcluded(path: change.path, root: root) else { continue }
                let modified = (try? FileManager.default.attributesOfItem(atPath: change.path)[.modificationDate]) as? Date
                try queue.enqueue(path: change.path, priority: Int64(modified?.timeIntervalSince1970 ?? 0))
            } else {
                try queue.enqueue(path: change.path, priority: Int64.min)
            }
        }
    }
}
