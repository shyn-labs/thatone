import CoreGraphics
import XCTest
@testable import ThatOneCore

final class DocumentIndexingTests: XCTestCase {
    static let secretText = "deploy key sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789"

    final class Setup {
        let dir = TestSupport.tempDir("docidx")
        let store: Store
        let embedder = FakeEmbedder()
        let indexer: Indexer
        init(ocr: @escaping (CGImage) throws -> String = { _ in "" }, kinds: Set<String> = Kinds.defaultEnabled) throws {
            store = try Store.open(path: dir.appendingPathComponent("index.db").path, key: TestSupport.key, dim: FakeEmbedder.dim)
            indexer = Indexer(store: store, embedder: embedder, workDir: dir.appendingPathComponent("work"), exclusions: Exclusions(),
                              roots: { [] }, ocr: ocr, enabledKinds: { kinds })
        }
        func search(_ q: String) throws -> [SearchHit] { try Searcher(store: store).search(query: q, queryVector: nil) }
        var runFiles: [URL] { (try? FileManager.default.contentsOfDirectory(at: indexer.runDirectory, includingPropertiesForKeys: nil)) ?? [] }
    }

    func anchors(_ hit: SearchHit) -> [[String: Any]] {
        hit.anchors.compactMap { try? JSONSerialization.jsonObject(with: Data($0.anchor.utf8)) as? [String: Any] }
    }

    func testPDFIsIndexedAndFoundByPageText() throws {
        let s = try Setup()
        let url = PDFFixtures.file()
        PDFFixtures.make([.text("The notice period is thirty days from written notice."), .text("Invoices are due within forty five days of receipt.")], at: url)
        XCTAssertEqual(s.indexer.index(paths: [url.path]), [url.path: .indexed])
        XCTAssertEqual(try s.store.fileRecord(path: url.path)?.kind, "pdf")
        let hit = try XCTUnwrap(s.search("forty five days").first)
        XCTAssertEqual(hit.paths, [url.path])
        XCTAssertEqual(anchors(hit).first?["page"] as? Int, 2)
        XCTAssertEqual(try s.search("notice period").first.flatMap { anchors($0).first?["page"] as? Int }, 1)
    }

    func testScannedPageIsFoundByItsOCRTextAndKeepsAnImageSegment() throws {
        let s = try Setup(ocr: { _ in "tractor dealer invoice 4471" })
        let url = PDFFixtures.file()
        PDFFixtures.make([.image(PDFFixtures.scan("INVOICE"))], at: url)
        XCTAssertEqual(s.indexer.index(paths: [url.path]), [url.path: .indexed])
        XCTAssertEqual(try s.search("tractor").first?.paths, [url.path])
        XCTAssertEqual(try s.store.counts().segmentsByModality["image"], 1)
        XCTAssertEqual(s.embedder.callCount(.image), 1)
        XCTAssertTrue(s.runFiles.isEmpty, "page images are removed after embedding")
    }

    func testSecretOnAnyPageSkipsTheWholeFile() throws {
        let s = try Setup()
        let url = PDFFixtures.file()
        PDFFixtures.make([.text("An ordinary first page with harmless words in it."), .text(Self.secretText)], at: url)
        XCTAssertEqual(s.indexer.index(paths: [url.path]), [url.path: .skipped("secret")])
        XCTAssertTrue(s.embedder.calls.isEmpty)
        XCTAssertEqual(try s.search("harmless words").count, 0)                      // not even the clean page is searchable
        XCTAssertEqual(try s.store.fileRecord(path: url.path)?.status, "skipped")
    }

    func testNoPageImageIsWrittenBeforeTheSecretGate() throws {
        let s = try Setup(ocr: { _ in Self.secretText })
        let url = PDFFixtures.file()
        PDFFixtures.make([.image(PDFFixtures.scan("KEY"))], at: url)
        XCTAssertEqual(s.indexer.index(paths: [url.path]), [url.path: .skipped("secret")])
        XCTAssertTrue(s.embedder.calls.isEmpty)
        XCTAssertTrue(s.runFiles.isEmpty)
        // control: without a secret an image does reach the run folder while it is embedded
        let clean = try Setup(ocr: { _ in "ordinary scanned words" })
        var sawFile = false
        clean.embedder.onEmbed = { if !clean.runFiles.isEmpty { sawFile = true } }
        XCTAssertEqual(clean.indexer.index(paths: [url.path]), [url.path: .indexed])
        XCTAssertTrue(sawFile)
    }

    func testChangedPDFDropsOldSegments() throws {
        let s = try Setup()
        let url = PDFFixtures.file()
        PDFFixtures.make([.text("Original wording about harvest timing and soil moisture.")], at: url)
        XCTAssertEqual(s.indexer.index(paths: [url.path]), [url.path: .indexed])
        PDFFixtures.make([.text("Completely different wording about tractor maintenance schedules.")], at: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: url.path)
        XCTAssertEqual(s.indexer.index(paths: [url.path]), [url.path: .indexed])
        XCTAssertEqual(try s.search("harvest timing").count, 0)
        XCTAssertEqual(try s.search("tractor maintenance").count, 1)
    }

    func testRenamedDocumentLinksByHashWithoutReEmbedding() throws {
        let s = try Setup()
        let original = DocFixtures.convert(html: DocFixtures.sampleHTML, to: "docx", in: DocFixtures.dir())
        XCTAssertEqual(s.indexer.index(paths: [original.path]), [original.path: .indexed])
        let calls = s.embedder.calls.count
        XCTAssertGreaterThan(calls, 0)
        let renamed = original.deletingLastPathComponent().appendingPathComponent("renamed.docx")
        try FileManager.default.moveItem(at: original, to: renamed)
        let outcomes = s.indexer.index(paths: [renamed.path, original.path])
        XCTAssertEqual(outcomes[renamed.path], .linked)
        XCTAssertEqual(outcomes[original.path], .removed)
        XCTAssertEqual(s.embedder.calls.count, calls)
        XCTAssertEqual(try s.search("forty five days").first?.paths, [renamed.path])
    }

    func testLockedEmptyAndCorruptFilesAreSkippedOrFailedWithReasons() throws {
        let s = try Setup()
        let locked = PDFFixtures.file("locked.pdf")
        PDFFixtures.make([.text("Secret contents of a protected document, long enough.")], at: locked, password: "pw")
        let blank = PDFFixtures.file("blank.pdf")
        PDFFixtures.make([.blank], at: blank)
        let fake = PDFFixtures.file("fake.pdf")
        try Data("not really a pdf".utf8).write(to: fake)
        let outcomes = s.indexer.index(paths: [locked.path, blank.path, fake.path])
        XCTAssertEqual(outcomes[locked.path], .skipped("password-protected"))
        XCTAssertEqual(outcomes[blank.path], .skipped("no text found"))
        guard case .failed(let reason)? = outcomes[fake.path] else { return XCTFail("\(outcomes)") }
        XCTAssertTrue(reason.hasPrefix("cannot read"), reason)
        XCTAssertEqual(try s.store.fileRecord(path: locked.path)?.note, "password-protected")
        XCTAssertTrue(s.embedder.calls.isEmpty)
        XCTAssertEqual(s.indexer.index(paths: [locked.path]), [locked.path: .unchanged])          // not retried until it changes
    }

    func testPageCapIsRecordedInTheFileNote() throws {
        let saved = ReadLimits.maxPages
        ReadLimits.maxPages = 2
        defer { ReadLimits.maxPages = saved }
        let s = try Setup()
        let url = PDFFixtures.file()
        PDFFixtures.make((1...4).map { .text("Page \($0) holds ordinary words about the farm.") }, at: url)
        XCTAssertEqual(s.indexer.index(paths: [url.path]), [url.path: .indexed])
        XCTAssertEqual(try s.store.fileRecord(path: url.path)?.note, "first 2 pages")
    }

    func testEmbedderDownDefersADocumentAndRecordsNothing() throws {
        let s = try Setup()
        let url = PDFFixtures.file()
        PDFFixtures.make([.text("Ordinary words that will wait for the model to come back.")], at: url)
        s.embedder.failure = SidecarEmbedder.Failure.unavailable("offline")
        XCTAssertEqual(s.indexer.index(paths: [url.path]), [url.path: .deferred("embedding unavailable: offline")])
        XCTAssertNil(try s.store.fileRecord(path: url.path))
        s.embedder.failure = nil
        XCTAssertEqual(s.indexer.index(paths: [url.path]), [url.path: .indexed])
    }

    func testTextFilesNeedTheirKindSwitchedOn() throws {
        let url = DocFixtures.dir().appendingPathComponent("notes.txt")
        DocFixtures.write("Meeting notes about the notice period and the next harvest review.", to: url)
        let off = try Setup()
        XCTAssertEqual(off.indexer.index(paths: [url.path]), [url.path: .skipped("text files are switched off")])
        let on = try Setup(kinds: Kinds.defaultEnabled.union(["text"]))
        XCTAssertEqual(on.indexer.index(paths: [url.path]), [url.path: .indexed])
        XCTAssertEqual(try on.search("harvest review").first?.paths, [url.path])
    }

    func testManySegmentsAreEmbeddedInGroups() throws {
        let s = try Setup()
        let url = PDFFixtures.file()
        PDFFixtures.make((1...40).map { .text("Page \($0) discusses topic number \($0) at some length.") }, at: url)
        XCTAssertEqual(s.indexer.index(paths: [url.path]), [url.path: .indexed])
        XCTAssertEqual(s.embedder.callCount(.text), 3)                                          // 40 segments in groups of 16
        XCTAssertEqual(try s.store.counts().segmentsByModality["text"], 40)
    }

    func testASecretCutInHalfByTheChunkerIsStillCaught() throws {
        let s = try Setup(kinds: Kinds.defaultEnabled.union(["text"]))
        let url = DocFixtures.dir().appendingPathComponent("blob.txt")
        // 1,790 characters without any space, then a key: the chunker's hard cut at 1,800 lands inside the key.
        DocFixtures.write(String(repeating: "a", count: 1790) + "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789" + " tail words after it", to: url)
        XCTAssertEqual(s.indexer.index(paths: [url.path]), [url.path: .skipped("secret")])
        XCTAssertTrue(s.embedder.calls.isEmpty)
    }

    func testASecretStraddlingTheCharacterLimitIsStillCaught() throws {
        let saved = ReadLimits.maxChars
        ReadLimits.maxChars = 1000
        defer { ReadLimits.maxChars = saved }
        let s = try Setup(kinds: Kinds.defaultEnabled.union(["text"]))
        let url = DocFixtures.dir().appendingPathComponent("long.txt")
        DocFixtures.write(String(repeating: "word ", count: 195) + "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789" + " more text", to: url)   // key starts at 975
        XCTAssertEqual(s.indexer.index(paths: [url.path]), [url.path: .skipped("secret")])
    }
}
