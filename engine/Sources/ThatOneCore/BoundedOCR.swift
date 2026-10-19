import CoreGraphics
import Foundation

/// Lets a recognizer say how to stop it; `cancel()` runs that handler (at once if it is set after the cancel).
public final class OCRCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    public func onCancel(_ handler: @escaping () -> Void) {
        lock.lock()
        if cancelled { lock.unlock(); handler(); return }
        self.handler = handler
        lock.unlock()
    }

    public func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let run = handler
        handler = nil
        lock.unlock()
        run?()
    }
}

/// Text recognition was refused because `BoundedOCR.maxAbandoned` stuck calls are still parked: nothing ran, so this
/// says nothing about the file. The file waits (deferred) and is tried again once a stuck call returns.
public struct OCRUnavailable: Error, Equatable {
    public init() {}
}

/// Files whose text recognition actually ran past its deadline, in this process. The next attempt of the same file
/// (same path, size and date) fails at once instead of giving Vision the same image again, so a file that always
/// hangs costs one deadline and one stuck thread, not one per attempt. In memory only; "retry failed files" clears it.
public final class OCRTimeoutBreaker: @unchecked Sendable {
    static let capacity = 256          // files remembered, oldest dropped first
    private let lock = NSLock()
    private var keys: [String] = []

    public init() {}

    private static func key(_ path: String, _ size: Int64, _ mtime: Int64) -> String { "\(path)|\(size)|\(mtime)" }

    public func isTripped(path: String, size: Int64, mtime: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return keys.contains(Self.key(path, size, mtime))
    }

    public func noteTimeout(path: String, size: Int64, mtime: Int64) {
        lock.lock(); defer { lock.unlock() }
        let key = Self.key(path, size, mtime)
        guard !keys.contains(key) else { return }
        keys.append(key)
        if keys.count > Self.capacity { keys.removeFirst(keys.count - Self.capacity) }
    }

    public func reset() { lock.lock(); keys = []; lock.unlock() }
    public var count: Int { lock.lock(); defer { lock.unlock() }; return keys.count }
}

/// Text recognition with a deadline. Vision has no timeout and cannot be killed: one call once hung for ten minutes and
/// froze the indexer. Each call runs on its own thread; past `deadline` the request is cancelled (best effort), the
/// thread is let go and the caller gets `ReadFailure.timedOut` ("reading took too long"), which fails that file only.
/// A let-go thread stays parked until Vision returns, so at most `maxAbandoned` may exist at once: beyond that every
/// call fails at once with `OCRUnavailable` (the file waits, it is not failed) instead of parking yet another thread.
public final class BoundedOCR: @unchecked Sendable {
    public typealias Recognizer = (CGImage, OCRCancellation) throws -> String

    public static let defaultDeadline: TimeInterval = 60
    public static let defaultMaxAbandoned = 4
    /// Vision's own work runs on these threads; the default 512 KB of a secondary thread is tight for it.
    static let threadStackSize = 4 << 20

    private let deadline: TimeInterval
    private let maxAbandoned: Int
    private let recognizer: Recognizer
    private let lock = NSLock()
    private var abandoned = 0
    private var started = 0
    private var finishedCalls = 0
    /// Test seam: runs on the caller's thread after the wait timed out and before the timeout is acted on.
    var onDeadlinePassed: (() -> Void)?

    public init(deadline: TimeInterval = BoundedOCR.defaultDeadline, maxAbandoned: Int = BoundedOCR.defaultMaxAbandoned,
                recognizer: @escaping Recognizer = OCR.vision) {
        self.deadline = deadline
        self.maxAbandoned = maxAbandoned
        self.recognizer = recognizer
    }

    /// Calls that timed out and have not returned yet.
    public var abandonedCount: Int { lock.lock(); defer { lock.unlock() }; return abandoned }
    /// Threads started so far (one per call that was not refused).
    public var threadsStarted: Int { lock.lock(); defer { lock.unlock() }; return started }
    /// Calls whose recognizer has returned (on time or not).
    public var callsFinished: Int { lock.lock(); defer { lock.unlock() }; return finishedCalls }

    public func text(in image: CGImage) throws -> String {
        final class Call: @unchecked Sendable {
            var result: Result<String, Error>?
            var finished = false
            var abandoned = false
        }
        lock.lock()
        guard abandoned < maxAbandoned else { lock.unlock(); throw OCRUnavailable() }   // full: no new thread
        started += 1
        lock.unlock()

        let call = Call()
        let cancellation = OCRCancellation()
        let done = DispatchSemaphore(value: 0)
        let recognizer = self.recognizer
        let thread = Thread { [self] in
            let result: Result<String, Error> = autoreleasepool { Result { try recognizer(image, cancellation) } }
            lock.lock()
            call.result = result
            call.finished = true
            finishedCalls += 1
            if call.abandoned { abandoned -= 1 }          // a stuck call finally came back: its slot is free again
            lock.unlock()
            done.signal()
        }
        thread.name = "thatone.ocr"
        thread.stackSize = Self.threadStackSize
        thread.start()

        if done.wait(timeout: .now() + deadline) == .timedOut {
            onDeadlinePassed?()
            lock.lock()
            if !call.finished {                            // checked under the lock: it may have finished just now
                call.abandoned = true
                abandoned += 1
                lock.unlock()
                cancellation.cancel()
                throw ReadFailure.timedOut
            }
            lock.unlock()
        }
        lock.lock(); let result = call.result; lock.unlock()
        guard let result else { throw ReadFailure.timedOut }
        return try result.get()
    }
}
