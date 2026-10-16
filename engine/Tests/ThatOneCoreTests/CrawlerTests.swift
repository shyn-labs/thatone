import XCTest
@testable import ThatOneCore

final class CrawlerTests: XCTestCase {
    func makeCrawler(_ h: Harness, exclusions: Exclusions = Exclusions()) -> Crawler {
        Crawler(store: h.store, queue: h.queue, exclusions: exclusions)
    }

    func testScanQueuesImagesSkipsOthersAndUnchangedFiles() throws {
        let h = try Harness(ocr: { _ in "words" })
        let root = h.dir.appendingPathComponent("lib")
        try h.image("a.png", in: root)
        try h.image("b.jpg", in: root.appendingPathComponent("sub"))
        try Data("x".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try h.image("hidden.png", in: root.appendingPathComponent("node_modules/pkg"))
        let crawler = makeCrawler(h)
        XCTAssertEqual(try crawler.scan(roots: [root.path]), Crawler.ScanResult(enqueued: 2, purgeQueued: 0))
        try h.drain()
        XCTAssertEqual(try h.store.counts().filesByStatus, ["indexed": 2])
        XCTAssertEqual(try crawler.scan(roots: [root.path]), Crawler.ScanResult(enqueued: 0, purgeQueued: 0))
    }

    func testScanQueuesChangedFiles() throws {
        let h = try Harness(ocr: { _ in "words" })
        let root = h.dir.appendingPathComponent("lib")
        let p = try h.image("a.png", in: root)
        let crawler = makeCrawler(h)
        _ = try crawler.scan(roots: [root.path])
        try h.drain()
        try makeImage(width: 700, height: 100, text: nil, at: URL(fileURLWithPath: p))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: p)
        XCTAssertEqual(try crawler.scan(roots: [root.path]).enqueued, 1)
    }

    func testScanQueuesPurgeForVanishedFilesAndTheIndexerForgetsThem() throws {
        let h = try Harness(ocr: { _ in "words" })
        let root = h.dir.appendingPathComponent("lib")
        let p = try h.image("a.png", in: root)
        let crawler = makeCrawler(h)
        _ = try crawler.scan(roots: [root.path])
        try h.drain()
        try FileManager.default.removeItem(atPath: p)
        XCTAssertEqual(try crawler.scan(roots: [root.path]), Crawler.ScanResult(enqueued: 0, purgeQueued: 1))
        XCTAssertNotNil(try h.store.fileRecord(path: p))        // not deleted by the crawler itself
        try h.drain()
        XCTAssertNil(try h.store.fileRecord(path: p))
        XCTAssertEqual(try h.store.counts().contents, 0)
    }

    func testRenameLinksByHashWithoutReembedding() throws {
        for oldEventFirst in [true, false] {
            let h = try Harness(ocr: { _ in "words" })
            let root = h.dir.appendingPathComponent("lib")
            let old = try h.image("a.png", in: root)
            let crawler = makeCrawler(h)
            _ = try crawler.scan(roots: [root.path])
            try h.drain()
            let embeds = h.embedder.calls.count
            let new = RealPath.of(root.path) + "/renamed copy.png"
            try FileManager.default.moveItem(atPath: old, toPath: new)
            let changes = [FileWatcher.Change(path: old, removedOrRenamed: true),
                           FileWatcher.Change(path: new, removedOrRenamed: false)]
            try crawler.handle(oldEventFirst ? changes : changes.reversed(), roots: [root.path])
            try h.drain()
            XCTAssertEqual(h.embedder.calls.count, embeds, "oldEventFirst=\(oldEventFirst)")
            XCTAssertEqual(try h.store.fileRecord(path: new)?.status, "indexed")
            XCTAssertNil(try h.store.fileRecord(path: old))
            XCTAssertEqual(try h.store.counts().contents, 1)
        }
    }

    func testHandleIgnoresPathsOutsideRootsAndExcludedOnes() throws {
        let h = try Harness(ocr: { _ in "words" })
        let root = h.dir.appendingPathComponent("lib")
        let inside = try h.image("a.png", in: root)
        let outside = try h.image("b.png", in: h.dir.appendingPathComponent("elsewhere"))
        let excluded = try h.image("c.png", in: root.appendingPathComponent(".ssh"))
        let crawler = makeCrawler(h)
        try crawler.handle([.init(path: inside, removedOrRenamed: false), .init(path: outside, removedOrRenamed: false),
                            .init(path: excluded, removedOrRenamed: false)], roots: [root.path])
        XCTAssertEqual(try h.queue.claim(limit: 10), [inside])
    }

    func testNewExclusionPurgesAlreadyIndexedFiles() throws {
        let root = TestSupport.tempDir("lib")
        let real = RealPath.of(root.path)
        let rules = Exclusions(extraPrefixes: [real + "/private"])
        let h = try Harness(ocr: { _ in "words" }, roots: [real], exclusions: rules)
        let kept = try h.image("keep.png", in: root)
        let hidden = try h.image("secret.png", in: root.appendingPathComponent("private"))
        // index both as if no rule existed, then rescan with the rule active
        let open = Indexer(store: h.store, embedder: h.embedder, workDir: h.dir.appendingPathComponent("w2"))
        _ = open.index(paths: [kept, hidden])
        XCTAssertEqual(try h.store.counts().filesByStatus, ["indexed": 2])
        let crawler = makeCrawler(h, exclusions: rules)
        XCTAssertEqual(try crawler.scan(roots: [real]).purgeQueued, 1)
        try h.drain()
        XCTAssertNotNil(try h.store.fileRecord(path: kept))
        XCTAssertNil(try h.store.fileRecord(path: hidden))
    }

    func testUnicodeSpaceAndQuotedPathsSurvive() throws {
        let h = try Harness(ocr: { _ in "words" })
        let root = h.dir.appendingPathComponent("ಕನ್ನಡ ಫೋಲ್ಡರ್")
        let p = try h.image("it's \"x\" 100%_done.png", in: root)
        _ = try makeCrawler(h).scan(roots: [root.path])
        try h.drain()
        XCTAssertEqual(try h.store.fileRecord(path: p)?.status, "indexed")
        XCTAssertEqual(try h.store.filePaths(under: RealPath.of(root.path)), [p])
    }

    func testScanOfAMissingRootPurgesNothing() throws {
        let h = try Harness(ocr: { _ in "words" })
        let root = h.dir.appendingPathComponent("lib")
        let p = try h.image("a.png", in: root)
        let crawler = makeCrawler(h)
        _ = try crawler.scan(roots: [root.path])
        try h.drain()
        let storedRoot = RealPath.of(root.path)                            // how the index knows it
        XCTAssertEqual(try h.store.filePaths(under: storedRoot), [p])
        let away = h.dir.appendingPathComponent("lib-unplugged")
        try FileManager.default.moveItem(at: root, to: away)               // the drive is unplugged
        XCTAssertEqual(try crawler.scan(roots: [storedRoot]), Crawler.ScanResult(enqueued: 0, purgeQueued: 0))
        try h.drain()
        XCTAssertEqual(try h.store.fileRecord(path: p)?.status, "indexed")
    }

    func testScanOfAnUnreadableRootPurgesNothing() throws {
        let h = try Harness(ocr: { _ in "words" })
        let root = h.dir.appendingPathComponent("lib")
        let p = try h.image("a.png", in: root)
        let crawler = makeCrawler(h)
        _ = try crawler.scan(roots: [root.path])
        try h.drain()
        chmod(root.path, 0o000)                                            // e.g. a revoked privacy grant
        defer { chmod(root.path, 0o755) }
        XCTAssertEqual(try crawler.scan(roots: [RealPath.of(root.path)]), Crawler.ScanResult(enqueued: 0, purgeQueued: 0))
        try h.drain()
        XCTAssertEqual(try h.store.fileRecord(path: p)?.status, "indexed")
    }

    func testScanDoesNotPurgeUnderAFolderItCouldNotRead() throws {
        let h = try Harness(ocr: { _ in "words" })
        let root = h.dir.appendingPathComponent("lib")
        let kept = try h.image("keep.png", in: root)
        let locked = try h.image("hidden.png", in: root.appendingPathComponent("locked"))
        let crawler = makeCrawler(h)
        _ = try crawler.scan(roots: [root.path])
        try h.drain()
        chmod(root.appendingPathComponent("locked").path, 0o000)
        defer { chmod(root.appendingPathComponent("locked").path, 0o755) }
        XCTAssertEqual(try crawler.scan(roots: [root.path]).purgeQueued, 0)
        try h.drain()
        XCTAssertEqual(try h.store.fileRecord(path: kept)?.status, "indexed")
        XCTAssertEqual(try h.store.fileRecord(path: locked)?.status, "indexed")
    }
}

final class FileWatcherTests: XCTestCase {
    func testReportsCreatedAndRemovedFiles() throws {
        let dir = TestSupport.tempDir("watch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let realDir = URL(fileURLWithPath: RealPath.of(dir.path))
        let created = expectation(description: "created"), removed = expectation(description: "removed")
        let file = realDir.appendingPathComponent("a.txt")
        let watcher = FileWatcher(roots: [realDir]) { changes in
            for change in changes where change.path == file.path {
                if change.removedOrRenamed { removed.fulfill() } else { created.fulfill() }
            }
        }
        watcher.start()
        defer { watcher.stop() }
        Thread.sleep(forTimeInterval: 0.5)
        try Data("hi".utf8).write(to: file)
        wait(for: [created], timeout: 10)
        try FileManager.default.removeItem(at: file)
        wait(for: [removed], timeout: 10)
    }
}
