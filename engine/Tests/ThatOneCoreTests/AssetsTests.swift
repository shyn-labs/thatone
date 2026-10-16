import CoreGraphics
import XCTest
@testable import ThatOneCore

final class AssetsTests: XCTestCase {
    final class Setup {
        let dir = TestSupport.tempDir("assets")
        let store: Store
        let embedder = FakeEmbedder()
        let provider = FakeAssetProvider()
        let indexer: Indexer
        init(ocr: @escaping (CGImage) throws -> String = { _ in "invoice 4471" }) throws {
            store = try Store.open(path: dir.appendingPathComponent("index.db").path, key: TestSupport.key, dim: FakeEmbedder.dim)
            indexer = Indexer(store: store, embedder: embedder, workDir: dir.appendingPathComponent("work"),
                              exclusions: Exclusions(), roots: { [] }, ocr: ocr, assets: provider)
        }
    }

    func testPhotosPathRoundTrips() {
        for (id, name) in [("9F3C/L0/001", "IMG 8481.HEIC"), ("ABC", "it's \"x\".jpg"), ("A/L0/001", "ಕನ್ನಡ.png")] {
            let path = PhotosPath.make(id: id, filename: name)
            XCTAssertTrue(PhotosPath.isPhotos(path))
            let parsed = PhotosPath.parse(path)
            XCTAssertEqual(parsed?.id, id)
            XCTAssertEqual(parsed?.filename, name)
        }
        XCTAssertNil(PhotosPath.parse("/Users/me/a.png"))
        XCTAssertNil(PhotosPath.parse("photos:noslash"))
        XCTAssertNil(PhotosPath.parse("photos:/x"))
    }

    func testAnAssetIsIndexedLikeAFile() throws {
        let s = try Setup()
        let path = s.provider.add("A/L0/001", filename: "IMG_8481.HEIC", width: 300)
        XCTAssertEqual(s.indexer.index(paths: [path]), [path: .indexed])
        let record = try XCTUnwrap(try s.store.fileRecord(path: path))
        XCTAssertEqual(record.kind, "image")
        XCTAssertEqual(record.status, "indexed")
        XCTAssertEqual(record.mtime, 1000)
        XCTAssertEqual(record.size, 30000)
        XCTAssertEqual(try Searcher(store: s.store).search(query: "invoice", queryVector: nil).first?.paths, [path])
    }

    func testUnchangedAssetIsUnchangedAndEditedAssetIsReindexed() throws {
        var text = "first words here"
        let s = try Setup(ocr: { _ in text })
        let path = s.provider.add("B/L0/001", width: 300)
        XCTAssertEqual(s.indexer.index(paths: [path]), [path: .indexed])
        XCTAssertEqual(s.indexer.index(paths: [path]), [path: .unchanged])
        text = "second words here"
        s.provider.add("B/L0/001", width: 310, mtime: 2000)              // edited in Photos
        XCTAssertEqual(s.indexer.index(paths: [path]), [path: .indexed])
        XCTAssertEqual(try Searcher(store: s.store).search(query: "first", queryVector: nil).count, 0)
        XCTAssertEqual(try Searcher(store: s.store).search(query: "second", queryVector: nil).count, 1)
    }

    func testGoneAssetIsRemoved() throws {
        let s = try Setup()
        let path = s.provider.add("C/L0/001", width: 300)
        XCTAssertEqual(s.indexer.index(paths: [path]), [path: .indexed])
        s.provider.assets["C/L0/001"] = nil
        XCTAssertEqual(s.indexer.index(paths: [path]), [path: .removed])
        XCTAssertNil(try s.store.fileRecord(path: path))
        XCTAssertEqual(try Searcher(store: s.store).search(query: "invoice", queryVector: nil).count, 0)
    }

    func testVideoAndInCloudAreSkippedNotFailed() throws {
        let s = try Setup()
        let video = s.provider.add("D/L0/001", filename: "MOV.MOV", width: 300, video: true)
        let cloud = s.provider.add("E/L0/001", width: 301)
        s.provider.cloud = ["E/L0/001"]
        let outcomes = s.indexer.index(paths: [video, cloud])
        XCTAssertEqual(outcomes[video], .skipped(AssetNotes.video))
        XCTAssertEqual(outcomes[cloud], .skipped(AssetNotes.inCloud))
        XCTAssertEqual(try s.store.fileRecord(path: video)?.status, "skipped")
        XCTAssertEqual(try s.store.fileRecord(path: cloud)?.note, AssetNotes.inCloud)
        XCTAssertTrue(s.embedder.calls.isEmpty)
        XCTAssertEqual(s.provider.loads, ["E/L0/001"])                   // the video's pixels were never requested
        s.provider.cloud = []                                            // the original arrives later
        XCTAssertEqual(s.indexer.index(paths: [cloud]), [cloud: .indexed])
    }

    func testSecretInAPhotoSkipsTheWholeAsset() throws {
        let s = try Setup(ocr: { _ in "my password: sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789" })
        let path = s.provider.add("F/L0/001", width: 300)
        XCTAssertEqual(s.indexer.index(paths: [path]), [path: .skipped("secret")])
        XCTAssertTrue(s.embedder.calls.isEmpty)
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: s.indexer.runDirectory, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
    }

    func testIdenticalPicturesLinkByHash() throws {
        let s = try Setup()
        let a = s.provider.add("G/L0/001", width: 300)
        let b = s.provider.add("H/L0/001", filename: "copy.JPG", width: 300)
        let outcomes = s.indexer.index(paths: [a])
        XCTAssertEqual(outcomes[a], .indexed)
        XCTAssertEqual(s.indexer.index(paths: [b]), [b: .linked])
    }

    func testAnAssetFailureIsIsolatedAndTheEmbedderBeingDownDefers() throws {
        let s = try Setup()
        let bad = s.provider.add("I/L0/001", width: 300)
        let good = s.provider.add("J/L0/001", width: 311)
        s.provider.loadFailures["I/L0/001"] = "corrupt"
        let outcomes = s.indexer.index(paths: [bad, good])
        guard case .failed? = outcomes[bad] else { return XCTFail("\(outcomes)") }
        XCTAssertEqual(outcomes[good], .indexed)
        let later = s.provider.add("K/L0/001", width: 322)
        s.embedder.failure = SidecarEmbedder.Failure.unavailable("offline")
        XCTAssertEqual(s.indexer.index(paths: [later]), [later: .deferred("embedding unavailable: offline")])
        XCTAssertNil(try s.store.fileRecord(path: later))
    }
}
