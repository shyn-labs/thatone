import Foundation
import ThatOneCore

public struct HostSnapshot: Equatable {
    public enum State: Equatable {
        case starting
        case idle
        case indexing(done: Int, waiting: Int)
        case pausedByUser
        case paused(String)            // Low Power Mode, a low battery, or an unavailable embedder
    }
    public var state: State = .starting
    public var folders: [String] = []
    public var files: [String: Int] = [:]
    public var segments: [String: Int] = [:]
    public var queue = ServiceQueue(queued: 0, running: 0, failed: 0)
    public var failedFiles: [ServiceFailedFile] = []
    public var hotKeyProblem: String?
    public var photos: PhotosState = .off
    public var photosCount = 0
    public var audio: AudioState = .off
    public var photosEnabled = false          // the saved setting (it can be on while access was revoked)
    public var kinds: [String: Int] = [:]     // indexed files per kind
    public var enabledKinds: Set<String> = Kinds.defaultEnabled
    public init() {}
}

/// Watches the Photos library for changes (the real one registers with PhotoKit).
public protocol PhotosWatching: AnyObject {
    func start()
    func stop()
}

/// Owns the app's one `Engine`: scans and watches folders, indexes in the background, and serves the UI and the socket.
public final class EngineHost: EngineService {
    public var kickDebounce: TimeInterval = 1.0
    public var retryDelay: TimeInterval = 60
    public var uiHandler: ((String) throws -> Void)?

    private let engine: Engine
    private let power: () -> String?
    private let memory: MemoryPressureSource
    private let onChange: (HostSnapshot) -> Void
    private let work = DispatchQueue(label: "thatone.host.work")      // scans and indexing run here, one at a time
    private let lock = NSLock()
    private var current = HostSnapshot()
    private var userPaused = false
    private var stopped = false
    private var cycleQueued = false
    private var watcher: FileWatcher?
    private var retryTimer: DispatchSourceTimer?
    private var lastCountRefresh = Date.distantPast       // touched only on the work queue
    private let assets: AssetProvider?
    private let requestPhotosAccess: ((@escaping (AssetAuthorization) -> Void) -> Void)?
    private let makePhotosWatcher: ((@escaping () -> Void) -> PhotosWatching)?
    private var photosWatcher: PhotosWatching?            // guarded by `lock`
    private var photosAttempt: AssetAuthorization?        // the answer to the last permission request, while Photos is off
    private var photosScanQueued = false
    private let kindsQueue = DispatchQueue(label: "thatone.host.kinds")   // serial: changes apply in the order they were made
    private let audioAvailable: (() -> Bool)?             // nil: this process has no transcriber
    private var desiredKinds: Set<String>                 // what the user last chose; the UI shows this, not what the engine has applied so far

    public init(engine: Engine, power: @escaping () -> String? = PowerPolicy.currentReason,
                memory: MemoryPressureSource = SystemMemoryPressure(),
                assets: AssetProvider? = nil,
                requestPhotosAccess: ((@escaping (AssetAuthorization) -> Void) -> Void)? = nil,
                makePhotosWatcher: ((@escaping () -> Void) -> PhotosWatching)? = nil,
                audioAvailable: (() -> Bool)? = nil,
                onChange: @escaping (HostSnapshot) -> Void) {
        self.engine = engine
        self.power = power
        self.memory = memory
        self.assets = assets
        self.desiredKinds = engine.config.kinds
        self.requestPhotosAccess = requestPhotosAccess
        self.makePhotosWatcher = makePhotosWatcher
        self.audioAvailable = audioAvailable
        self.onChange = onChange
    }

    public var snapshot: HostSnapshot { lock.lock(); defer { lock.unlock() }; return current }

    private func publish(_ change: (inout HostSnapshot) -> Void) {
        lock.lock()
        change(&current)
        let copy = current
        DispatchQueue.main.async { [onChange] in onChange(copy) }     // queued under the lock: delivered in publish order
        lock.unlock()
    }

    // MARK: lifecycle

    public func start() {
        memory.onChange { [weak self] level in if level == .normal { self?.kick() } }       // resume when memory frees up
        work.async { [self] in
            refreshCounts()
            do { _ = try engine.scan() } catch { publish { $0.state = .paused("could not scan: \(error)") } }
            restartWatching()
            startPhotosIfEnabled()
            runCycle()
        }
    }

    public func stop() {
        lock.lock()
        stopped = true
        retryTimer?.cancel()
        let w = watcher
        watcher = nil
        lock.unlock()
        w?.stop()
        stopPhotosWatcher()
    }

    public func pause() {
        lock.lock(); userPaused = true; lock.unlock()
        publish { $0.state = .pausedByUser }
    }

    public func resume() {
        lock.lock(); userPaused = false; lock.unlock()
        kick()
    }

    /// Asks for an indexing pass soon (file events, power changes and retries all land here).
    public func kick() {
        lock.lock()
        if stopped || cycleQueued { lock.unlock(); return }
        cycleQueued = true
        lock.unlock()
        work.asyncAfter(deadline: .now() + kickDebounce) { [weak self] in self?.runCycle() }
    }

    /// Call after the list of watched folders changed.
    public func restartWatching() {
        let fresh = engine.startWatching(onChange: { [weak self] in self?.kick() }, onError: { _ in })
        lock.lock(); let old = watcher; watcher = fresh; lock.unlock()
        old?.stop()
    }

    public func setHotKeyProblem(_ text: String?) { publish { $0.hotKeyProblem = text } }

    // MARK: the indexing pass

    /// Why indexing should wait right now (power, then memory), or nil.
    private func pauseReason() -> String? {
        if let reason = power() { return reason }
        return memory.level == .normal ? nil : "memory is low"
    }

    private func mayContinue() -> Bool {
        lock.lock(); let ok = !stopped && !userPaused; lock.unlock()
        return ok && pauseReason() == nil
    }

    private func runCycle() {
        lock.lock(); cycleQueued = false; let isStopped = stopped; let paused = userPaused; lock.unlock()
        if isStopped { return }
        refreshCounts()
        if paused { publish { $0.state = .pausedByUser }; return }
        if let reason = pauseReason() { publish { $0.state = .paused(reason) }; scheduleRetry(); return }
        let queue = snapshot.queue
        if queue.queued == 0 && queue.running == 0 { publish { $0.state = .idle }; return }
        publish { $0.state = .indexing(done: 0, waiting: $0.queue.queued) }
        do {
            let summary = try engine.runIndexing(
                progress: { [weak self] done, waiting in
                    guard let self else { return }
                    self.publish { $0.state = .indexing(done: done, waiting: waiting) }
                    // Counts (indexed files, queue) otherwise stay frozen until the whole run ends, which can be hours.
                    if Date().timeIntervalSince(lastCountRefresh) >= 3 { lastCountRefresh = Date(); self.refreshCounts() }
                },
                shouldContinue: { [weak self] in self?.mayContinue() ?? false })
            refreshCounts()
            lock.lock(); let userPausedNow = userPaused; let isStoppedNow = stopped; lock.unlock()
            if isStoppedNow { return }
            if summary.stopped {
                if userPausedNow { publish { $0.state = .pausedByUser } }
                else { publish { $0.state = .paused(pauseReason() ?? "waiting") }; scheduleRetry() }
            } else if let reason = summary.pausedReason {
                publish { $0.state = .paused(reason) }
                scheduleRetry()
            } else if summary.retryPending > 0 {
                publish { $0.state = .idle }                  // some files are backing off after an error
                scheduleRetry()
            } else {
                publish { $0.state = .idle }
            }
        } catch EngineError.alreadyIndexing {
            publish { $0.state = .paused("another ThatOne is indexing") }
            scheduleRetry()
        } catch {
            publish { $0.state = .paused("\(error)") }
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        lock.lock()
        retryTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: work)
        timer.schedule(deadline: .now() + retryDelay)
        timer.setEventHandler { [weak self] in self?.kick() }
        retryTimer = timer
        lock.unlock()
        timer.resume()
    }

    private func refreshCounts() {
        guard let s = try? engine.status() else { return }
        publish {
            $0.folders = s.folders
            $0.files = s.counts.filesByStatus
            $0.segments = s.counts.segmentsByModality
            $0.queue = ServiceQueue(queued: s.queue.queued, running: s.queue.running, failed: s.queue.failed)
            $0.failedFiles = s.failedFiles.map { ServiceFailedFile(path: $0.path, note: $0.note) }
            $0.kinds = s.counts.filesByKind
        }
        lock.lock(); let enabledKinds = desiredKinds; lock.unlock()
        let needsWhisper = enabledKinds.contains("audio") || enabledKinds.contains("video")
        let audio: AudioState = !needsWhisper ? .off : (audioAvailable?() == true ? .ready : .modelMissing)
        publish { $0.enabledKinds = enabledKinds; $0.audio = audio }
        publishPhotosState()
    }

    // MARK: Apple Photos

    private func currentPhotosState() -> PhotosState {
        let auth = assets?.authorization() ?? .denied
        if engine.config.photos { return PhotosState.state(enabled: true, authorization: auth) }
        lock.lock(); let attempt = photosAttempt; lock.unlock()
        // A refusal is shown only while macOS still refuses (the user may have allowed it in System Settings since).
        if attempt == .notDetermined && auth == .notDetermined { return .needsPermission }
        if let attempt, attempt == .denied || attempt == .restricted, auth == attempt { return PhotosState.state(enabled: true, authorization: attempt) }
        return .off
    }

    private func publishPhotosState() {
        let state = currentPhotosState()
        let count = (try? engine.photoCount()) ?? 0
        let enabled = engine.config.photos
        publish { $0.photos = state; $0.photosCount = count; $0.photosEnabled = enabled }
    }

    private func startPhotosIfEnabled() {
        guard engine.config.photos else { publishPhotosState(); return }
        let auth = assets?.authorization() ?? .denied
        if auth == .authorized || auth == .limited {
            startPhotosWatcher()
            _ = try? engine.scanPhotos(retryInCloud: true)       // photos skipped because they were iCloud-only get another look
        }
        publishPhotosState()
    }

    private func startPhotosWatcher() {
        lock.lock()
        guard photosWatcher == nil, let make = makePhotosWatcher else { lock.unlock(); return }
        let watcher = make { [weak self] in self?.photosChanged() }
        photosWatcher = watcher
        lock.unlock()
        watcher.start()
    }

    private func stopPhotosWatcher() {
        lock.lock(); let watcher = photosWatcher; photosWatcher = nil; lock.unlock()
        watcher?.stop()
    }

    /// Photos reports every edit; rescan at most every few seconds.
    private func photosChanged() {
        lock.lock()
        if photosScanQueued || stopped { lock.unlock(); return }
        photosScanQueued = true
        lock.unlock()
        // Scans run beside indexing (the engine is thread-safe), not behind it.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(kickDebounce * 3, 0.05)) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.photosScanQueued = false; self.lock.unlock()
            _ = try? self.engine.scanPhotos()
            self.refreshCounts()
            self.kick()
        }
    }

    /// Turns Apple Photos on (asking macOS for permission if needed) or off (forgetting everything from it).
    /// Neither waits behind a long indexing run: the engine is thread-safe, so this runs beside it.
    public func setPhotos(_ on: Bool) {
        let background = DispatchQueue.global(qos: .userInitiated)
        guard on else {
            stopPhotosWatcher()
            lock.lock(); photosAttempt = nil; lock.unlock()
            background.async { [self] in
                try? engine.setPhotos(false)
                refreshCounts()
            }
            return
        }
        let finish: (AssetAuthorization) -> Void = { [self] auth in
            lock.lock(); photosAttempt = auth; lock.unlock()
            guard auth == .authorized || auth == .limited else { publishPhotosState(); return }
            try? engine.setPhotos(true)
            startPhotosWatcher()
            _ = try? engine.scanPhotos(retryInCloud: true)
            refreshCounts()
            kick()
        }
        let auth = assets?.authorization() ?? .restricted
        if auth == .notDetermined, let request = requestPhotosAccess {
            lock.lock(); photosAttempt = .notDetermined; lock.unlock()
            background.async { [self] in publishPhotosState() }          // "waiting for your answer"
            DispatchQueue.main.async { request { answer in background.async { finish(answer) } } }   // never blocks a queue
        } else {
            background.async { finish(auth) }
        }
    }

    // MARK: what to index

    /// Switches kinds of files on or off. A kind switched off disappears at once; one switched on is scanned for.
    public func setKinds(_ kinds: Set<String>) {
        let wanted = kinds.intersection(Kinds.all)
        lock.lock(); desiredKinds = wanted; lock.unlock()
        publish { $0.enabledKinds = wanted }              // the switch shows the new value at once and stays there
        kindsQueue.async { [self] in
            try? engine.setKinds(wanted)
            _ = try? engine.scan()
            refreshCounts()
            kick()
        }
    }

    // MARK: folder management for the UI

    public func removeFolder(_ path: String) throws {
        try engine.removeFolder(path)
        restartWatching()
        refreshCounts()
    }

    /// Queues the files that failed three times again (the frame cutter forgets which files stalled, too).
    public func retryFailed() throws {
        try engine.retryFailed()
        kick()
    }

    // MARK: EngineService

    public func search(_ q: ServiceQuery) throws -> ServiceSearchResult {
        let filters = SearchFilters(kinds: Set(q.kinds), folder: q.folder, since: q.since)
        if q.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ServiceSearchResult(hits: try Searcher(store: engine.store).recent(filters: filters, limit: q.limit).map(ServiceHit.init),
                                       notice: nil)
        }
        let response = try engine.search(q.query, filters: filters, limit: q.limit)
        return ServiceSearchResult(hits: response.hits.map(ServiceHit.init), notice: response.notice)
    }

    public func similar(path: String, limit: Int) throws -> ServiceSearchResult {
        let response = try engine.similar(toPath: path, limit: limit)
        return ServiceSearchResult(hits: response.hits.map(ServiceHit.init), notice: response.notice)
    }

    public func status() throws -> ServiceStatus {
        let s = snapshot
        let (state, detail): (String, String)
        switch s.state {
        case .starting: (state, detail) = ("starting", "")
        case .idle: (state, detail) = ("idle", "")
        case .indexing(let done, let waiting): (state, detail) = ("indexing", "\(done) of \(done + waiting)")
        case .pausedByUser: (state, detail) = ("paused", "paused by you")
        case .paused(let reason): (state, detail) = ("paused", reason)
        }
        return ServiceStatus(state: state, detail: detail, folders: s.folders, files: s.files, segments: s.segments,
                             queue: s.queue, failedFiles: s.failedFiles, photos: s.photos.label, kinds: s.kinds)
    }

    public func index(folders: [String]) throws -> Int {
        for folder in folders { try engine.addFolder(folder) }
        restartWatching()
        let queued = try engine.scan().enqueued
        refreshCounts()
        lock.lock(); let held = userPaused; lock.unlock()
        if queued > 0 && !held {
            // Say so now: a client polling right after this call must not see "idle" during the debounce.
            publish { $0.state = .indexing(done: 0, waiting: $0.queue.queued) }
        }
        kick()
        return queued
    }

    public func forget(path: String) throws {
        try engine.forget(path: path)
        refreshCounts()
    }

    public func exclude(path: String) throws {
        try engine.exclude(path)
        refreshCounts()
    }

    public func ui(action: String) throws {
        guard let handler = uiHandler else { throw ServiceError.unsupported("the app has no window to \(action)") }
        try handler(action)
    }
}
