import CoreGraphics
import Foundation
import XCTest
@testable import ThatOneCore

/// A run's "failed" count is files, not attempts: a file retried and failing again in the same run counts once.
final class FailedCountTests: XCTestCase {
    struct OCRBroke: Error {}

    func makeEngine() throws -> Engine {
        try Engine(paths: Paths(home: TestSupport.tempDir("home")), config: Config(),
                   keyProvider: StaticKeyProvider(TestSupport.key), embedder: FakeEmbedder(), ocr: { _ in throw OCRBroke() })
    }

    /// Two pictures big enough that an OCR error fails them.
    func twoImages() throws -> URL {
        let folder = TestSupport.tempDir("pics")
        try makeImage(width: 300, height: 100, text: nil, at: folder.appendingPathComponent("a.png"))
        try makeImage(width: 310, height: 100, text: nil, at: folder.appendingPathComponent("b.png"))
        return folder
    }

    /// Makes failed jobs claimable again at once, so the same run retries them (as a long run does after the back-off).
    func skipBackOff(_ e: Engine) { _ = try? e.store.run("update jobs set next_attempt = 0 where state = 'queued'") }

    func testRunSummaryCountsDistinctFailedFiles() throws {
        let e = try makeEngine()
        try e.addFolder(try twoImages().path)
        XCTAssertEqual(try e.scan().enqueued, 2)
        let summary = try e.runIndexing(progress: { _, _ in self.skipBackOff(e) })
        XCTAssertEqual(try e.queue.counts().failed, 2)                         // each file ran out of attempts in this run
        XCTAssertEqual(summary.failed, 2)                                       // not 6 (2 files x 3 attempts)
    }

    func testAFileThatFailsThenSucceedsInTheSameRunIsNotCountedFailed() throws {
        final class Flaky: @unchecked Sendable { var calls = 0 }
        let flaky = Flaky()
        let e = try Engine(paths: Paths(home: TestSupport.tempDir("home")), config: Config(),
                           keyProvider: StaticKeyProvider(TestSupport.key), embedder: FakeEmbedder(),
                           ocr: { _ in flaky.calls += 1; if flaky.calls == 1 { throw OCRBroke() }; return "words" })
        let folder = TestSupport.tempDir("pics")
        try makeImage(width: 300, height: 100, text: nil, at: folder.appendingPathComponent("a.png"))
        try e.addFolder(folder.path)
        _ = try e.scan()
        let summary = try e.runIndexing(progress: { _, _ in self.skipBackOff(e) })
        XCTAssertEqual(summary.indexed, 1)
        XCTAssertEqual(summary.failed, 0)
    }

    func testCLIIndexPrintsFilesAndDistinctFailures() throws {
        let e = try makeEngine()
        let folder = try twoImages()
        var out: [String] = []
        try CLI.index([folder.path], { e }, { nil }, { out.append($0) }, { _ in self.skipBackOff(e) })
        let text = out.joined(separator: "\n")
        XCTAssertTrue(text.contains("queued 2 file(s)"), text)
        XCTAssertFalse(text.contains("image(s)"), text)
        XCTAssertTrue(text.contains("failed 2"), text)
        XCTAssertFalse(text.contains("failed 6"), text)
        XCTAssertEqual(try e.status().counts.filesByStatus["failed"], 2)       // what `follow` prints from the app's status
    }
}
