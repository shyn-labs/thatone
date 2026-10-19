import XCTest
@testable import ThatOneCore

/// A normal quit is not a crash, and a crash blames only the file that was being read.
final class CrashGuardTests: XCTestCase {
    struct SimulatedExit: Error {}

    /// An engine watching a repo with `count` distinct code files f0.swift ... (claimed in that order).
    func engineWithCodeFiles(_ count: Int, embedder: FakeEmbedder = FakeEmbedder(),
                             marker: (Int) -> String = { _ in "" }) throws -> (Engine, [String]) {
        let repo = TestSupport.tempDir("repo")
        for i in 0..<count { CodeIndexingTests.write(CodeIndexingTests.source + "// file \(i) \(marker(i))\n", "f\(i).swift", in: repo) }
        let e = try CodeIndexingTests.makeEngine(embedder: embedder)
        try e.addFolder(repo.path)
        XCTAssertEqual(try e.scan().enqueued, count)
        return (e, (0..<count).map { RealPath.of(repo.path) + "/f\($0).swift" })
    }

    func jobs(_ e: Engine) throws -> [String] {
        try e.store.query("select path, state, attempts, last_error from jobs order by path") {
            "\($0.text(0))|\($0.text(1))|\($0.int(2))|\($0.text(3))"
        }
    }

    func keyword(_ e: Engine, _ q: String) throws -> [String] {
        try Searcher(store: e.store).search(query: q, queryVector: nil, filters: SearchFilters(kinds: ["code"])).flatMap(\.paths)
    }

    // MARK: 1. a normal quit puts the batch back

    func testReleaseClaimedPutsTheBatchBackWithoutCountingAnAttempt() throws {
        let (e, paths) = try engineWithCodeFiles(8)
        var claimed: [String] = []
        e.onClaim = { batch in
            claimed = batch
            try e.releaseClaimed()                                       // the app quits normally...
            try e.releaseClaimed()                                       // (twice is harmless)
            throw SimulatedExit()                                        // ...and the process ends mid-batch
        }
        XCTAssertThrowsError(try e.runIndexing())
        e.onClaim = nil
        XCTAssertEqual(claimed, paths)
        XCTAssertEqual(try e.queue.counts(), QueueCounts(queued: 8, running: 0, failed: 0))
        XCTAssertEqual(try jobs(e), paths.map { "\($0)|queued|0|" })   // no attempt, no error
        let summary = try e.runIndexing()                                // the next launch claims them as usual
        XCTAssertEqual(summary.indexed, 8)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(try e.store.failedFiles().count, 0)
        XCTAssertEqual(try e.queue.counts(), QueueCounts(queued: 0, running: 0, failed: 0))
    }

    func testTwoNormalQuitsDuringOneBatchFailNothing() throws {
        let (e, paths) = try engineWithCodeFiles(8)
        for _ in 0..<2 {
            e.onClaim = { _ in try e.releaseClaimed(); throw SimulatedExit() }
            XCTAssertThrowsError(try e.runIndexing())
        }
        e.onClaim = nil
        XCTAssertEqual(try jobs(e), paths.map { "\($0)|queued|0|" })
        XCTAssertEqual(try e.runIndexing().indexed, 8)
        XCTAssertEqual(try e.store.failedFiles().count, 0)
    }

    func testAJobThatFinishedIsNoLongerInFlight() throws {
        let embedder = FakeEmbedder()
        embedder.failWhen = { _, input in input.contains("zzbroken") }
        let (e, paths) = try engineWithCodeFiles(2, embedder: embedder, marker: { $0 == 0 ? "zzbroken" : "" })
        let summary = try e.runIndexing()
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.indexed, 1)
        try e.releaseClaimed()                                           // nothing in flight: the failed file keeps its back-off
        XCTAssertEqual(try jobs(e).count, 1)
        XCTAssertTrue(try jobs(e)[0].hasPrefix("\(paths[0])|queued|1|embedding"))
        XCTAssertEqual(try e.queue.claim(limit: 8), [])                  // still backing off (30 s)
    }

    // MARK: 3. an unclean exit blames only the culprit

    func testAnUncleanExitBlamesOnlyTheFileThatWasBeingRead() throws {
        let (e, paths) = try engineWithCodeFiles(8)
        let culprit = paths[4]
        var batches: [[String]] = []
        e.onClaim = { batch in
            batches.append(batch)
            if batch.contains(culprit) { throw SimulatedExit() }        // the app dies reading the culprit
        }
        XCTAssertThrowsError(try e.runIndexing())                        // launch 1: dies with all 8 claimed
        XCTAssertEqual(batches, [paths])
        batches = []
        XCTAssertThrowsError(try e.runIndexing())                        // launch 2: recovered paths one at a time
        XCTAssertEqual(batches, paths[0...4].map { [$0] })
        XCTAssertEqual(try e.queue.counts().failed, 0)
        batches = []
        let summary = try e.runIndexing()                                // launch 3: only the culprit is given up
        XCTAssertEqual(batches, paths[5...7].map { [$0] })
        XCTAssertEqual(summary.indexed, 3)
        XCTAssertEqual(try e.queue.failedJobs().map(\.path), [culprit])
        XCTAssertEqual(try e.store.failedFiles().map(\.path), [culprit])
        XCTAssertEqual(try e.store.fileRecord(path: culprit)?.note, JobQueue.crashNote)
        for path in paths where path != culprit { XCTAssertEqual(try e.store.fileRecord(path: path)?.status, "indexed", path) }
        XCTAssertEqual(try e.queue.counts(), QueueCounts(queued: 0, running: 0, failed: 1))
    }

    func testRecoveredJobsGoFirstThenNormalBatchesResume() throws {
        let (e, paths) = try engineWithCodeFiles(3)
        XCTAssertEqual(try e.queue.claim(limit: 2), Array(paths[0...1]))  // the app dies with two claimed
        var batches: [[String]] = []
        e.onClaim = { batches.append($0) }
        XCTAssertEqual(try e.runIndexing().indexed, 3)
        XCTAssertEqual(batches, [[paths[0]], [paths[1]], [paths[2]]])
        XCTAssertEqual(try e.queue.counts(), QueueCounts(queued: 0, running: 0, failed: 0))
    }

    // MARK: 2. a crash never drops content that was already indexed

    func testAnIndexedFileThatStopsTheAppKeepsItsSearchResults() throws {
        let (e, paths) = try engineWithCodeFiles(1)
        let path = paths[0]
        try e.runIndexing()
        XCTAssertEqual(try keyword(e, "retryWithBackoff"), [path])
        let segments = try e.store.counts().segmentsByModality
        let later = Date().addingTimeInterval(120)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: path)   // touched: queued again
        XCTAssertEqual(try e.scan().enqueued, 1)
        for _ in 0..<2 {                                                 // the app dies twice while reading it
            XCTAssertEqual(try e.queue.claim(limit: 5), [path])
            try e.runIndexing(shouldContinue: { false })
        }
        XCTAssertEqual(try e.queue.failedJobs().map(\.path), [path])
        XCTAssertEqual(try keyword(e, "retryWithBackoff"), [path])       // still found
        XCTAssertEqual(try e.store.counts().segmentsByModality, segments)
        let failed = try e.store.failedFiles()                           // and still shown as failed, with why
        XCTAssertEqual(failed.map(\.path), [path])
        XCTAssertEqual(failed.first?.note, Store.keptAfterFailure + JobQueue.crashNote)
        XCTAssertEqual(try e.scan().enqueued, 0)                         // unchanged since: left alone
        try e.retryFailed()                                              // the user's retry reads it again
        XCTAssertEqual(try e.runIndexing().linked, 1)
        XCTAssertEqual(try e.store.failedFiles().count, 0)
        XCTAssertEqual(try e.store.fileRecord(path: path)?.note, "")
        XCTAssertEqual(try keyword(e, "retryWithBackoff"), [path])
    }

    // MARK: 4. a purge interrupted by a crash just runs again

    func testACrashDuringAPurgeLeavesNoFailedRecordForAMissingFile() throws {
        let (e, paths) = try engineWithCodeFiles(1)
        let path = paths[0]
        try e.runIndexing()
        try FileManager.default.removeItem(atPath: path)
        XCTAssertEqual(try e.scan().purgeQueued, 1)
        for _ in 0..<3 {                                                 // the app dies during the purge, three times
            XCTAssertEqual(try e.queue.claim(limit: 5), [path])
            try e.runIndexing(shouldContinue: { false })
        }
        XCTAssertEqual(try jobs(e), ["\(path)|queued|0|"])               // no attempt counted, nothing failed
        XCTAssertEqual(try e.store.failedFiles().count, 0)
        XCTAssertEqual(try e.runIndexing().removed, 1)                   // the purge runs again
        XCTAssertNil(try e.store.fileRecord(path: path))
        XCTAssertEqual(try e.queue.counts(), QueueCounts(queued: 0, running: 0, failed: 0))
    }
}
