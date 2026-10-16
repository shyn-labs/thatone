import XCTest
@testable import ThatOneCore

final class AssetsScanTests: XCTestCase {
    func makeEngine(photos: Bool = true, _ provider: FakeAssetProvider, ocr: String = "invoice 4471") throws -> Engine {
        try Engine(paths: Paths(home: TestSupport.tempDir("home")), config: Config(photos: photos),
                   keyProvider: StaticKeyProvider(TestSupport.key), embedder: FakeEmbedder(), ocr: { _ in ocr }, assets: provider)
    }

    func photoPaths(_ e: Engine) throws -> [String] { try e.store.filePaths(withPrefix: PhotosPath.scheme) }

    func testScanQueuesNewAndChangedAssetsOnly() throws {
        let p = FakeAssetProvider()
        p.add("A/L0/001", width: 300); p.add("B/L0/001", width: 310)
        let e = try makeEngine(p)
        XCTAssertEqual(try e.scanPhotos().enqueued, 2)
        try e.runIndexing()
        XCTAssertEqual(try e.scanPhotos(), Crawler.ScanResult())                   // nothing changed
        p.add("B/L0/001", width: 320, mtime: 2000)                                 // edited in Photos
        p.add("C/L0/001", width: 330)                                              // new
        XCTAssertEqual(try e.scanPhotos().enqueued, 2)
    }

    func testVideosAreRecordedOnceThenIgnored() throws {
        let p = FakeAssetProvider()
        p.add("V/L0/001", filename: "M.MOV", width: 300, video: true)
        let e = try makeEngine(p)
        XCTAssertEqual(try e.scanPhotos().enqueued, 1)
        try e.runIndexing()
        XCTAssertEqual(try e.scanPhotos().enqueued, 0)
        XCTAssertEqual(try e.store.fileRecord(path: p.assets["V/L0/001"]!.path)?.note, AssetNotes.video)
    }

    func testDeletedAssetsArePurgedWhenEnumerationSucceeds() throws {
        let p = FakeAssetProvider()
        p.add("A/L0/001", width: 300); p.add("B/L0/001", width: 310)
        let e = try makeEngine(p)
        _ = try e.scanPhotos(); try e.runIndexing()
        XCTAssertEqual(try photoPaths(e).count, 2)
        p.assets["A/L0/001"] = nil
        XCTAssertEqual(try e.scanPhotos().purgeQueued, 1)
        try e.runIndexing()
        XCTAssertEqual(try photoPaths(e).count, 1)
    }

    func testFailedEnumerationPurgesNothing() throws {
        let p = FakeAssetProvider()
        p.add("A/L0/001", width: 300)
        let e = try makeEngine(p)
        _ = try e.scanPhotos(); try e.runIndexing()
        p.enumerateFailure = EngineError.cannotLock("photos library busy")
        XCTAssertEqual(try e.scanPhotos(), Crawler.ScanResult())
        for denied in [AssetAuthorization.denied, .restricted, .notDetermined] {
            p.enumerateFailure = nil; p.auth = denied
            XCTAssertEqual(try e.scanPhotos(), Crawler.ScanResult(), "\(denied)")
        }
        XCTAssertEqual(try photoPaths(e).count, 1)
        XCTAssertEqual(try e.queue.counts(), QueueCounts(queued: 0, running: 0, failed: 0))
    }

    func testLimitedAccessPurgesWhatIsNoLongerVisible() throws {
        let p = FakeAssetProvider()
        p.add("A/L0/001", width: 300); p.add("B/L0/001", width: 310)
        let e = try makeEngine(p)
        _ = try e.scanPhotos(); try e.runIndexing()
        p.auth = .limited
        p.assets["B/L0/001"] = nil                                                 // the user shrank the selection
        _ = try e.scanPhotos(); try e.runIndexing()
        XCTAssertEqual(try photoPaths(e), [p.assets["A/L0/001"]!.path])
    }

    func testICloudSkippedAssetsRetryOnlyWhenAsked() throws {
        let p = FakeAssetProvider()
        p.add("A/L0/001", width: 300)
        p.cloud = ["A/L0/001"]
        let e = try makeEngine(p)
        _ = try e.scanPhotos(); try e.runIndexing()
        XCTAssertEqual(try e.scanPhotos().enqueued, 0)
        p.cloud = []
        XCTAssertEqual(try e.scanPhotos().enqueued, 0)                             // not until asked
        XCTAssertEqual(try e.scanPhotos(retryInCloud: true).enqueued, 1)
        try e.runIndexing()
        XCTAssertEqual(try e.store.fileRecord(path: p.assets["A/L0/001"]!.path)?.status, "indexed")
    }

    func testForgetAndExcludeLeavePhotosPathsIntact() throws {
        let p = FakeAssetProvider()
        let a = p.add("A/L0/001", filename: "IMG A.JPG", width: 300)
        let b = p.add("B/L0/001", filename: "IMG B.JPG", width: 310)
        let e = try makeEngine(p)
        _ = try e.scanPhotos(); try e.runIndexing()
        try e.forget(path: a)
        XCTAssertEqual(try photoPaths(e), [b])
        try e.exclude(b)
        XCTAssertEqual(try photoPaths(e), [])
        XCTAssertEqual(e.config.exclude, [b])                                      // stored as is, not made absolute
        _ = try e.scanPhotos(); try e.runIndexing()
        XCTAssertEqual(try photoPaths(e), [a])                                     // the forgotten one returns, the excluded does not
    }

    func testDisablingPhotosForgetsEverything() throws {
        let p = FakeAssetProvider()
        p.add("A/L0/001", width: 300); p.add("B/L0/001", width: 310)
        let e = try makeEngine(p)
        _ = try e.scanPhotos(); try e.runIndexing()
        XCTAssertEqual(try Searcher(store: e.store).search(query: "invoice", queryVector: nil).count, 2)  // identical OCR text, two assets
        _ = try e.scanPhotos()                                                     // new jobs waiting
        try e.setPhotos(false)
        XCTAssertEqual(try photoPaths(e), [])
        XCTAssertEqual(try e.queue.counts(), QueueCounts(queued: 0, running: 0, failed: 0))
        XCTAssertEqual(try Searcher(store: e.store).search(query: "invoice", queryVector: nil).count, 0)
        XCTAssertEqual(try e.scan().enqueued, 0)                                   // and it stays off
        XCTAssertFalse(try Config.load(from: e.paths.config).photos)
        try e.setPhotos(true)
        XCTAssertEqual(try e.scanPhotos().enqueued, 2)
    }

    func testWorkInFlightWhenPhotosIsSwitchedOffDoesNotReAddRows() throws {
        let p = FakeAssetProvider()
        for i in 0..<3 { p.add("A\(i)/L0/001", width: 300 + i) }
        let fake = FakeEmbedder()
        let e = try Engine(paths: Paths(home: TestSupport.tempDir("home")), config: Config(photos: true),
                           keyProvider: StaticKeyProvider(TestSupport.key), embedder: fake, ocr: { _ in "words" }, assets: p)
        _ = try e.scanPhotos()
        var off = false
        fake.onEmbed = { if !off { off = true; try? e.setPhotos(false) } }
        try e.runIndexing()
        XCTAssertEqual(try photoPaths(e), [])
    }

    func testPhotosOffByDefaultAndScanIgnoresTheProviderWhenOff() throws {
        let p = FakeAssetProvider()
        p.add("A/L0/001", width: 300)
        let e = try makeEngine(photos: false, p)
        XCTAssertEqual(try e.scanPhotos(), Crawler.ScanResult())
        XCTAssertEqual(try e.scan().enqueued, 0)
        XCTAssertFalse(Config().photos)
    }

    func testConfigPhotosRoundTrips() throws {
        let url = TestSupport.tempDir().appendingPathComponent("config.json")
        try Config(photos: true).save(to: url)
        XCTAssertTrue(try Config.load(from: url).photos)
        try Data("{}".utf8).write(to: url)
        XCTAssertFalse(try Config.load(from: url).photos)
    }

    func testSwitchingPhotosOffBetweenLookupAndLoadLeavesNoFailedRowOrJob() throws {
        let p = FakeAssetProvider()
        let b = p.add("B/L0/001", filename: "b.JPG", width: 300)
        let e = try makeEngine(p)
        try e.queue.enqueue(path: b, priority: 1)
        p.onInfo = { id in if id == "B/L0/001" { try? e.setPhotos(false) } }        // flips after info() said "exists"
        try e.runIndexing()
        XCTAssertEqual(try photoPaths(e), [])                                       // no "failed: Photos is off" row
        XCTAssertEqual(try e.queue.counts(), QueueCounts(queued: 0, running: 0, failed: 0))
    }

    func testTurningPhotosBackOnIsNotWipedByAnEarlierOff() throws {
        let p = FakeAssetProvider()
        p.add("A/L0/001", width: 300)
        let e = try makeEngine(p)
        try e.setPhotos(false)
        try e.setPhotos(true)
        _ = try e.scanPhotos(); try e.runIndexing()
        XCTAssertEqual(try photoPaths(e).count, 1)
    }

    func testAnEmptyEnumerationNeverPurgesExistingRows() throws {
        let p = FakeAssetProvider()
        p.add("A/L0/001", width: 300)
        let e = try makeEngine(p)
        _ = try e.scanPhotos(); try e.runIndexing()
        p.assets = [:]                                                              // an unmounted library looks empty
        XCTAssertEqual(try e.scanPhotos(), Crawler.ScanResult())
        XCTAssertEqual(try photoPaths(e).count, 1)
    }

    func testSimilarAndRemoveExclusionWorkOnPhotosPaths() throws {
        let p = FakeAssetProvider()
        let a = p.add("A/L0/001", filename: "a.JPG", width: 300)
        let b = p.add("B/L0/001", filename: "b.JPG", width: 301)
        let e = try makeEngine(p)
        _ = try e.scanPhotos(); try e.runIndexing()
        XCTAssertEqual(try e.similar(toPath: a).hits.flatMap { $0.paths }, [b])
        try e.exclude(b)
        XCTAssertEqual(e.config.exclude, [b])
        try e.removeExclusion(b)
        XCTAssertEqual(e.config.exclude, [])
    }

    func testRevokedAccessDoesNotDeleteQueuedAssetsRows() throws {
        let p = FakeAssetProvider()
        let a = p.add("A/L0/001", width: 300)
        let e = try makeEngine(p)
        _ = try e.scanPhotos(); try e.runIndexing()
        p.auth = .denied                                                            // PhotoKit would now report assets as gone
        p.assets["A/L0/001"] = nil
        try e.queue.enqueue(path: a, priority: 1)
        try e.runIndexing()
        XCTAssertEqual(try photoPaths(e), [a])
    }
}
