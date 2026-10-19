import CoreGraphics
import Foundation
import XCTest
@testable import ThatOneCore

/// Review round 1: a full stuck-call cap makes files wait (nothing ran, nothing is the file's fault); a file whose OCR
/// really timed out is not given Vision again in this process; the deadline race; the default OCR is the bounded one.
final class OCRDeferralTests: XCTestCase {
    typealias Stuck = OCRTimeoutTests.StuckRecognizer

    func blank() -> CGImage { OCRTimeoutTests().blankImage() }

    /// A runner whose one stuck-call slot is already taken: every call is refused until `stuck` is released.
    func fullRunner(_ stuck: Stuck) -> BoundedOCR {
        let ocr = BoundedOCR(deadline: 0.2, maxAbandoned: 1, recognizer: stuck.recognize)
        XCTAssertThrowsError(try ocr.text(in: blank())) { XCTAssertEqual($0 as? ReadFailure, .timedOut) }
        XCTAssertEqual(ocr.abandonedCount, 1)
        return ocr
    }

    func waitUntil(_ seconds: Double = 3, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; Thread.sleep(forTimeInterval: 0.01) }
        return condition()
    }

    // MARK: cap full -> deferred, not failed

    func testWithTheCapFullAChangedImageWaitsAndKeepsItsIndexedContentThenIndexesOnceASlotFrees() throws {
        final class Box: @unchecked Sendable { var ocr: (CGImage) throws -> String = { _ in "first words" } }
        let box = Box()
        let h = try Harness(ocr: { try box.ocr($0) })
        let url = h.dir.appendingPathComponent("pics/shot.png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeImage(width: 300, height: 100, text: nil, at: url)
        let p = RealPath.of(url.path)
        XCTAssertEqual(h.indexer.index(paths: [p]), [p: .indexed])
        let before = try XCTUnwrap(try h.store.fileRecord(path: p))

        let stuck = Stuck()
        defer { stuck.release() }
        let full = fullRunner(stuck)
        box.ocr = full.text
        try makeImage(width: 320, height: 100, text: nil, at: url)                  // the file changed
        let outcome = try XCTUnwrap(h.indexer.index(paths: [p])[p])
        guard case .deferred(let reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(reason.hasPrefix(Indexer.ocrUnavailable), reason)
        let after = try XCTUnwrap(try h.store.fileRecord(path: p))
        XCTAssertEqual(after, before)                                                 // nothing recorded: still indexed, old content kept
        XCTAssertEqual(try Searcher(store: h.store).search(query: "first words", queryVector: nil).flatMap { $0.paths }, [p])

        stuck.release()
        XCTAssertTrue(waitUntil { full.abandonedCount == 0 })
        XCTAssertEqual(h.indexer.index(paths: [p]), [p: .indexed])                  // a later pass succeeds
    }

    func testWithTheCapFullAScannedPDFWaits() throws {
        let stuck = Stuck()
        defer { stuck.release() }
        let full = fullRunner(stuck)
        let url = PDFFixtures.file()
        PDFFixtures.make([.image(PDFFixtures.scan("INVOICE 4471"))], at: url)
        XCTAssertThrowsError(try PDFReader(ocr: full.text).read(url)) { XCTAssertTrue($0 is OCRUnavailable, "\($0)") }
        let h = try Harness(ocr: full.text)
        let p = RealPath.of(url.path)
        guard case .deferred(let reason)? = h.indexer.index(paths: [p])[p] else { return XCTFail() }
        XCTAssertTrue(reason.hasPrefix(Indexer.ocrUnavailable))
        XCTAssertNil(try h.store.fileRecord(path: p))
    }

    func testWithTheCapFullATinyImageWaitsInsteadOfBeingIndexedWithoutText() throws {
        let stuck = Stuck()
        defer { stuck.release() }
        let full = fullRunner(stuck)
        let h = try Harness(ocr: full.text)
        let tiny = h.dir.appendingPathComponent("pics/tiny.png")
        try FileManager.default.createDirectory(at: tiny.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeImage(width: 2, height: 56, text: nil, at: tiny)
        let p = RealPath.of(tiny.path)
        guard case .deferred? = h.indexer.index(paths: [p])[p] else { return XCTFail() }
    }

    func testWithTheCapFullTheEngineRequeuesPhotosAndFilesWithoutFailingOrPausing() throws {
        let stuck = Stuck()
        defer { stuck.release() }
        let full = fullRunner(stuck)
        let provider = FakeAssetProvider()
        let asset = provider.add("A/L0/001", width: 300)
        let e = try Engine(paths: Paths(home: TestSupport.tempDir("home")), config: Config(photos: true),
                           keyProvider: StaticKeyProvider(TestSupport.key), embedder: FakeEmbedder(), ocr: full.text, assets: provider)
        let folder = TestSupport.tempDir("pics")
        try makeImage(width: 300, height: 100, text: nil, at: folder.appendingPathComponent("a.png"))
        PDFFixtures.make([.text("A page with a real text layer, long enough to count.")], at: folder.appendingPathComponent("n.pdf"))
        try e.addFolder(folder.path)
        _ = try e.scan(); _ = try e.scanPhotos()
        let summary = try e.runIndexing()
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(summary.deferred, 2)                                          // the image and the photo wait
        XCTAssertEqual(summary.indexed, 1)                                           // the text-layer PDF needs no OCR
        XCTAssertNil(summary.pausedReason)                                           // not an embedder outage
        XCTAssertEqual(try e.queue.counts().failed, 0)
        XCTAssertEqual(try e.queue.counts().queued, 2)                               // still queued, retried later
        XCTAssertNil(try e.store.fileRecord(path: asset))
    }

    func testARealTimeoutStillFailsWithReadingTookTooLong() throws {
        let stuck = Stuck()
        defer { stuck.release() }
        let ocr = BoundedOCR(deadline: 0.2, maxAbandoned: 4, recognizer: stuck.recognize)
        let h = try Harness(ocr: ocr.text)
        let p = try h.image("shot.png")
        XCTAssertEqual(h.indexer.index(paths: [p]), [p: .failed("reading took too long")])
    }

    // MARK: per-path timeout breaker

    func testAFileWhoseOCRTimedOutIsNotGivenVisionAgainInThisProcess() throws {
        let stuck = Stuck()
        defer { stuck.release() }
        let ocr = BoundedOCR(deadline: 0.2, maxAbandoned: 4, recognizer: stuck.recognize)
        let h = try Harness(ocr: ocr.text)
        let p = try h.image("shot.png")
        XCTAssertEqual(h.indexer.index(paths: [p]), [p: .failed("reading took too long")])
        XCTAssertEqual(stuck.calls, 1)
        let start = Date()
        XCTAssertEqual(h.indexer.index(paths: [p]), [p: .failed("reading took too long")])   // the next attempt
        XCTAssertEqual(stuck.calls, 1)                                               // no second Vision call
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.15)
        XCTAssertEqual(ocr.abandonedCount, 1)                                        // one stuck slot, not two

        let other = try h.image("other.png")                                         // other files still get OCR
        XCTAssertEqual(h.indexer.index(paths: [other]), [other: .failed("reading took too long")])
        XCTAssertEqual(stuck.calls, 2)
    }

    func testAScannedPDFWhoseOCRTimedOutIsNotGivenVisionAgain() throws {
        let stuck = Stuck()
        defer { stuck.release() }
        let ocr = BoundedOCR(deadline: 0.2, maxAbandoned: 4, recognizer: stuck.recognize)
        let h = try Harness(ocr: ocr.text)
        let url = PDFFixtures.file()
        PDFFixtures.make([.image(PDFFixtures.scan("INVOICE 4471"))], at: url)
        let p = RealPath.of(url.path)
        XCTAssertEqual(h.indexer.index(paths: [p]), [p: .failed("reading took too long")])
        XCTAssertEqual(h.indexer.index(paths: [p]), [p: .failed("reading took too long")])
        XCTAssertEqual(stuck.calls, 1)
    }

    func testTheBreakerForgetsAChangedFileAndCanBeReset() {
        let breaker = OCRTimeoutBreaker()
        breaker.noteTimeout(path: "/a.png", size: 10, mtime: 1)
        XCTAssertTrue(breaker.isTripped(path: "/a.png", size: 10, mtime: 1))
        XCTAssertFalse(breaker.isTripped(path: "/a.png", size: 11, mtime: 1))       // a changed file starts afresh
        XCTAssertFalse(breaker.isTripped(path: "/b.png", size: 10, mtime: 1))
        breaker.reset()
        XCTAssertFalse(breaker.isTripped(path: "/a.png", size: 10, mtime: 1))
        for i in 0..<(OCRTimeoutBreaker.capacity + 5) { breaker.noteTimeout(path: "/\(i)", size: 1, mtime: 1) }
        XCTAssertEqual(breaker.count, OCRTimeoutBreaker.capacity)                   // bounded, oldest dropped
    }

    func testRetryFailedFilesResetsTheEnginesOCRBreaker() throws {
        let e = try Engine(paths: Paths(home: TestSupport.tempDir("home")), config: Config(),
                           keyProvider: StaticKeyProvider(TestSupport.key), embedder: FakeEmbedder(), ocr: { _ in "x" })
        e.ocrTimeouts.noteTimeout(path: "/a.png", size: 1, mtime: 1)
        try e.retryFailed()
        XCTAssertEqual(e.ocrTimeouts.count, 0)
    }

    // MARK: the deadline race

    func testACallThatFinishesExactlyAtTheDeadlineReturnsItsResult() throws {
        let gate = DispatchSemaphore(value: 0)
        let ocr = BoundedOCR(deadline: 0.05, maxAbandoned: 4, recognizer: { _, _ in gate.wait(); return "on time" })
        // Runs after the wait timed out and before the timeout is acted on: the call finishes in exactly that window.
        ocr.onDeadlinePassed = {
            gate.signal()
            XCTAssertTrue(self.waitUntil { ocr.callsFinished == 1 })
        }
        XCTAssertEqual(try ocr.text(in: blank()), "on time")
        XCTAssertEqual(ocr.abandonedCount, 0)                                        // nothing left counted as stuck
    }

    // MARK: wiring

    func testOCRTextAndTheEnginesDefaultGoThroughTheSharedBoundedRunner() throws {
        let stuck = Stuck()
        defer { stuck.release() }
        let saved = OCR.shared
        defer { OCR.shared = saved }
        OCR.shared = BoundedOCR(deadline: 0.2, maxAbandoned: 4, recognizer: stuck.recognize)
        XCTAssertThrowsError(try OCR.text(in: blank())) { XCTAssertEqual($0 as? ReadFailure, .timedOut) }
        XCTAssertEqual(stuck.calls, 1)

        let e = try Engine(paths: Paths(home: TestSupport.tempDir("home")), config: Config(),
                           keyProvider: StaticKeyProvider(TestSupport.key), embedder: FakeEmbedder(), ocr: nil)
        let folder = TestSupport.tempDir("pics")
        let shot = folder.appendingPathComponent("a.png")
        try makeImage(width: 300, height: 100, text: nil, at: shot)
        try e.addFolder(folder.path)
        _ = try e.scan()
        XCTAssertEqual(try e.runIndexing().failed, 1)
        XCTAssertEqual(stuck.calls, 2)                                               // the engine's default used the shared runner
        XCTAssertEqual(try e.store.fileRecord(path: RealPath.of(shot.path))?.note, "reading took too long")
    }
}
