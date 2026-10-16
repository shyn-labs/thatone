import CoreGraphics
import XCTest
@testable import ThatOneCore

final class IndexerTests: XCTestCase {
    func testIndexesAnImageWithTextAndSearchFindsIt() throws {
        let h = try Harness(ocr: { _ in "invoice 4471" })
        let p = try h.image("a.png")
        XCTAssertEqual(h.indexer.index(paths: [p]), [p: .indexed])
        XCTAssertEqual(try h.store.counts().segmentsByModality, ["image": 1, "text": 1])
        XCTAssertEqual(try h.store.fileRecord(path: p)?.status, "indexed")
        let hits = try Searcher(store: h.store).search(query: "4471", queryVector: nil)
        XCTAssertEqual(hits.flatMap { $0.paths }, [p])
    }

    func testImageWithoutTextGetsOnlyAnImageSegment() throws {
        let h = try Harness(ocr: { _ in "" })
        let p = try h.image("blank.png")
        XCTAssertEqual(h.indexer.index(paths: [p]), [p: .indexed])
        XCTAssertEqual(try h.store.counts().segmentsByModality, ["image": 1])
        XCTAssertEqual(h.embedder.callCount(.text), 0)
    }

    func testBatchEmbedsAllImagesInOneCall() throws {
        let h = try Harness(ocr: { _ in "some words here" })
        let paths = try (1...3).map { try h.image("p\($0).png") }
        _ = h.indexer.index(paths: paths)
        XCTAssertEqual(h.embedder.callCount(.image), 1)
        XCTAssertEqual(h.embedder.calls.first { $0.0 == .image }?.2.count, 3)
        XCTAssertEqual(h.embedder.callCount(.text), 1)
    }

    func testCorruptImageIsIsolated() throws {
        let h = try Harness(ocr: { _ in "words" })
        let good1 = try h.image("good1.png")
        let bad = h.dir.appendingPathComponent("pics/bad.png")
        try Data("this is not an image".utf8).write(to: bad)
        let good2 = try h.image("good2.png")
        let out = h.indexer.index(paths: [good1, RealPath.of(bad.path), good2])
        XCTAssertEqual(out[good1], .indexed)
        XCTAssertEqual(out[good2], .indexed)
        XCTAssertEqual(out[RealPath.of(bad.path)], .failed("cannot decode image"))
        XCTAssertEqual(try h.store.failedFiles().map { $0.note }, ["cannot decode image"])
    }

    func testEmbedFailureForOneItemFailsOnlyThatFile() throws {
        let h = try Harness(ocr: { _ in "words" })
        let a = try h.image("a.png"), b = try h.image("b.png"), c = try h.image("c.png")
        let badHash = try Indexer.sha256Hex(of: b)
        h.embedder.failWhen = { modality, input in modality == .image && input.hasSuffix("\(badHash).jpg") }
        let out = h.indexer.index(paths: [a, b, c])
        XCTAssertEqual(out[a], .indexed)
        XCTAssertEqual(out[c], .indexed)
        guard case .failed(let message)? = out[b] else { return XCTFail("\(String(describing: out[b]))") }
        XCTAssertTrue(message.contains("embedding input_error"), message)
        XCTAssertEqual(try h.store.fileRecord(path: b)?.status, "failed")
        XCTAssertEqual(try h.store.counts().contents, 2)
    }

    func testUnchangedFileIsSkippedWithoutEmbedding() throws {
        let h = try Harness(ocr: { _ in "words" })
        let p = try h.image("a.png")
        _ = h.indexer.index(paths: [p])
        let calls = h.embedder.calls.count
        XCTAssertEqual(h.indexer.index(paths: [p]), [p: .unchanged])
        XCTAssertEqual(h.embedder.calls.count, calls)
    }

    func testChangedFileIsReindexed() throws {
        var version = 0
        let h = try Harness(ocr: { _ in version += 1; return version == 1 ? "first version text" : "second version text" })
        let p = try h.image("a.png")
        _ = h.indexer.index(paths: [p])
        // replace the content and move the mtime forward
        try makeImage(width: 640, height: 100, text: nil, at: URL(fileURLWithPath: p))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: p)
        XCTAssertEqual(h.indexer.index(paths: [p]), [p: .indexed])
        let searcher = Searcher(store: h.store)
        XCTAssertEqual(try searcher.search(query: "first", queryVector: nil).count, 0)
        XCTAssertEqual(try searcher.search(query: "second", queryVector: nil).count, 1)
        XCTAssertEqual(try h.store.counts().contents, 1)
        XCTAssertEqual(try h.store.int("select count(*) from segment_vectors"), 2)
    }

    func testIdenticalContentUnderTwoPathsIsEmbeddedOnce() throws {
        let h = try Harness(ocr: { _ in "shared words" })
        let a = try h.image("a.png")
        let copy = h.dir.appendingPathComponent("pics/a copy.png")
        try FileManager.default.copyItem(atPath: a, toPath: copy.path)
        let b = RealPath.of(copy.path)
        let out = h.indexer.index(paths: [a, b])
        XCTAssertEqual(Set(out.values), [.indexed, .linked])
        XCTAssertEqual(h.embedder.callCount(.image), 1)
        XCTAssertEqual(h.embedder.calls.first { $0.0 == .image }?.2.count, 1)
        XCTAssertEqual(try h.store.counts().contents, 1)
        XCTAssertEqual(try h.store.counts().filesByStatus, ["indexed": 2])
    }

    func testMissingFileIsRemoved() throws {
        let h = try Harness(ocr: { _ in "words" })
        let p = try h.image("a.png")
        _ = h.indexer.index(paths: [p])
        try FileManager.default.removeItem(atPath: p)
        XCTAssertEqual(h.indexer.index(paths: [p]), [p: .removed])
        XCTAssertNil(try h.store.fileRecord(path: p))
        XCTAssertEqual(try h.store.counts().contents, 0)
    }

    func testExcludedAndUnsupportedAreSkippedAndNotRecorded() throws {
        let h = try Harness(ocr: { _ in "words" })
        let key = h.dir.appendingPathComponent("pics/id_rsa.png")
        try FileManager.default.createDirectory(at: key.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeImage(width: 50, height: 50, text: nil, at: key)
        let notes = h.dir.appendingPathComponent("pics/archive.zip")
        try Data("hello".utf8).write(to: notes)
        let out = h.indexer.index(paths: [RealPath.of(key.path), RealPath.of(notes.path)])
        XCTAssertEqual(out[RealPath.of(key.path)], .skipped("excluded"))
        XCTAssertEqual(out[RealPath.of(notes.path)], .skipped("unsupported file type"))
        XCTAssertEqual(try h.store.counts().filesByStatus, [:])
        XCTAssertEqual(h.embedder.calls.count, 0)
    }

    func testSecretImageIsSkippedEntirely() throws {
        let h = try Harness(ocr: { _ in "token ghp_abcdefghijklmnopqrstuvwxyz0123456789" })
        let p = try h.image("key.png")
        XCTAssertEqual(h.indexer.index(paths: [p]), [p: .skipped("secret")])
        XCTAssertEqual(try h.store.counts().segmentsByModality, [:])
        XCTAssertEqual(try h.store.fileRecord(path: p)?.status, "skipped")
        XCTAssertEqual(try h.store.fileRecord(path: p)?.note, "secret")
        XCTAssertEqual(h.embedder.calls.count, 0)                 // never embedded
        XCTAssertEqual(try Searcher(store: h.store).search(query: "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
                                                           queryVector: FakeEmbedder.vector(for: "x")).count, 0)
    }

    func testDatabaseFilesContainNoPlaintext() throws {
        let h = try Harness(ocr: { _ in "plaintext canary 8675309" })
        let p = try h.image("a.png")
        _ = h.indexer.index(paths: [p])
        h.store.close()
        var inspected = 0
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: h.dbPath + suffix)
            guard let data = FileManager.default.contents(atPath: url.path) else { continue }
            inspected += 1
            XCTAssertNil(data.range(of: Data("plaintext canary".utf8)), url.lastPathComponent)
            XCTAssertNil(data.range(of: Data("8675309".utf8)), url.lastPathComponent)
        }
        XCTAssertGreaterThanOrEqual(inspected, 1)
    }

    func testRealOCRReadsRenderedText() throws {
        let h = try Harness(ocr: { try OCR.text(in: $0) })     // the real Vision OCR, not the stub
        let p = try h.image("invoice.png", text: "INVOICE 4471")
        XCTAssertEqual(h.indexer.index(paths: [p]), [p: .indexed])
        XCTAssertEqual(try Searcher(store: h.store).search(query: "4471", queryVector: nil).flatMap { $0.paths }, [p])
    }

    struct OCRBroke: Error {}

    func testOCRFailureOnATinyImageStillIndexesIt() throws {
        let h = try Harness(ocr: { _ in throw OCRBroke() })
        let tiny = h.dir.appendingPathComponent("pics/tiny.png")
        try FileManager.default.createDirectory(at: tiny.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeImage(width: 2, height: 56, text: nil, at: tiny)        // Vision refuses sides of 2 px or less
        let p = RealPath.of(tiny.path)
        XCTAssertEqual(h.indexer.index(paths: [p]), [p: .indexed])
        XCTAssertEqual(try h.store.counts().segmentsByModality, ["image": 1])
        XCTAssertEqual(try h.store.query("select note from contents") { $0.text(0) }.first?.hasPrefix("ocr failed"), true)
    }

    func testOCRFailureOnARealImageFailsTheFileInsteadOfSkippingTheSecretGate() throws {
        let h = try Harness(ocr: { _ in throw OCRBroke() })
        let p = try h.image("screenshot.png")                           // 200+ x 100: large enough to hold readable text
        guard case .failed(let message)? = h.indexer.index(paths: [p])[p] else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.hasPrefix("ocr failed"), message)
        XCTAssertTrue(h.embedder.calls.isEmpty)                         // never embedded without having been checked
        XCTAssertEqual(try h.store.counts().segmentsByModality, [:])
    }

    func testTooLargeImageFailsWithAClearReason() throws {
        let h = try Harness(ocr: { _ in "words" })
        let p = try h.image("a.png")
        let old = ImagePrep.maxPixels
        ImagePrep.maxPixels = 100
        defer { ImagePrep.maxPixels = old }
        XCTAssertEqual(h.indexer.index(paths: [p]), [p: .failed("image too large")])
        XCTAssertTrue(h.embedder.calls.isEmpty)
    }

    private func jpegs(under dir: URL) -> [String] {
        let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "jpg" }.map { $0.path }
    }

    func testNoPlaintextJPEGExistsWhenOCRAndTheSecretGateRun() throws {
        final class Spy { var dir: URL?; var seen: [String] = [] }
        let spy = Spy()
        var inspect: (URL) -> [String] = { _ in [] }
        let h = try Harness(ocr: { _ in
            if let dir = spy.dir { spy.seen += inspect(dir) }
            return "token ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        })
        spy.dir = h.dir.appendingPathComponent("work")
        inspect = { self.jpegs(under: $0) }
        let p = try h.image("key.png")
        XCTAssertEqual(h.indexer.index(paths: [p]), [p: .skipped("secret")])
        XCTAssertEqual(spy.seen, [])                                               // no copy of the image existed during OCR
        XCTAssertEqual(jpegs(under: h.dir.appendingPathComponent("work")), [])    // and none was written afterwards
    }

    func testWorkFolderIsEmptyAfterIndexing() throws {
        let h = try Harness(ocr: { _ in "words here" })
        let p = try h.image("a.png")
        XCTAssertEqual(h.indexer.index(paths: [p]), [p: .indexed])
        XCTAssertEqual(jpegs(under: h.dir.appendingPathComponent("work")), [])
    }

    func testSweepRemovesDeadRunsAndKeepsLiveOnes() throws {
        let work = TestSupport.tempDir("work")
        func make(_ name: String) throws -> URL {
            let url = work.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url.appendingPathComponent("leftover.jpg"))
            return url
        }
        let dead = try make("run-2147483000-\(UUID().uuidString)")           // no such process
        let live = try make("run-\(getpid())-\(UUID().uuidString)")          // this process
        let loose = work.appendingPathComponent("old.jpg")                    // pre-run-folder leftovers
        try Data("x".utf8).write(to: loose)
        Indexer.sweepStaleRuns(in: work)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: loose.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
    }

    func testTwoIndexersNeverShareARunFolder() throws {
        let h = try Harness()
        let other = Indexer(store: h.store, embedder: h.embedder, workDir: h.dir.appendingPathComponent("work"))
        XCTAssertNotEqual(h.indexer.runDirectory, other.runDirectory)
        XCTAssertTrue(h.indexer.runDirectory.lastPathComponent.hasPrefix("run-\(getpid())-"))
    }

    func testAnUnreadableFolderDoesNotDropWhatIsIndexed() throws {
        let h = try Harness(ocr: { _ in "words" })
        let folder = h.dir.appendingPathComponent("pics/locked")
        let p = try h.image("a.png", in: folder)
        XCTAssertEqual(h.indexer.index(paths: [p]), [p: .indexed])
        chmod(folder.path, 0o000)
        defer { chmod(folder.path, 0o755) }
        XCTAssertEqual(h.indexer.index(paths: [p]), [p: .skipped("not accessible")])
        XCTAssertEqual(try h.store.fileRecord(path: p)?.status, "indexed")
        XCTAssertEqual(try h.store.counts().contents, 1)
    }

    func testUnavailableEmbedderDefersInsteadOfFailingAndKeepsOldContent() throws {
        var version = 0
        let h = try Harness(ocr: { _ in version += 1; return version == 1 ? "first version text" : "second version text" })
        let p = try h.image("a.png")
        XCTAssertEqual(h.indexer.index(paths: [p]), [p: .indexed])
        try makeImage(width: 640, height: 100, text: nil, at: URL(fileURLWithPath: p))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: p)
        h.embedder.failure = SidecarEmbedder.Failure.unavailable("worker not installed")
        XCTAssertEqual(h.indexer.index(paths: [p]), [p: .deferred("embedding unavailable: worker not installed")])
        XCTAssertEqual(try h.store.fileRecord(path: p)?.status, "indexed")                  // the old entry survives
        XCTAssertEqual(try Searcher(store: h.store).search(query: "first", queryVector: nil).count, 1)
        h.embedder.failure = nil
        XCTAssertEqual(h.indexer.index(paths: [p]), [p: .indexed])                          // the next run catches up
        XCTAssertEqual(try Searcher(store: h.store).search(query: "second", queryVector: nil).count, 1)
    }

    func testLaunchFailuresAreDeferredAndPerFileErrorsStillFail() throws {
        struct Boom: Error {}
        let h = try Harness(ocr: { _ in "words" })
        let a = try h.image("a.png")
        h.embedder.failure = Boom()                       // e.g. Process.run() failing because uv is missing
        XCTAssertEqual(h.indexer.index(paths: [a])[a], .deferred(String(describing: Boom())))
        h.embedder.failure = SidecarError.remote(code: "input_error", message: "bad pixels")
        guard case .failed(let message)? = h.indexer.index(paths: [a])[a] else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.contains("input_error"), message)
    }

    func testAWorkerThatKeepsDyingDefersTheBatchAndBurnsNoAttempts() throws {
        let h = try Harness(ocr: { _ in "first version text" })
        let a = try h.image("a.png"), b = try h.image("b.png"), c = try h.image("c.png")
        XCTAssertEqual(h.indexer.index(paths: [a]), [a: .indexed])
        h.embedder.failure = SidecarError.workerExited(1)                    // every launch dies
        let outcomes = h.indexer.index(paths: [b, c])
        XCTAssertEqual(outcomes.values.filter { if case .deferred = $0 { return true } else { return false } }.count, 2, "\(outcomes)")
        XCTAssertNil(try h.store.fileRecord(path: b))                          // nothing recorded as failed
        XCTAssertEqual(try h.store.fileRecord(path: a)?.status, "indexed")
    }
}
