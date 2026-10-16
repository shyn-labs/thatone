import CoreGraphics
import ImageIO
import XCTest
@testable import ThatOneCore

final class ImagePrepTests: XCTestCase {
    var dir: URL!
    override func setUp() { dir = TestSupport.tempDir("img") }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testLargeImageIsDownscaled() throws {
        let src = dir.appendingPathComponent("big.png")
        try makeImage(width: 4000, height: 3000, text: nil, at: src)
        let p = try ImagePrep.prepare(src, workDir: dir.appendingPathComponent("w"), name: "a")
        XCTAssertEqual(max(p.ocrImage.width, p.ocrImage.height), 3000)
        let small = CGImageSourceCreateWithURL(p.embedJPEG as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }!
        XCTAssertEqual(max(small.width, small.height), 1024)
    }

    func testSmallImageIsNotEnlarged() throws {
        let src = dir.appendingPathComponent("small.png")
        try makeImage(width: 300, height: 200, text: nil, at: src)
        let p = try ImagePrep.prepare(src, workDir: dir.appendingPathComponent("w"), name: "s")
        XCTAssertEqual(p.ocrImage.width, 300)
    }

    func testOrientationIsApplied() throws {
        let src = dir.appendingPathComponent("rot.png")
        try makeImage(width: 400, height: 200, text: nil, orientation: 6, at: src)
        let p = try ImagePrep.prepare(src, workDir: dir.appendingPathComponent("w"), name: "b")
        XCTAssertEqual(p.ocrImage.width, 200)
        XCTAssertEqual(p.ocrImage.height, 400)
    }

    func testUnreadableFileThrows() throws {
        let bad = dir.appendingPathComponent("bad.png")
        try Data("nope".utf8).write(to: bad)
        XCTAssertThrowsError(try ImagePrep.prepare(bad, workDir: dir, name: "c")) {
            XCTAssertEqual($0 as? ImagePrepError, .unreadable(bad.path))
        }
    }

    func testOCRReadsText() throws {
        let src = dir.appendingPathComponent("t.png")
        try makeImage(width: 1200, height: 300, text: "INVOICE 4471", at: src)
        let p = try ImagePrep.prepare(src, workDir: dir.appendingPathComponent("w"), name: "d")
        XCTAssertTrue(try OCR.text(in: p.ocrImage).contains("4471"))
    }

    func testBlankImageHasNoText() throws {
        let src = dir.appendingPathComponent("blank.png")
        try makeImage(width: 400, height: 400, text: nil, at: src)
        let p = try ImagePrep.prepare(src, workDir: dir.appendingPathComponent("w"), name: "e")
        XCTAssertEqual(try OCR.text(in: p.ocrImage), "")
    }

    func testImagesOverThePixelCapAreRefusedBeforeDecoding() throws {
        let src = dir.appendingPathComponent("big.png")
        try makeImage(width: 200, height: 100, text: nil, at: src)
        let old = ImagePrep.maxPixels
        ImagePrep.maxPixels = 1000
        defer { ImagePrep.maxPixels = old }
        XCTAssertThrowsError(try ImagePrep.decode(src)) { XCTAssertEqual($0 as? ImagePrepError, .tooLarge(src.path)) }
    }

    func testDecodeWritesNothingAndWriteJPEGCreatesItsFolder() throws {
        let src = dir.appendingPathComponent("a.png")
        try makeImage(width: 300, height: 100, text: nil, at: src)
        let decoded = try ImagePrep.decode(src)
        let out = dir.appendingPathComponent("not/yet/there/a.jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.deletingLastPathComponent().path))
        try ImagePrep.writeJPEG(decoded.smallImage, to: out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
    }
}
