import CoreGraphics
import Foundation
import XCTest
@testable import ThatOneCore

/// Vision text recognition bounded in time: a stuck call fails its file ("reading took too long") instead of freezing
/// the indexer, and only a few stuck calls may be left behind at once.
final class OCRTimeoutTests: XCTestCase {
    /// A recognizer that stays stuck until the test lets it go (Vision cannot be killed; neither can this).
    final class StuckRecognizer: @unchecked Sendable {
        private let lock = NSLock()
        private var held = true
        private var _calls = 0
        private var _cancels = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        var cancels: Int { lock.lock(); defer { lock.unlock() }; return _cancels }
        func release() { lock.lock(); held = false; lock.unlock() }

        func recognize(_ image: CGImage, _ cancellation: OCRCancellation) throws -> String {
            lock.lock(); _calls += 1; lock.unlock()
            cancellation.onCancel { [self] in lock.lock(); _cancels += 1; lock.unlock() }
            while true {
                lock.lock(); let stillHeld = held; lock.unlock()
                if !stillHeld { return "late text" }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    func blankImage(width: Int = 64, height: Int = 64) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    func waitUntil(_ seconds: Double = 3, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; Thread.sleep(forTimeInterval: 0.01) }
        return condition()
    }

    func testDefaultsAreSixtySecondsAndFourAbandonedCalls() {
        XCTAssertEqual(BoundedOCR.defaultDeadline, 60)
        XCTAssertEqual(BoundedOCR.defaultMaxAbandoned, 4)
    }

    func testAStuckRecognizerTimesOutQuicklyAndIsCancelled() {
        let stuck = StuckRecognizer()
        defer { stuck.release() }
        let ocr = BoundedOCR(deadline: 0.2, maxAbandoned: 4, recognizer: stuck.recognize)
        let start = Date()
        XCTAssertThrowsError(try ocr.text(in: blankImage())) { XCTAssertEqual($0 as? ReadFailure, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        XCTAssertEqual(stuck.cancels, 1)                                            // the Vision request is asked to stop
        XCTAssertEqual(ocr.abandonedCount, 1)
    }

    func testAFastRecognizerIsUnchanged() throws {
        let ocr = BoundedOCR(deadline: 0.2, maxAbandoned: 4, recognizer: { _, _ in "INVOICE 4471" })
        XCTAssertEqual(try ocr.text(in: blankImage()), "INVOICE 4471")
        XCTAssertEqual(ocr.abandonedCount, 0)
        struct Broke: Error {}
        let failing = BoundedOCR(deadline: 0.2, maxAbandoned: 4, recognizer: { _, _ in throw Broke() })
        XCTAssertThrowsError(try failing.text(in: blankImage())) { XCTAssertTrue($0 is Broke) }   // its own errors pass through
        XCTAssertEqual(failing.abandonedCount, 0)
    }

    func testAbandonedCallsAreCappedAndTheCapFreesWhenTheyReturn() throws {
        let stuck = StuckRecognizer()
        defer { stuck.release() }
        let ocr = BoundedOCR(deadline: 0.2, maxAbandoned: 2, recognizer: stuck.recognize)
        for _ in 0..<2 { XCTAssertThrowsError(try ocr.text(in: blankImage())) { XCTAssertEqual($0 as? ReadFailure, .timedOut) } }
        XCTAssertEqual(ocr.abandonedCount, 2)
        XCTAssertEqual(ocr.threadsStarted, 2)

        let start = Date()
        XCTAssertThrowsError(try ocr.text(in: blankImage())) { XCTAssertTrue($0 is OCRUnavailable, "\($0)") }  // not a timeout: nothing ran
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)                     // fails fast, no wait for the deadline
        XCTAssertEqual(ocr.threadsStarted, 2)                                       // and no new thread
        XCTAssertEqual(stuck.calls, 2)

        stuck.release()                                                             // the stuck calls finally return
        XCTAssertTrue(waitUntil { ocr.abandonedCount == 0 })
        XCTAssertEqual(try ocr.text(in: blankImage()), "late text")                 // the cap is free again
        XCTAssertEqual(ocr.threadsStarted, 3)
    }

    func testTheRealVisionRecognizerStillReadsText() throws {
        let dir = TestSupport.tempDir("ocr")
        let src = dir.appendingPathComponent("t.png")
        try makeImage(width: 1200, height: 300, text: "INVOICE 4471", at: src)
        let decoded = try ImagePrep.decode(src)
        XCTAssertTrue(try BoundedOCR().text(in: decoded.ocrImage).contains("4471"))
        XCTAssertTrue(try OCR.text(in: decoded.ocrImage).contains("4471"))
    }

    // MARK: every call site turns a timeout into a failed file

    func testAnImageWhoseOCRTimesOutIsRecordedFailed() throws {
        let stuck = StuckRecognizer()
        defer { stuck.release() }
        let ocr = BoundedOCR(deadline: 0.2, maxAbandoned: 4, recognizer: stuck.recognize)
        let h = try Harness(ocr: ocr.text)
        let p = try h.image("shot.png", text: "INVOICE 4471")
        let start = Date()
        XCTAssertEqual(h.indexer.index(paths: [p]), [p: .failed("reading took too long")])
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        let record = try XCTUnwrap(try h.store.fileRecord(path: p))
        XCTAssertEqual(record.status, "failed")
        XCTAssertEqual(record.note, "reading took too long")
    }

    func testOtherFilesInTheBatchStillIndexWhenOneTimesOut() throws {
        final class Picky: @unchecked Sendable { var first = true }
        let picky = Picky()
        let stuck = StuckRecognizer()
        defer { stuck.release() }
        let ocr = BoundedOCR(deadline: 0.2, maxAbandoned: 4, recognizer: { image, cancel in
            if picky.first { picky.first = false; return try stuck.recognize(image, cancel) }
            return "fine"
        })
        let h = try Harness(ocr: ocr.text)
        let a = try h.image("a.png"), b = try h.image("b.png")
        let outcomes = h.indexer.index(paths: [a, b])
        XCTAssertEqual(outcomes.values.filter { $0 == .failed("reading took too long") }.count, 1)
        XCTAssertEqual(outcomes.values.filter { $0 == .indexed }.count, 1)
    }

    func testAScannedPDFPageWhoseOCRTimesOutFailsTheFile() throws {
        let stuck = StuckRecognizer()
        defer { stuck.release() }
        let ocr = BoundedOCR(deadline: 0.2, maxAbandoned: 4, recognizer: stuck.recognize)
        let url = PDFFixtures.file()
        PDFFixtures.make([.text("A page with a real text layer, long enough to count."), .image(PDFFixtures.scan("INVOICE 4471")),
                          .image(PDFFixtures.scan("PAGE THREE"))], at: url)
        XCTAssertThrowsError(try PDFReader(ocr: ocr.text).read(url)) { XCTAssertEqual($0 as? ReadFailure, .timedOut) }
        XCTAssertEqual(stuck.calls, 1)                                              // the first timeout ends the file

        let h = try Harness(ocr: ocr.text)
        let p = RealPath.of(url.path)
        XCTAssertEqual(h.indexer.index(paths: [p]), [p: .failed("reading took too long")])
        XCTAssertEqual(try h.store.fileRecord(path: p)?.note, "reading took too long")
    }

    func testAPhotosAssetWhoseOCRTimesOutIsRecordedFailed() throws {
        let stuck = StuckRecognizer()
        defer { stuck.release() }
        let ocr = BoundedOCR(deadline: 0.2, maxAbandoned: 4, recognizer: stuck.recognize)
        let provider = FakeAssetProvider()
        let path = provider.add("A/L0/001", width: 300)
        let e = try Engine(paths: Paths(home: TestSupport.tempDir("home")), config: Config(photos: true),
                           keyProvider: StaticKeyProvider(TestSupport.key), embedder: FakeEmbedder(), ocr: ocr.text, assets: provider)
        XCTAssertEqual(try e.scanPhotos().enqueued, 1)
        let summary = try e.runIndexing()
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(try e.store.fileRecord(path: path)?.note, "reading took too long")
    }
}
