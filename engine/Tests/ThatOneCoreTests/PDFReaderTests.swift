import PDFKit
import XCTest
@testable import ThatOneCore

final class PDFReaderTests: XCTestCase {
    func anchorObject(_ s: ReadSegment) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.anchor.utf8)) as? [String: Any]) ?? [:]
    }

    func testTextPDFGivesOneSegmentPerPageWithPageNumbers() throws {
        let url = PDFFixtures.file()
        PDFFixtures.make([.text("The notice period is thirty days. Termination needs written notice."),
                          .text("Payment terms: invoices are due within forty five days of receipt.")], at: url)
        let result = try PDFReader().read(url)
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments.map { $0.modality }, ["text", "text"])
        XCTAssertEqual(result.segments.map { anchorObject($0)["page"] as? Int }, [1, 2])
        XCTAssertTrue(result.segments[0].text.contains("notice period"))
        XCTAssertTrue(result.segments[1].text.contains("forty five days"))
        XCTAssertEqual(result.note, "")
    }

    func testScannedPageIsOCRdAndKeptAsAnImage() throws {
        let url = PDFFixtures.file()
        PDFFixtures.make([.text("A page with a real text layer, long enough to count."), .image(PDFFixtures.scan("INVOICE 4471"))], at: url)
        var ocrCalls = 0
        let result = try PDFReader(ocr: { _ in ocrCalls += 1; return "INVOICE 4471 tractor" }).read(url)
        XCTAssertEqual(ocrCalls, 1)                                                   // only the scanned page is OCR'd
        XCTAssertEqual(result.segments.map { $0.modality }, ["text", "text", "image"])
        let image = try XCTUnwrap(result.segments.last)
        XCTAssertEqual(anchorObject(image)["page"] as? Int, 2)
        XCTAssertEqual(image.text, "INVOICE 4471 tractor")
        XCTAssertLessThanOrEqual(max(image.image?.width ?? 0, image.image?.height ?? 0), ImagePrep.embedMaxSide)
        XCTAssertNotNil(image.image)
    }

    func testRealVisionOCRReadsAScannedPage() throws {
        let url = PDFFixtures.file()
        PDFFixtures.make([.image(PDFFixtures.scan("INVOICE 4471"))], at: url)
        let result = try PDFReader().read(url)
        let text = result.segments.filter { $0.modality == "text" }.map { $0.text }.joined(separator: " ")
        XCTAssertTrue(text.contains("4471"), "OCR read: \(text)")
    }

    func testOCRFailureOnAScannedPageFailsTheFileBecauseTheSecretGateCannotRun() {
        struct Boom: Error {}
        let url = PDFFixtures.file()
        PDFFixtures.make([.image(PDFFixtures.scan("SECRET"))], at: url)
        XCTAssertThrowsError(try PDFReader(ocr: { _ in throw Boom() }).read(url)) {
            guard case .unreadable? = $0 as? ReadFailure else { return XCTFail("\($0)") }
        }
    }

    func testPasswordProtectedPDFIsLocked() {
        let url = PDFFixtures.file()
        PDFFixtures.make([.text("Top secret contents of a locked file that is long enough.")], at: url, password: "hunter2")
        XCTAssertThrowsError(try PDFReader().read(url)) { XCTAssertEqual($0 as? ReadFailure, .locked) }
    }

    func testNotAPDFAndEmptyPDFsAreRefusedWithReasons() throws {
        let fake = PDFFixtures.file("fake.pdf")
        try Data("this is not a pdf".utf8).write(to: fake)
        XCTAssertThrowsError(try PDFReader().read(fake)) {
            guard case .unreadable? = $0 as? ReadFailure else { return XCTFail("\($0)") }
        }
        let blank = PDFFixtures.file("blank.pdf")
        PDFFixtures.make([.blank, .blank], at: blank)
        XCTAssertThrowsError(try PDFReader(ocr: { _ in "" }).read(blank)) {         // two blank pages: nothing to index
            guard case .empty? = $0 as? ReadFailure else { return XCTFail("\($0)") }
        }
        let none = PDFFixtures.file("none.pdf")
        PDFFixtures.make([], at: none)
        XCTAssertThrowsError(try PDFReader().read(none))                            // zero pages: empty or unreadable, never a crash
    }

    func testPageCapIsRecordedInTheNote() throws {
        let saved = ReadLimits.maxPages
        ReadLimits.maxPages = 5
        defer { ReadLimits.maxPages = saved }
        let url = PDFFixtures.file()
        PDFFixtures.make((1...9).map { .text("Page number \($0) has plenty of ordinary words on it.") }, at: url)
        let result = try PDFReader().read(url)
        XCTAssertEqual(result.segments.count, 5)
        XCTAssertEqual(result.note, "first 5 pages")
    }

    func testScannedPageCapIsRecordedInTheNote() throws {
        let saved = ReadLimits.maxScannedPages
        ReadLimits.maxScannedPages = 2
        defer { ReadLimits.maxScannedPages = saved }
        let url = PDFFixtures.file()
        let image = PDFFixtures.scan("PAGE")
        PDFFixtures.make((1...5).map { _ in .image(image) }, at: url)
        var ocrCalls = 0
        let result = try PDFReader(ocr: { _ in ocrCalls += 1; return "scanned words here" }).read(url)
        XCTAssertEqual(ocrCalls, 2)
        XCTAssertEqual(result.segments.filter { $0.modality == "image" }.count, 2)
        XCTAssertTrue(result.note.contains("3 scanned pages beyond the first 2 not read"), result.note)
    }

    func testAHugePageIsChunkedNotOneGiantSegment() throws {
        let url = PDFFixtures.file()
        let line = String(repeating: "alpha bravo charlie delta ", count: 8)           // about 200 characters per line
        PDFFixtures.make([.text(Array(repeating: line, count: 400).joined(separator: "\n"), fontSize: 1.5)], at: url)
        let result = try PDFReader().read(url)
        XCTAssertGreaterThan(result.segments.count, 3)
        for s in result.segments {
            XCTAssertLessThanOrEqual(s.text.count, 1800)
            XCTAssertEqual(anchorObject(s)["page"] as? Int, 1)
            XCTAssertNotNil(anchorObject(s)["part"])
        }
        XCTAssertEqual(result.segments.compactMap { anchorObject($0)["part"] as? Int }, Array(1...result.segments.count))
    }

    func testTextLimitStopsReadingAndSaysSo() throws {
        let saved = ReadLimits.maxChars
        ReadLimits.maxChars = 150
        defer { ReadLimits.maxChars = saved }
        let url = PDFFixtures.file()
        PDFFixtures.make((1...6).map { .text("Page \($0): " + String(repeating: "word ", count: 20)) }, at: url)
        let result = try PDFReader().read(url)
        XCTAssertLessThan(result.segments.count, 6)
        XCTAssertTrue(result.note.contains("text limit"), result.note)
    }

    func testOversizedFilesAreRefusedBeforeBeingOpened() throws {
        let saved = ReadLimits.maxFileBytes
        ReadLimits.maxFileBytes = 100
        defer { ReadLimits.maxFileBytes = saved }
        let url = PDFFixtures.file()
        PDFFixtures.make([.text("Some ordinary text on a page of a small but over the limit file.")], at: url)
        XCTAssertThrowsError(try PDFReader().read(url)) { guard case .tooLarge? = $0 as? ReadFailure else { return XCTFail("\($0)") } }
    }

    func testCleanRemovesControlCharactersAndCollapsesBlanks() {
        XCTAssertEqual(PDFReader.clean("a \u{7} b\u{0C}  c\t\td\r\ne"), "a b c d\ne")
    }

    /// Reads the grey value of one pixel of an image (0 = black, 255 = white).
    func gray(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        var pixel: UInt8 = 0
        withUnsafeMutablePointer(to: &pixel) { pointer in
            let context = CGContext(data: pointer, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        return pixel
    }

    func testAScannedPageIsRenderedAtFullScaleNotAsASmallBlock() throws {
        let url = PDFFixtures.file()
        PDFFixtures.make([.fill], at: url)                                           // a page that is black edge to edge
        let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        let image = try XCTUnwrap(PDFReader.render(page, longSide: PDFReader.ocrSide))
        XCTAssertEqual(max(image.width, image.height), PDFReader.ocrSide)
        for (x, y) in [(2, 2), (image.width - 3, 2), (2, image.height - 3), (image.width - 3, image.height - 3), (image.width / 2, image.height / 2)] {
            XCTAssertLessThan(gray(image, x: x, y: y), 40, "pixel (\(x), \(y)) is white: the page was drawn small in the middle")
        }
    }
}
