import Foundation
import ThatOneCore

/// One loaded speech model. The real one wraps WhisperKit; tests use a fake so no model is ever loaded in a test.
public protocol SpeechEngine: AnyObject {
    func transcribe(path: String, maxSeconds: Double, shouldContinue: @escaping () -> Bool) async throws -> [TranscriptSegment]
}

/// Loads the model on first use, keeps it for `idleSeconds` after the last use, then lets go of it (the model holds
/// gigabytes). Everything blocking happens on the caller's thread, which is never the main thread.
public final class SpeechSession: Transcriber {
    private let locate: () -> URL?
    private let load: (URL) async throws -> SpeechEngine
    private let idleSeconds: TimeInterval
    private let scheduler: (TimeInterval, @escaping () -> Void) -> DispatchWorkItem
    private let lock = NSLock()
    private var engine: SpeechEngine?
    private var unloadTimer: DispatchWorkItem?
    private(set) var loads = 0
    private(set) var unloads = 0

    public init(locate: @escaping () -> URL?, idleSeconds: TimeInterval = 120,
                scheduler: @escaping (TimeInterval, @escaping () -> Void) -> DispatchWorkItem = SpeechSession.dispatchScheduler,
                load: @escaping (URL) async throws -> SpeechEngine) {
        self.locate = locate
        self.idleSeconds = idleSeconds
        self.scheduler = scheduler
        self.load = load
    }

    public static let dispatchScheduler: (TimeInterval, @escaping () -> Void) -> DispatchWorkItem = { delay, body in
        let item = DispatchWorkItem(block: body)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: item)
        return item
    }

    public var isAvailable: Bool { locate() != nil }
    public var isLoaded: Bool { lock.lock(); defer { lock.unlock() }; return engine != nil }

    public func transcribe(_ url: URL, maxSeconds: Double, shouldContinue: () -> Bool) throws -> [TranscriptSegment] {
        lock.lock(); unloadTimer?.cancel(); unloadTimer = nil; lock.unlock()
        defer { armUnloadTimer() }
        let loaded = try current()
        return try withoutActuallyEscaping(shouldContinue) { stop in
            // The engine (WhisperKit) can still call its callback from its own tasks after `transcribe` has returned, so it
            // gets a gate that forgets `stop` when this call ends instead of `stop` itself.
            let gate = StopGate(stop)
            defer { gate.close() }
            let callback: () -> Bool = { gate.check() }
            let segments: [TranscriptSegment] = try Self.blocking {
                do { return try await loaded.transcribe(path: url.path, maxSeconds: maxSeconds, shouldContinue: callback) }
                catch let failure as TranscribeFailure { throw failure }
                catch { throw TranscribeFailure.failed(String(describing: error)) }
            }
            // A stop that was asked for once means the engine may have quit early: what it returned is a part, never
            // stored as the whole file even if the pressure cleared a moment later.
            if gate.wasStopped { throw TranscribeFailure.interrupted }
            return segments
        }
    }

    private func current() throws -> SpeechEngine {
        lock.lock(); if let engine { lock.unlock(); return engine }; lock.unlock()
        guard let folder = locate() else { throw TranscribeFailure.unavailable("the speech model was not found") }
        let loadFolder = load
        let fresh: SpeechEngine = try Self.blocking {
            do { return try await loadFolder(folder) }
            catch { throw TranscribeFailure.unavailable("the speech model could not be loaded: \(error)") }
        }
        lock.lock(); engine = fresh; loads += 1; lock.unlock()
        return fresh
    }

    private func armUnloadTimer() {
        lock.lock(); defer { lock.unlock() }
        unloadTimer?.cancel()
        unloadTimer = scheduler(idleSeconds) { [weak self] in self?.unload() }
    }

    /// Lets go of the model now (idle timeout, or memory pressure).
    public func unload() {
        lock.lock()
        if engine != nil { engine = nil; unloads += 1 }
        unloadTimer = nil
        lock.unlock()
    }

    /// Runs async work to completion from synchronous code on a non-main thread.
    private static func blocking<T>(_ work: @escaping () async throws -> T) throws -> T {
        let done = DispatchSemaphore(value: 0)
        let result = Box<Result<T, Error>?>(nil)
        Task.detached { result.value = await Result { try await work() }; done.signal() }
        done.wait()
        return try result.value!.get()
    }

    final class StopGate {
        private let lock = NSLock()
        private var stop: (() -> Bool)?
        private var stopped = false
        init(_ stop: @escaping () -> Bool) { self.stop = stop }
        /// Calls `stop` under the lock, so `close()` cannot return while a worker is still inside it.
        func check() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard let stop else { stopped = true; return false }               // closed: stop
            let go = stop()
            if !go { stopped = true }
            return go
        }
        func close() { lock.lock(); stop = nil; lock.unlock() }
        var wasStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    }

    private final class Box<V> { var value: V; init(_ value: V) { self.value = value } }
}
