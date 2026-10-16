import XCTest
@testable import ThatOneCore

final class KindsEngineTests: XCTestCase {
    /// A watched folder with two PDFs, a docx, a txt and a png.
    func makeFolder() throws -> URL {
        let folder = TestSupport.tempDir("mix")
        PDFFixtures.make([.text("Contract page one talks about the notice period.")], at: folder.appendingPathComponent("a.pdf"))
        PDFFixtures.make([.text("Second contract is about payment terms and invoices.")], at: folder.appendingPathComponent("b.pdf"))
        let docx = DocFixtures.convert(html: DocFixtures.sampleHTML, to: "docx", in: DocFixtures.dir())
        try FileManager.default.copyItem(at: docx, to: folder.appendingPathComponent("c.docx"))
        DocFixtures.write("Plain notes about the farm visit and the soil samples taken there.", to: folder.appendingPathComponent("d.txt"))
        try makeImage(width: 300, height: 100, text: nil, at: folder.appendingPathComponent("e.png"))
        return folder
    }

    func makeEngine(_ config: Config = Config(), embedder: FakeEmbedder = FakeEmbedder()) throws -> Engine {
        try Engine(paths: Paths(home: TestSupport.tempDir("home")), config: config, keyProvider: StaticKeyProvider(TestSupport.key),
                   embedder: embedder, ocr: { _ in "" })
    }

    /// Keyword matches only: the fake embedder's vectors would make every file a near neighbour.
    func keyword(_ e: Engine, _ q: String, _ filters: SearchFilters = SearchFilters()) throws -> [SearchHit] {
        try Searcher(store: e.store).search(query: q, queryVector: nil, filters: filters)
    }

    func indexAll(_ e: Engine, _ folder: URL) throws {
        try e.addFolder(folder.path)
        _ = try e.scan()
        try e.runIndexing()
    }

    func testDefaultKindsIndexPDFsDocumentsAndImagesButNotTextFiles() throws {
        let e = try makeEngine()
        try indexAll(e, try makeFolder())
        XCTAssertEqual(try e.status().counts.filesByKind, ["pdf": 2, "document": 1, "image": 1])
        XCTAssertEqual(try e.status().counts.filesByStatus["indexed"], 4)
        XCTAssertEqual(try keyword(e, "soil samples").count, 0)                              // the txt was never read
    }

    func testStatusShowsFilesPerKindThroughTheService() throws {
        let e = try makeEngine()
        try indexAll(e, try makeFolder())
        XCTAssertEqual(try LocalEngineService(engine: e).status().kinds, ["pdf": 2, "document": 1, "image": 1])
    }

    func testKindFilterWorksForPDFsAndDocuments() throws {
        let e = try makeEngine()
        try indexAll(e, try makeFolder())
        let pdfs = try keyword(e, "notice period", SearchFilters(kinds: ["pdf"]))
        XCTAssertEqual(pdfs.map { ($0.paths[0] as NSString).lastPathComponent }, ["a.pdf"])
        XCTAssertEqual(try keyword(e, "notice period", SearchFilters(kinds: ["document"])).map { $0.kind }, ["document"])
        XCTAssertEqual(try e.recent(filters: SearchFilters(kinds: ["pdf"])).hits.count, 2)
    }

    func testKindSwitchedOffPurgesAndStaysOff() throws {
        let e = try makeEngine()
        let folder = try makeFolder()
        try indexAll(e, folder)
        try e.setKinds(["image", "document"])                                                   // PDFs off
        XCTAssertEqual(try e.status().counts.filesByKind, ["document": 1, "image": 1])
        XCTAssertEqual(try keyword(e, "notice period", SearchFilters(kinds: ["pdf"])).count, 0)
        XCTAssertEqual(try Config.load(from: e.paths.config).kinds, ["image", "document"])
        _ = try e.scan(); try e.runIndexing()                                                    // a rescan must not bring them back
        XCTAssertEqual(try e.status().counts.filesByKind, ["document": 1, "image": 1])
        try e.setKinds(["image", "document", "pdf"])                                             // and switching on restores them
        _ = try e.scan(); try e.runIndexing()
        XCTAssertEqual(try e.status().counts.filesByKind, ["pdf": 2, "document": 1, "image": 1])
    }

    func testSwitchingOffImagesKeepsApplePhotosRows() throws {
        let photos = FakeAssetProvider()
        photos.add("A/L0/001", width: 300)
        let e = try Engine(paths: Paths(home: TestSupport.tempDir("home")), config: Config(photos: true), keyProvider: StaticKeyProvider(TestSupport.key),
                           embedder: FakeEmbedder(), ocr: { _ in "words" }, assets: photos)
        try indexAll(e, try makeFolder())
        XCTAssertEqual(try e.photoCount(), 1)
        try e.setKinds(["pdf", "document"])
        XCTAssertEqual(try e.photoCount(), 1)                                                    // Photos has its own switch
        XCTAssertEqual(try e.status().counts.filesByKind["image"], 1)                            // only the photo is left
    }

    func testKindSwitchedOffDuringIndexingLeavesNothingBehind() throws {
        let fake = FakeEmbedder()
        let e = try makeEngine(embedder: fake)
        let folder = try makeFolder()
        try e.addFolder(folder.path)
        _ = try e.scan()
        var flipped = false
        fake.onEmbed = { if !flipped { flipped = true; try? e.setKinds(["image"]) } }            // PDFs and documents switched off mid-run
        try e.runIndexing()
        XCTAssertTrue(flipped)
        XCTAssertEqual(try e.status().counts.filesByKind["pdf"] ?? 0, 0)
        XCTAssertEqual(try e.status().counts.filesByKind["document"] ?? 0, 0)
        XCTAssertEqual(try e.queue.counts(), QueueCounts(queued: 0, running: 0, failed: 0))
    }

    func testEnqueueFilesRespectsEnabledKinds() throws {
        let e = try makeEngine()
        let folder = try makeFolder()
        let queued = try e.enqueue(files: ["a.pdf", "c.docx", "d.txt", "e.png"].map { folder.appendingPathComponent($0).path })
        XCTAssertEqual(queued, 3)                                                                 // d.txt is not an enabled kind
    }

    func testTextFilesIndexWhenSwitchedOn() throws {
        let e = try makeEngine(Config(kinds: Kinds.defaultEnabled.union(["text"])))
        try indexAll(e, try makeFolder())
        XCTAssertEqual(try e.status().counts.filesByKind["text"], 1)
        XCTAssertEqual(try keyword(e, "soil samples").count, 1)
    }

    func testAnEmptyKindSetIndexesNothing() throws {
        let e = try makeEngine(Config(kinds: []))
        try indexAll(e, try makeFolder())
        XCTAssertEqual(try e.status().counts.filesByStatus["indexed"] ?? 0, 0)
    }

    func testImagesSwitchedOffWhileABatchIsEmbeddingAreNotStored() throws {
        let fake = FakeEmbedder()
        let e = try makeEngine(embedder: fake)
        let folder = TestSupport.tempDir("pics")
        try makeImage(width: 300, height: 100, text: nil, at: folder.appendingPathComponent("a.png"))
        try e.addFolder(folder.path)
        _ = try e.scan()
        var flipped = false
        // Switching off, then a scan (which drains the pending purge) before the batch commits: only the commit-time check can save it.
        fake.onEmbed = { if !flipped { flipped = true; try? e.setKinds(["pdf"]); _ = try? e.scan() } }
        try e.runIndexing()
        XCTAssertTrue(flipped)
        XCTAssertEqual(try e.status().counts.filesByKind["image"] ?? 0, 0)
    }

    func testAPDFSwitchedOffBetweenReadingAndCommitIsNotStored() throws {
        let fake = FakeEmbedder()
        let e = try makeEngine(embedder: fake)
        let folder = TestSupport.tempDir("pdfs")
        PDFFixtures.make([.text("A contract page with ordinary words about notice periods.")], at: folder.appendingPathComponent("a.pdf"))
        try e.addFolder(folder.path)
        _ = try e.scan()
        var flipped = false
        fake.onEmbed = { if !flipped { flipped = true; try? e.setKinds(["image"]); _ = try? e.scan() } }
        try e.runIndexing()
        XCTAssertTrue(flipped)
        XCTAssertEqual(try e.status().counts.filesByKind["pdf"] ?? 0, 0)
    }
}
