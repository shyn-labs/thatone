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

    func testAJobThatCrashesTheAppTwiceIsRecordedFailedAndNotRetried() throws {
        let q = try makeQueue()
        try q.enqueue(path: "/crash.swift", priority: 1)
        try q.enqueue(path: "/fine.swift", priority: 0)
        XCTAssertEqual(try q.claim(limit: 1), ["/crash.swift"])        // the app dies while reading it
        XCTAssertEqual(try q.recoverRunning(), [])                      // first restart: one attempt, queued again
        XCTAssertEqual(try q.counts(), QueueCounts(queued: 2, running: 0, failed: 0))
        XCTAssertEqual(try q.claim(limit: 1), ["/crash.swift"])        // dies again
        XCTAssertEqual(try q.recoverRunning(), ["/crash.swift"])        // second restart: given up
        XCTAssertEqual(try q.counts(), QueueCounts(queued: 1, running: 0, failed: 1))
        XCTAssertEqual(try q.failedJobs().map { "\($0.path)|\($0.error)" }, ["/crash.swift|\(JobQueue.crashNote)"])
        XCTAssertEqual(JobQueue.crashNote, "stopped the app while reading")
        now += 100_000
        XCTAssertEqual(try q.recoverRunning(), [])                      // a third launch changes nothing
        XCTAssertEqual(try q.claim(limit: 5), ["/fine.swift"])          // never claimed again on its own
        try q.complete(path: "/fine.swift")
        XCTAssertEqual(try q.claim(limit: 5), [])
        try q.retryFailed()                                             // only the user's retry brings it back
        XCTAssertEqual(try q.claim(limit: 5), ["/crash.swift"])
    }

    func testOneCrashThenANormalFinishLeavesNoTrace() throws {
        let q = try makeQueue()
        try q.enqueue(path: "/a.swift", priority: 1)
        _ = try q.claim(limit: 1)
        try q.recoverRunning()                                           // one crash
        _ = try q.claim(limit: 1)
        try q.fail(path: "/a.swift", error: "unreadable")               // a normal failure: the crash counted as attempt 1
        now += 60
        XCTAssertEqual(try q.claim(limit: 1), ["/a.swift"])
        try q.fail(path: "/a.swift", error: "unreadable")               // attempt 3: failed with its own error
        XCTAssertEqual(try q.failedJobs().map { "\($0.path)|\($0.error)" }, ["/a.swift|unreadable"])
    }

    func testEngineRecordsACrashLoopingFileAsFailedSoAScanDoesNotQueueItAgain() throws {
        let repo = TestSupport.tempDir("repo")
        CodeIndexingTests.write(CodeIndexingTests.source, "src/crash.swift", in: repo)
        let e = try CodeIndexingTests.makeEngine()
        try e.addFolder(repo.path)
        _ = try e.scan()
        let path = RealPath.of(repo.path) + "/src/crash.swift"
        for _ in 0..<2 {                                                 // claimed, then the app dies before finishing
            XCTAssertEqual(try e.queue.claim(limit: 5), [path])
            try e.runIndexing(shouldContinue: { false })                 // the next launch recovers, then stops at once
        }
        let record = try XCTUnwrap(e.store.fileRecord(path: path))
        XCTAssertEqual(record.status, "failed"); XCTAssertEqual(record.note, JobQueue.crashNote)
        XCTAssertEqual(try e.scan().enqueued, 0)                          // unchanged file: not queued again
        XCTAssertEqual(try e.queue.counts(), QueueCounts(queued: 0, running: 0, failed: 1))
    }

    func testAPhotosAssetThatStopsTheAppTwiceIsNotQueuedAgainByAPhotosScan() throws {
        let provider = FakeAssetProvider()
        let path = provider.add("A1", width: 300)
        let e = try Engine(paths: Paths(home: TestSupport.tempDir("home")), config: Config(photos: true),
                           keyProvider: StaticKeyProvider(TestSupport.key), embedder: FakeEmbedder(), ocr: { _ in "" },
                           assets: provider)
        XCTAssertEqual(try e.scanPhotos().enqueued, 1)
        for _ in 0..<2 {
            XCTAssertEqual(try e.queue.claim(limit: 5), [path])
            try e.runIndexing(shouldContinue: { false })
        }
        XCTAssertEqual(try e.store.fileRecord(path: path)?.note, JobQueue.crashNote)
        XCTAssertEqual(try e.scanPhotos().enqueued, 0)
        XCTAssertEqual(try e.queue.counts(), QueueCounts(queued: 0, running: 0, failed: 1))
    }

    func testReleaseRequeuesOnlyRunningJobsAndKeepsTheirHistory() throws {
        let q = try makeQueue()
        try q.enqueue(path: "/a.png", priority: 2)
        try q.enqueue(path: "/b.png", priority: 1)
        _ = try q.claim(limit: 2)
        try q.fail(path: "/b.png", error: "x")                       // finished (failed) before the quit: backing off
        try q.release(paths: ["/a.png", "/b.png"])
        try q.release(paths: ["/a.png", "/b.png"])                   // idempotent
        XCTAssertEqual(try q.counts(), QueueCounts(queued: 2, running: 0, failed: 0))
        XCTAssertEqual(try q.claim(limit: 5), ["/a.png"])             // b keeps its 30 s back-off
        try q.recoverRunning()
        XCTAssertEqual(try q.claimRecovered(), ["/a.png"])            // a crash after the release counts from zero
        XCTAssertEqual(try q.recoverRunning(), ["/a.png"])
    }

    func testReleaseLeavesAJobThatWasGivenUpFailed() throws {
        let q = try makeQueue()
        try q.enqueue(path: "/c.png", priority: 1)
        for _ in 0..<3 { now += 10_000; _ = try q.claim(limit: 1); try q.fail(path: "/c.png", error: "x") }
        try q.release(paths: ["/c.png"])                             // the quit came after it was given up
        XCTAssertEqual(try q.counts(), QueueCounts(queued: 0, running: 0, failed: 1))
    }

    func testARunningPurgeJobIsRequeuedAsItWasAfterACrash() throws {
        let q = try makeQueue()
        try q.enqueue(path: "/gone.png", priority: JobQueue.purgePriority)
        for _ in 0..<3 {
            XCTAssertEqual(try q.claim(limit: 1), ["/gone.png"])
            XCTAssertEqual(try q.recoverRunning(), [])
        }
        XCTAssertEqual(try q.counts(), QueueCounts(queued: 1, running: 0, failed: 0))
        XCTAssertEqual(try q.claimRecovered(), [])                   // not a recovered read: claimed with its batch
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
