import XCTest
@testable import ThatOneCore

final class JobQueueTests: XCTestCase {
    var now: Int64 = 1000

    func makeQueue() throws -> JobQueue {
        let store = try Store.open(path: TestSupport.tempDir().appendingPathComponent("q.db").path,
                                   key: TestSupport.key, dim: 4)
        return JobQueue(store: store, clock: { [unowned self] in self.now })
    }

    func testNewestFirstAndClaimMarksRunning() throws {
        let q = try makeQueue()
        try q.enqueue(path: "/old.png", priority: 10)
        try q.enqueue(path: "/new.png", priority: 30)
        try q.enqueue(path: "/mid.png", priority: 20)
        XCTAssertEqual(try q.claim(limit: 2), ["/new.png", "/mid.png"])
        XCTAssertEqual(try q.counts(), QueueCounts(queued: 1, running: 2, failed: 0))
        XCTAssertEqual(try q.claim(limit: 5), ["/old.png"])
    }

    func testRemovalChecksRunLast() throws {
        let q = try makeQueue()
        try q.enqueue(path: "/gone.png", priority: Int64.min)
        try q.enqueue(path: "/new.png", priority: 5)
        XCTAssertEqual(try q.claim(limit: 1), ["/new.png"])
    }

    func testCompleteRemovesTheJob() throws {
        let q = try makeQueue()
        try q.enqueue(path: "/a.png", priority: 1)
        _ = try q.claim(limit: 1)
        try q.complete(path: "/a.png")
        XCTAssertEqual(try q.counts(), QueueCounts(queued: 0, running: 0, failed: 0))
    }

    func testFailBacksOffThenGivesUp() throws {
        let q = try makeQueue()
        try q.enqueue(path: "/a.png", priority: 1)
        _ = try q.claim(limit: 1)
        try q.fail(path: "/a.png", error: "boom")
        XCTAssertEqual(try q.claim(limit: 1), [])            // backing off for 30 s
        now += 30
        XCTAssertEqual(try q.claim(limit: 1), ["/a.png"])
        try q.fail(path: "/a.png", error: "boom again")
        now += 59
        XCTAssertEqual(try q.claim(limit: 1), [])            // 60 s this time
        now += 1
        XCTAssertEqual(try q.claim(limit: 1), ["/a.png"])
        try q.fail(path: "/a.png", error: "third")
        XCTAssertEqual(try q.counts(), QueueCounts(queued: 0, running: 0, failed: 1))
        now += 100_000
        XCTAssertEqual(try q.claim(limit: 1), [])
        XCTAssertEqual(try q.failedJobs().map { "\($0.path)|\($0.error)" }, ["/a.png|third"])
    }

    func testRecoverRunningRequeuesAfterACrash() throws {
        let q = try makeQueue()
        try q.enqueue(path: "/a.png", priority: 1)
        _ = try q.claim(limit: 1)
        try q.recoverRunning()
        XCTAssertEqual(try q.claim(limit: 1), ["/a.png"])
    }

    func testEnqueueDoesNotDisturbARunningJob() throws {
        let q = try makeQueue()
        try q.enqueue(path: "/a.png", priority: 1)
        _ = try q.claim(limit: 1)
        try q.enqueue(path: "/a.png", priority: 99)
        XCTAssertEqual(try q.counts(), QueueCounts(queued: 0, running: 1, failed: 0))
    }

    func testReenqueueAndRetryResetAFailedJob() throws {
        let q = try makeQueue()
        for path in ["/a.png", "/b.png"] {
            try q.enqueue(path: path, priority: 1)
            for _ in 0..<3 {
                now += 10_000
                _ = try q.claim(limit: 5)
                try q.fail(path: path, error: "x")
            }
        }
        XCTAssertEqual(try q.counts().failed, 2)
        try q.enqueue(path: "/a.png", priority: 2)            // the file changed: try again from scratch
        XCTAssertEqual(try q.counts(), QueueCounts(queued: 1, running: 0, failed: 1))
        try q.retryFailed()
        XCTAssertEqual(try q.counts(), QueueCounts(queued: 2, running: 0, failed: 0))
    }

    func testRemoveByPathAndByFolderIsLiteral() throws {
        let q = try makeQueue()
        for p in ["/pics/100%_done/a.png", "/pics/100x_done/b.png", "/pics/other.png"] { try q.enqueue(path: p, priority: 1) }
        try q.remove(under: "/pics/100%_done")
        XCTAssertEqual(try q.counts().queued, 2)
        try q.remove(path: "/pics/other.png")
        XCTAssertEqual(try q.claim(limit: 10), ["/pics/100x_done/b.png"])
    }

    func testRequeueKeepsAttemptsAndWaits() throws {
        let q = try makeQueue()
        try q.enqueue(path: "/a.png", priority: 1)
        _ = try q.claim(limit: 1)
        try q.fail(path: "/a.png", error: "x")                       // attempts = 1, waits 30 s
        now += 30
        XCTAssertEqual(try q.claim(limit: 1), ["/a.png"])
        try q.requeue(path: "/a.png", delaySeconds: 10)
        XCTAssertEqual(try q.claim(limit: 1), [])
        now += 10
        XCTAssertEqual(try q.claim(limit: 1), ["/a.png"])
        try q.fail(path: "/a.png", error: "y")                       // attempts = 2, not 3: the requeue cost nothing
        XCTAssertEqual(try q.counts(), QueueCounts(queued: 1, running: 0, failed: 0))
    }
}
