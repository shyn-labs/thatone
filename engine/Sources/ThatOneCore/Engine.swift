import CoreGraphics
import Foundation

public enum EngineError: Error, Equatable {
    case notAFolder(String)
    case noSidecarCommand
    case alreadyIndexing
    case cannotLock(String)
    case notIndexed(String)
    case unknownEditor(String)
}

public struct SearchResponse {
    public let hits: [SearchHit]
    public let notice: String?
}

public struct IndexingSummary: Equatable {
    /// `failed` counts files, not attempts (a file retried after its back-off and failing again counts once).
    public var indexed = 0, linked = 0, unchanged = 0, removed = 0, skipped = 0, failed = 0
    public var retryPending = 0
    public var deferred = 0
    public var pausedReason: String?
    public var stopped = false
    public init() {}
}

public struct StatusReport {
    public let folders: [String]
    public let counts: StoreCounts
    public let queue: QueueCounts
    public let failedFiles: [(path: String, note: String)]
    /// The first `skippedListLimit` skipped files by path, and how many are skipped in all.
    public var skippedFiles: [(path: String, note: String)] = []
    public var skippedFilesTotal = 0
    public static let skippedListLimit = 200
}

/// The watched folders, readable from the indexing thread while another thread changes them.
private final class RootsBox {
    private let lock = NSLock()
    private var value: [String] = []
    var roots: [String] {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// Whether Photos indexing is on, readable from the indexing thread while the setting changes.
private final class PhotosFlag {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    var isOn: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ on: Bool) { lock.lock(); value = on; lock.unlock() }
}

/// The Photos provider as the indexer sees it: when Photos is switched off, every asset reads as gone, so work already
/// in flight removes its rows instead of re-adding them.
private final class GatedAssets: AssetProvider {
    private let inner: AssetProvider
    private let flag: PhotosFlag
    init(_ inner: AssetProvider, flag: PhotosFlag) { self.inner = inner; self.flag = flag }
    func authorization() -> AssetAuthorization { inner.authorization() }
    func enumerate() throws -> [AssetInfo] {
        guard flag.isOn else { throw EngineError.cannotLock("Photos is off") }
        return try inner.enumerate()
    }
    func info(id: String) -> AssetInfo? { flag.isOn ? inner.info(id: id) : nil }
    func loadImage(id: String, maxSide: Int) -> AssetImage { flag.isOn ? inner.loadImage(id: id, maxSide: maxSide) : .failed("Photos is off") }
}

/// What `runIndexing` was told about stopping, readable by the indexer while it works on one long file.
private final class StopFlag {
    private let lock = NSLock()
    private var check: () -> Bool = { true }
    func set(_ check: @escaping () -> Bool) { lock.lock(); self.check = check; lock.unlock() }
    func shouldContinue() -> Bool { lock.lock(); let c = check; lock.unlock(); return c() }
}

/// Which kinds of files are switched on, readable from the indexing thread while the setting changes.
private final class KindsBox {
    private let lock = NSLock()
    private var value: Set<String>
    private let unavailableNow: () -> Set<String>     // kinds this process cannot index right now (audio and video without a transcriber or its model)
    init(_ value: Set<String>, unavailable: @escaping () -> Set<String> = { [] }) { self.value = value; self.unavailableNow = unavailable }
    var enabled: Set<String> { lock.lock(); let v = value; lock.unlock(); return v.subtracting(unavailableNow()) }
    /// Never purged, claimed or touched by this process: another one (the app) owns them.
    var unavailable: Set<String> { unavailableNow() }
    func set(_ kinds: Set<String>) { lock.lock(); value = kinds; lock.unlock() }
}

/// Frame-cutting deferrals per file in this process. A deterministic per-file error (one frame whose JPEG cannot be
/// written) would otherwise wait and retry forever, re-cutting and re-embedding every frame before the bad one.
final class FrameDeferrals {
    static let limit = 5          // the 5th deferral in a row fails the file instead
    static let capacity = 256     // files remembered, oldest dropped first
    private let lock = NSLock()
    private var counts: [(path: String, count: Int)] = []

    /// Records one more deferral of `path` and returns how many it has had.
    func note(_ path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        if let i = counts.firstIndex(where: { $0.path == path }) { counts[i].count += 1; return counts[i].count }
        counts.append((path, 1))
        if counts.count > Self.capacity { counts.removeFirst(counts.count - Self.capacity) }
        return 1
    }

    func clear(_ path: String) { lock.lock(); counts.removeAll { $0.path == path }; lock.unlock() }
    func clearAll() { lock.lock(); counts = []; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return counts.count }
}

/// Held while one process indexes. Search and status never take it. `flock` belongs to the open file description,
/// so two handles conflict even inside one process (which is what the tests use).
final class IndexLock {
    private var descriptor: Int32
    private init(descriptor: Int32) { self.descriptor = descriptor }

    /// nil when another indexer holds the lock.
    static func acquire(at url: URL) throws -> IndexLock? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw EngineError.cannotLock(String(cString: strerror(errno))) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let busy = errno == EWOULDBLOCK
            let reason = String(cString: strerror(errno))
            close(fd)
            if busy { return nil }
            throw EngineError.cannotLock(reason)
        }
        return IndexLock(descriptor: fd)
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}

/// Creates the real embedder on first use, so opening an existing database never launches the sidecar.
final class LazyEmbedder: Embedder {
    private let factory: () throws -> Embedder
    private var instance: Embedder?
    private let lock = NSLock()
    init(_ factory: @escaping () throws -> Embedder) { self.factory = factory }

    private func resolve() throws -> Embedder {
        lock.lock(); defer { lock.unlock() }
        if let instance { return instance }
        let made = try factory()
        instance = made
        return made
    }

    func info() throws -> SidecarClient.Info { try resolve().info() }
    func embed(_ modality: EmbedModality, role: EmbedRole, inputs: [String]) throws -> [[Float]] {
        try resolve().embed(modality, role: role, inputs: inputs)
    }
}

public final class Engine {
    public let paths: Paths
    public let store: Store
    public let queue: JobQueue
    public let embedder: Embedder

    /// Kinds that cannot be indexed without a usable transcriber: never queued, claimed or purged by such a process.
    static let speechKinds: Set<String> = ["audio", "video"]

    /// How long a file waits after the embedder turned out to be unavailable.
    public static var deferDelaySeconds: Int64 = 60

    // Everything below changes at runtime (folders, exclusions) and is read by the watcher and indexing threads.
    private let stateLock = NSRecursiveLock()
    private var _config: Config
    private var indexer: Indexer
    private var crawler: Crawler
    private var exclusions: Exclusions
    private let codeExclusions: CodeExclusions
    private let rootsBox: RootsBox
    private let ocr: ((CGImage) throws -> String)?
    private let assets: GatedAssets?                 // present only when the app supplied a Photos provider
    private let photosFlag: PhotosFlag
    private let kindsBox: KindsBox
    private let stopFlag = StopFlag()
    private let transcriber: Transcriber?
    private let frameCutter: FrameCutting
    let frameDeferrals = FrameDeferrals()
    /// Files whose OCR ran past its deadline in this process (see `OCRTimeoutBreaker`); cleared by `retryFailed`.
    let ocrTimeouts = OCRTimeoutBreaker()
    // Paths removed or excluded while indexing or scanning was running: forgotten again once the work in flight lands.
    private var pendingForgets: [String] = []
    // The batch claimed by `runIndexing` and not yet finished, so a normal quit can put it back (`releaseClaimed`).
    private let claimLock = NSLock()
    private var inFlight: [String] = []
    /// Test seam: runs after each claim; a throw stands in for the process dying with the batch still claimed.
    var onClaim: (([String]) throws -> Void)?

    public init(paths: Paths, config: Config, keyProvider: KeyProvider,
                embedder: Embedder? = nil, ocr: ((CGImage) throws -> String)? = nil,
                assets: AssetProvider? = nil, transcriber: Transcriber? = nil, frameCutter: FrameCutting = AVFrameCutter()) throws {
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let lazy = LazyEmbedder { embedder ?? Engine.sidecarEmbedder(config: config) }
        let store = try Store(path: paths.db.path, key: try keyProvider.key())
        try store.migrate(dim: try store.storedDim() ?? lazy.info().dim)
        let queue = JobQueue(store: store)
        Indexer.sweepStaleRuns(in: paths.work)   // plaintext copies left behind by an interrupted run
        let roots = RootsBox()
        roots.roots = config.folders
        let exclusions = Exclusions(extraPrefixes: config.exclude)
        self.paths = paths
        self._config = config
        self.store = store
        self.queue = queue
        self.embedder = lazy
        self.rootsBox = roots
        self.ocr = ocr
        self.exclusions = exclusions
        let flag = PhotosFlag(config.photos)
        // Audio and video both need the speech model (video is never indexed without its transcript), checked at each use.
        let kinds = KindsBox(config.kinds, unavailable: { transcriber.map { $0.isAvailable ? [] : Engine.speechKinds } ?? Engine.speechKinds })
        self.kindsBox = kinds
        self.transcriber = transcriber
        self.frameCutter = frameCutter
        let gated = assets.map { GatedAssets($0, flag: flag) }
        self.photosFlag = flag
        self.assets = gated
        let codeExclusions = CodeExclusions()
        self.codeExclusions = codeExclusions
        self.indexer = Engine.makeIndexer(store: store, embedder: lazy, paths: paths, exclusions: exclusions, codeExclusions: codeExclusions, roots: roots, ocr: ocr, assets: gated, kinds: kinds,
                                      transcriber: transcriber, frameCutter: frameCutter, ocrTimeouts: ocrTimeouts, shouldContinue: { [stopFlag] in stopFlag.shouldContinue() })
        self.crawler = Crawler(store: store, queue: queue, exclusions: exclusions, enabledKinds: { kinds.enabled }, unavailableKinds: { kinds.unavailable },
                               codeExclusions: codeExclusions)
    }

    public var config: Config {
        stateLock.lock(); defer { stateLock.unlock() }
        return _config
    }

    private struct Workers { let indexer: Indexer; let crawler: Crawler; let exclusions: Exclusions; let folders: [String] }

    /// A consistent snapshot, taken under the lock and used without it.
    private func workers() -> Workers {
        stateLock.lock(); defer { stateLock.unlock() }
        return Workers(indexer: indexer, crawler: crawler, exclusions: exclusions, folders: _config.folders)
    }

    private static func makeIndexer(store: Store, embedder: Embedder, paths: Paths, exclusions: Exclusions,
                                    codeExclusions: CodeExclusions, roots: RootsBox, ocr: ((CGImage) throws -> String)?, assets: AssetProvider?,
                                    kinds: KindsBox, transcriber: Transcriber?, frameCutter: FrameCutting,
                                    ocrTimeouts: OCRTimeoutBreaker, shouldContinue: @escaping () -> Bool) -> Indexer {
        Indexer(store: store, embedder: embedder, workDir: paths.work, exclusions: exclusions, codeExclusions: codeExclusions,
                roots: { roots.roots }, ocr: ocr ?? { try OCR.text(in: $0) }, assets: assets,
                enabledKinds: { kinds.enabled }, unavailableKinds: { kinds.unavailable }, transcriber: transcriber,
                frameCutter: frameCutter, ocrTimeouts: ocrTimeouts, shouldContinue: shouldContinue)
    }

    static func sidecarEmbedder(config: Config) -> SidecarEmbedder {
        SidecarEmbedder {
            let command = config.sidecar.isEmpty ? Engine.defaultSidecarCommand() : config.sidecar
            guard let executable = command.first else { throw EngineError.noSidecarCommand }
            let environment = ["HF_HUB_OFFLINE": "1", "UV_OFFLINE": "1"].merging(config.sidecarEnv) { _, new in new }
            return try SidecarClient(executable: URL(fileURLWithPath: executable),
                                     arguments: Array(command.dropFirst()), environment: environment)
        }
    }

    /// `uv run --project <repo>/sidecar/gemma python <repo>/sidecar/gemma/worker.py`; the repo defaults to
    /// ~/Documents/Code/thatone and can be overridden with THATONE_REPO.
    static func defaultSidecarCommand() -> [String] {
        let repo = ProcessInfo.processInfo.environment["THATONE_REPO"] ?? NSHomeDirectory() + "/Documents/Code/thatone"
        let project = repo + "/sidecar/gemma"
        let uv = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", NSHomeDirectory() + "/.local/bin/uv"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        let run = ["run", "--project", project, "python", project + "/worker.py"]
        return uv.map { [$0] + run } ?? ["/usr/bin/env", "uv"] + run
    }

    /// Callers hold `stateLock`.
    private func rebuildWorkers() {
        exclusions = Exclusions(extraPrefixes: _config.exclude)
        indexer = Engine.makeIndexer(store: store, embedder: embedder, paths: paths, exclusions: exclusions,
                                     codeExclusions: codeExclusions, roots: rootsBox, ocr: ocr, assets: assets, kinds: kindsBox,
                                     transcriber: transcriber, frameCutter: frameCutter, ocrTimeouts: ocrTimeouts, shouldContinue: { [stopFlag] in stopFlag.shouldContinue() })
        crawler = Crawler(store: store, queue: queue, exclusions: exclusions, enabledKinds: { [kindsBox] in kindsBox.enabled },
                          unavailableKinds: { [kindsBox] in kindsBox.unavailable }, codeExclusions: codeExclusions)
    }

    // MARK: folders and exclusions

    public func addFolder(_ path: String) throws {
        let real = RealPath.of((path as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw EngineError.notAFolder(path)
        }
        stateLock.lock(); defer { stateLock.unlock() }
        pendingForgets.removeAll { $0 == real }          // adding it back cancels an earlier removal
        guard !_config.folders.contains(real) else { return }
        var updated = _config
        updated.folders.append(real)
        try updated.save(to: paths.config)
        _config = updated
        rootsBox.roots = updated.folders
    }

    /// Stops watching `path` and drops everything indexed under it, immediately.
    public func removeFolder(_ path: String) throws {
        let real = RealPath.of((path as NSString).expandingTildeInPath)
        stateLock.lock()
        do {
            var updated = _config
            updated.folders.removeAll { $0 == real }
            try updated.save(to: paths.config)
            _config = updated
            rootsBox.roots = updated.folders
            pendingForgets.append(real)
        } catch { stateLock.unlock(); throw error }
        stateLock.unlock()
        try forget(path: real)                           // the slow part runs without the lock
    }

    /// Never index `path` again (a file or a whole folder) and drop what is indexed under it now.
    public func exclude(_ path: String) throws {
        let real = PhotosPath.isPhotos(path) ? path : RealPath.of((path as NSString).expandingTildeInPath)
        stateLock.lock()
        do {
            if !_config.exclude.contains(real) {
                var updated = _config
                updated.exclude.append(real)
                try updated.save(to: paths.config)
                _config = updated
                rebuildWorkers()
            }
            pendingForgets.append(real)
        } catch { stateLock.unlock(); throw error }
        stateLock.unlock()
        try forget(path: real)
    }

    /// Remembers the global hotkey preset (an id the app understands); nil restores the default.
    public func setHotKey(_ id: String?) throws {
        stateLock.lock(); defer { stateLock.unlock() }
        var updated = _config
        updated.hotKey = id
        try updated.save(to: paths.config)
        _config = updated
    }

    /// Remembers which editor opens code results ("vscode", "zed", "default"); nil goes back to automatic.
    public func setEditor(_ id: String?) throws {
        if let id, !Config.editors.contains(id) { throw EngineError.unknownEditor(id) }
        stateLock.lock(); defer { stateLock.unlock() }
        var updated = _config
        updated.editor = id
        try updated.save(to: paths.config)
        _config = updated
    }

    /// Takes a path off the exclusion list (nothing is re-indexed until the next scan). Absent paths are ignored.
    public func removeExclusion(_ path: String) throws {
        let real = PhotosPath.isPhotos(path) ? path : RealPath.of((path as NSString).expandingTildeInPath)
        stateLock.lock(); defer { stateLock.unlock() }
        guard _config.exclude.contains(real) else { return }
        var updated = _config
        updated.exclude.removeAll { $0 == real }
        try updated.save(to: paths.config)
        _config = updated
        rebuildWorkers()
    }

    /// Drops a file, or everything under a folder, from the index and the queue right now. A file that is still
    /// inside a watched folder comes back on the next scan; use `exclude` to keep it out.
    public func forget(path: String) throws {
        if PhotosPath.isPhotos(path) {                    // a virtual path: never resolved, never a folder
            try store.transaction { try store.removeFile(path: path) }
            try queue.remove(path: path)
            return
        }
        let real = RealPath.of((path as NSString).expandingTildeInPath)
        try store.transaction {
            try store.removeFile(path: real)
            for known in try store.filePaths(under: real) { try store.removeFile(path: known) }
        }
        try queue.remove(path: real)
        try queue.remove(under: real)
    }

    // MARK: indexing

    public func scan() throws -> Crawler.ScanResult {
        let w = workers()
        var result = try w.crawler.scan(roots: w.folders)
        let photos = try scanPhotos()
        result.enqueued += photos.enqueued
        result.purgeQueued += photos.purgeQueued
        try drainForgets()                               // a folder removed during the scan must not keep its new jobs
        return result
    }

    /// Scans Apple Photos (nothing when it is off or the app gave no provider).
    /// `retryInCloud` re-checks photos that were skipped because their original was only in iCloud.
    public func scanPhotos(retryInCloud: Bool = false) throws -> Crawler.ScanResult {
        guard config.photos, let assets else { return Crawler.ScanResult() }
        let w = workers()
        return try w.crawler.scanAssets(provider: assets, retryInCloud: retryInCloud)
    }

    /// Turns Apple Photos indexing on or off. Off drops every Photos row, segment and job at once.
    public func setPhotos(_ on: Bool) throws {
        stateLock.lock()
        var updated = _config
        updated.photos = on
        do { try updated.save(to: paths.config) } catch { stateLock.unlock(); throw error }
        _config = updated
        photosFlag.set(on)
        if on { pendingForgets.removeAll { $0 == PhotosPath.scheme } }
        else { pendingForgets.append(PhotosPath.scheme) }   // work already in flight is cleaned up again after its batch
        stateLock.unlock()
        if !on { try purgePhotos() }
    }

    /// Switches kinds of files on or off. A kind switched off is purged at once (rows, segments, jobs); work already in
    /// flight for it is cleaned up again after its batch. Switching one on only needs a scan.
    public func setKinds(_ kinds: Set<String>) throws {
        let wanted = kinds.intersection(Kinds.all)
        stateLock.lock()
        var updated = _config
        let before = updated.kinds
        updated.kinds = wanted
        do { try updated.save(to: paths.config) } catch { stateLock.unlock(); throw error }
        _config = updated
        kindsBox.set(wanted)
        let disabled = before.subtracting(wanted).sorted()
        for kind in Kinds.all {
            pendingForgets.removeAll { $0 == "kind:" + kind }
            if disabled.contains(kind) { pendingForgets.append("kind:" + kind) }
        }
        stateLock.unlock()
        for kind in disabled { try purgeKind(kind) }
    }

    private func purgeKind(_ kind: String) throws {
        let doomed = try store.filePaths(ofKind: kind)
        try store.transaction { for path in doomed { try store.removeFile(path: path) } }
        for path in doomed { try queue.remove(path: path) }
    }

    private func purgePhotos() throws {
        try store.transaction {
            for path in try store.filePaths(withPrefix: PhotosPath.scheme) { try store.removeFile(path: path) }
        }
        try queue.remove(withPrefix: PhotosPath.scheme)
    }

    /// Repeats `forget` for paths removed or excluded while work that started earlier was still running.
    private func drainForgets() throws {
        stateLock.lock()
        let paths = pendingForgets
        pendingForgets = []
        stateLock.unlock()
        for path in paths {
            if path == PhotosPath.scheme { try purgePhotos() }
            else if path.hasPrefix("kind:") { try purgeKind(String(path.dropFirst(5))) }
            else { try forget(path: path) }
        }
    }

    /// Queues exactly these files (full exclusion rules; code files also by build folder and `.gitignore`).
    public func enqueue(files: [String]) throws -> Int {
        let w = workers()
        let roots = w.folders.map(RealPath.of)
        var queued = 0
        for raw in files {
            let path = RealPath.of(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let kind = Kinds.detect(path), kindsBox.enabled.contains(kind), !w.exclusions.isExcluded(path: path),
                  FileManager.default.fileExists(atPath: path) else { continue }
            if kind == "code" {
                let root = roots.first { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
                if codeExclusions.reason(path: path, root: root) != nil { continue }
            }
            let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            try queue.enqueue(path: path, priority: Int64(modified?.timeIntervalSince1970 ?? 0))
            queued += 1
        }
        return queued
    }

    @discardableResult
    public func runIndexing(batchSize: Int = 8, progress: ((_ done: Int, _ waiting: Int) -> Void)? = nil,
                            shouldContinue: @escaping () -> Bool = { true }) throws -> IndexingSummary {
        // One indexer at a time. Only the holder may requeue jobs left `running`: they belong to a crashed run, never
        // to a live one.
        guard let lock = try IndexLock.acquire(at: paths.home.appendingPathComponent("index.lock")) else {
            throw EngineError.alreadyIndexing
        }
        defer { lock.release() }
        stopFlag.set(shouldContinue)
        defer { stopFlag.set({ true }) }
        // A file that keeps stopping the app is shown as failed, so the next scan leaves it alone until it changes.
        claimLock.lock(); inFlight = []; claimLock.unlock()          // whatever was claimed before is recovered below
        for path in try queue.recoverRunning() { try recordFailure(path, message: JobQueue.crashNote) }
        var summary = IndexingSummary()
        var done = 0
        // Files, not attempts: a failed file comes back after its back-off and may fail again in a long run.
        var failedPaths = Set<String>()
        while true {
            try drainForgets()
            // Checked and claimed under `claimLock`: a quit that has already released the batch cannot see a new one claimed.
            claimLock.lock()
            if !shouldContinue() { claimLock.unlock(); summary.stopped = true; break }
            let batch: [String]
            do {
                // A file recovered after a crash runs alone until it finishes once: only the culprit is blamed if it crashes again.
                let recovered = try queue.claimRecovered(skippingExtensions: ownedElsewhere())
                batch = recovered.isEmpty ? try queue.claim(limit: batchSize, skippingExtensions: ownedElsewhere()) : recovered
            } catch { claimLock.unlock(); throw error }
            inFlight = batch
            claimLock.unlock()
            if batch.isEmpty { break }
            try onClaim?(batch)
            let outcomes = workers().indexer.index(paths: batch)     // a fresh snapshot: an exclusion applies mid-run
            for path in batch {
                let outcome = outcomes[path] ?? .failed("no outcome")
                if case .deferred(let reason) = outcome, reason.hasPrefix(Indexer.frameCuttingUnavailable),
                   frameDeferrals.note(path) >= FrameDeferrals.limit {
                    // The same file kept failing to cut: treat it as the file's problem, not the environment's.
                    let message = "frame cutting failed repeatedly: \(String(reason.prefix(80)))"
                    try recordFailure(path, message: message)
                    try queue.fail(path: path, error: message)
                    landed(path)
                    failedPaths.insert(path)
                    continue
                }
                if case .deferred = outcome {} else { frameDeferrals.clear(path) }
                if case .failed = outcome {} else { failedPaths.remove(path) }     // it got further this time
                switch outcome {
                case .failed(let message): try queue.fail(path: path, error: message); landed(path); failedPaths.insert(path); continue
                case .deferred(let reason):
                    // Only this file's kind waits (no speech model, no frame cutting): images and PDFs go on.
                    let kindOnly = reason.hasPrefix("transcription unavailable") || reason.hasPrefix(Indexer.frameCuttingUnavailable)
                    // Text recognition refused (stuck Vision calls): only files that need OCR wait; the run goes on.
                    let ocrBusy = reason.hasPrefix(Indexer.ocrUnavailable)
                    try queue.requeue(path: path, delaySeconds: kindOnly ? Engine.deferDelaySeconds * 10 : Engine.deferDelaySeconds)
                    landed(path)
                    summary.deferred += 1
                    if summary.pausedReason == nil, !kindOnly, !ocrBusy, reason != "paused" { summary.pausedReason = reason }   // "paused": the loop sees shouldContinue
                    continue
                case .indexed: summary.indexed += 1
                case .linked: summary.linked += 1
                case .unchanged: summary.unchanged += 1
                case .removed: summary.removed += 1
                case .skipped: summary.skipped += 1
                }
                try queue.complete(path: path)
                landed(path)
            }
            try drainForgets()                                // anything removed during this batch is dropped again
            done += batch.count
            progress?(done, try queue.counts().queued)
            if summary.pausedReason != nil { break }       // every remaining file would defer too
        }
        summary.failed = failedPaths.count
        // Jobs waiting out a back-off. Those left for another process are not: counting them would wake a process
        // without the speech model every minute for jobs it never takes.
        summary.retryPending = try queue.claimableCount(skippingExtensions: ownedElsewhere())
        return summary
    }

    /// Extensions of the kinds this process cannot read (audio and video without the speech model). They belong to the
    /// app: their jobs stay queued for it instead of being claimed here and completed as unchanged.
    private func ownedElsewhere() -> Set<String> {
        kindsBox.unavailable.reduce(into: Set<String>()) { $0.formUnion(Kinds.extensions(of: $1)) }
    }

    /// A claimed job that completed, failed or was put back normally: no longer in flight.
    private func landed(_ path: String) {
        claimLock.lock(); inFlight.removeAll { $0 == path }; claimLock.unlock()
    }

    /// For a normal quit: puts the batch being indexed back in the queue without counting an attempt, so the next launch
    /// does not take it for a crash. One short write; idempotent; safe from any thread (the main thread at quit). It
    /// does not wait for the indexing thread, which may still finish some of those files before the process ends.
    public func releaseClaimed() throws {
        claimLock.lock(); defer { claimLock.unlock() }
        guard !inFlight.isEmpty else { return }
        try queue.release(paths: inFlight)
        inFlight = []
    }

    /// Queues the files that failed three times again, with a clean slate: the frame cutter forgets which files
    /// stalled and the frame-cutting deferral counts start over.
    public func retryFailed() throws {
        try queue.retryFailed()
        frameCutter.resetBreaker()
        frameDeferrals.clearAll()
        ocrTimeouts.reset()
    }

    /// Shows a file the engine gave up on as failed (the indexer records its own failures; this is for the engine's).
    /// A file already indexed keeps its content, so it stays searchable: its row stays `indexed` with the current size
    /// and mtime (the scan leaves it alone until it changes) and a note starting `Store.keptAfterFailure`, which lists it
    /// among the failed files and makes the next read (the user's retry) read it again.
    private func recordFailure(_ path: String, message: String) throws {
        var size: Int64 = 0, mtime: Int64 = 0
        if let id = PhotosPath.parse(path)?.id {           // a Photos asset's change signature, so its scan leaves it too
            if let info = assets?.info(id: id) { size = info.pixels; mtime = info.mtime }
        } else {
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            mtime = Int64((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        }
        if let record = try store.fileRecord(path: path), record.status == "indexed", let contentId = record.contentId {
            try store.upsertFile(path: path, contentId: contentId, kind: record.kind, size: size, mtime: mtime,
                                 status: "indexed", note: Store.keptAfterFailure + message)
            return
        }
        try store.upsertFile(path: path, contentId: nil, kind: Kinds.detect(path) ?? "video", size: size, mtime: mtime,
                             status: "failed", note: message)
    }

    /// What the watcher runs for each batch of file events. Safe to call from any thread.
    public func handle(_ changes: [FileWatcher.Change]) throws {
        let w = workers()
        try w.crawler.handle(changes, roots: w.folders)
    }

    /// Watches the configured folders and queues what changes. The caller keeps the returned watcher and calls its
    /// `stop()` when done; `onChange` runs after each handled batch of events (the host uses it to start indexing).
    public func startWatching(onChange: (() -> Void)? = nil, onError: @escaping (Error) -> Void = { _ in }) -> FileWatcher? {
        let roots = config.folders.map { URL(fileURLWithPath: $0) }
        guard !roots.isEmpty else { return nil }
        let watcher = FileWatcher(roots: roots) { [weak self] changes in
            guard let self else { return }
            do { try self.handle(changes); onChange?() } catch { onError(error) }
        }
        if watcher.start() { return watcher }
        watcher.stop()                                    // release the stream's reference to the watcher
        return nil
    }

    // MARK: search and status

    public func search(_ text: String, filters: SearchFilters = SearchFilters(), limit: Int = 10) throws -> SearchResponse {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return SearchResponse(hits: [], notice: nil) }
        var vector: [Float]?
        var notice: String?
        do { vector = try embedder.embed(.text, role: .query, inputs: [text]).first }
        catch { notice = "Embedding model unavailable; showing keyword matches only." }
        let hits = try Searcher(store: store).search(query: text, queryVector: vector, filters: filters, limit: limit)
        return SearchResponse(hits: hits, notice: notice)
    }

    public func recent(filters: SearchFilters = SearchFilters(), limit: Int = 60) throws -> SearchResponse {
        SearchResponse(hits: try Searcher(store: store).recent(filters: filters, limit: limit), notice: nil)
    }

    /// Images that look like the one at `path` (which must be indexed).
    public func similar(toPath path: String, limit: Int = 30, filters: SearchFilters = SearchFilters()) throws -> SearchResponse {
        let real = PhotosPath.isPhotos(path) ? path : RealPath.of((path as NSString).expandingTildeInPath)
        guard let contentId = try store.fileRecord(path: real)?.contentId else { throw EngineError.notIndexed(path) }
        return SearchResponse(hits: try Searcher(store: store).similar(toContentId: contentId, filters: filters, limit: limit),
                              notice: nil)
    }

    /// How many Apple Photos assets are indexed.
    public func photoCount() throws -> Int {
        Int(try store.int("select count(*) from files where substr(path, 1, \(PhotosPath.scheme.count)) = ? and status = 'indexed'",
                          [.text(PhotosPath.scheme)]) ?? 0)
    }

    public func status() throws -> StatusReport {
        let skipped = try store.skippedFiles(limit: StatusReport.skippedListLimit)
        return StatusReport(folders: config.folders, counts: try store.counts(), queue: try queue.counts(),
                            failedFiles: try store.failedFiles(), skippedFiles: skipped.files, skippedFilesTotal: skipped.total)
    }
}
