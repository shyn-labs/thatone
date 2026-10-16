import XCTest
@testable import ThatOneCore

final class ContentStoreTests: XCTestCase {
    func open(dim: Int = 4) throws -> (Store, String) {
        let path = TestSupport.tempDir().appendingPathComponent("a.db").path
        return (try Store.open(path: path, key: TestSupport.key, dim: dim), path)
    }

    func seg(_ text: String, _ v: [Float], modality: String = "text") -> SegmentInput {
        SegmentInput(modality: modality, text: text, vector: v)
    }

    func testMigrateStoresDimensionAndRejectsMismatch() throws {
        let (s, path) = try open(dim: 4)
        XCTAssertEqual(s.dim, 4)
        s.close()
        XCTAssertThrowsError(try Store.open(path: path, key: TestSupport.key, dim: 8)) {
            XCTAssertEqual($0 as? StoreError, .dimensionMismatch(stored: 4, requested: 8))
        }
        XCTAssertEqual(try Store.open(path: path, key: TestSupport.key, dim: 4).dim, 4)
        XCTAssertEqual(try Store(path: path, key: TestSupport.key).storedDim(), 4)
    }

    func testStoredDimIsNilForFreshDatabase() throws {
        let s = try Store(path: TestSupport.tempDir().appendingPathComponent("a.db").path, key: TestSupport.key)
        XCTAssertNil(try s.storedDim())
    }

    func testAddContentAndFileRoundTrip() throws {
        let (s, _) = try open()
        let id = try s.addContent(hash: "h1", kind: "image", status: "indexed", segments: [
            seg("invoice 4471", [1, 0, 0, 0], modality: "image"), seg("invoice 4471", [0, 1, 0, 0]),
        ])
        try s.upsertFile(path: "/tmp/a.png", contentId: id, kind: "image", size: 10, mtime: 20, status: "indexed")
        XCTAssertEqual(try s.contentByHash("h1"), ContentRecord(id: id, status: "indexed", note: ""))
        XCTAssertNil(try s.contentByHash("nope"))
        XCTAssertEqual(try s.fileRecord(path: "/tmp/a.png"),
                       FileRecord(id: 1, path: "/tmp/a.png", contentId: id, kind: "image", size: 10, mtime: 20, status: "indexed", note: ""))
        let c = try s.counts()
        XCTAssertEqual(c.contents, 1)
        XCTAssertEqual(c.filesByStatus, ["indexed": 1])
        XCTAssertEqual(c.segmentsByModality, ["image": 1, "text": 1])
    }

    func testTwoPathsShareOneContentUntilBothAreRemoved() throws {
        let (s, _) = try open()
        let id = try s.addContent(hash: "h1", kind: "image", status: "indexed", segments: [seg("alpha", [1, 0, 0, 0])])
        try s.upsertFile(path: "/tmp/a.png", contentId: id, kind: "image", size: 1, mtime: 1, status: "indexed")
        try s.upsertFile(path: "/tmp/b.png", contentId: id, kind: "image", size: 1, mtime: 1, status: "indexed")
        XCTAssertTrue(try s.removeFile(path: "/tmp/a.png"))
        XCTAssertEqual(try s.counts().contents, 1)            // still referenced by b.png
        XCTAssertEqual(try s.int("select count(*) from segments"), 1)
    }

    func testRemovingLastFileDeletesSegmentsFtsAndVectors() throws {
        let (s, _) = try open()
        let id = try s.addContent(hash: "h1", kind: "image", status: "indexed", segments: [seg("alpha", [1, 0, 0, 0])])
        try s.upsertFile(path: "/tmp/a.png", contentId: id, kind: "image", size: 1, mtime: 1, status: "indexed")
        XCTAssertTrue(try s.removeFile(path: "/tmp/a.png"))
        XCTAssertFalse(try s.removeFile(path: "/tmp/a.png"))   // already gone
        XCTAssertEqual(try s.int("select count(*) from contents"), 0)
        XCTAssertEqual(try s.int("select count(*) from segments"), 0)
        XCTAssertEqual(try s.int("select count(*) from segments_fts"), 0)
        XCTAssertEqual(try s.int("select count(*) from segment_vectors"), 0)
    }

    func testReplacingFileContentRemovesOldSegments() throws {
        let (s, _) = try open()
        let a = try s.addContent(hash: "hA", kind: "image", status: "indexed", segments: [seg("alpha", [1, 0, 0, 0])])
        try s.upsertFile(path: "/tmp/a.png", contentId: a, kind: "image", size: 1, mtime: 1, status: "indexed")
        let b = try s.addContent(hash: "hB", kind: "image", status: "indexed", segments: [seg("beta", [0, 1, 0, 0])])
        try s.upsertFile(path: "/tmp/a.png", contentId: b, kind: "image", size: 2, mtime: 2, status: "indexed")
        XCTAssertEqual(try s.int("select count(*) from segments_fts where segments_fts match 'alpha'"), 0)
        XCTAssertEqual(try s.int("select count(*) from segments_fts where segments_fts match 'beta'"), 1)
        XCTAssertEqual(try s.int("select count(*) from segments"), 1)
        XCTAssertEqual(try s.int("select count(*) from segment_vectors"), 1)
        XCTAssertNil(try s.contentByHash("hA"))
    }

    func testFailedFileHasNoContentAndIsListed() throws {
        let (s, _) = try open()
        try s.upsertFile(path: "/tmp/bad.png", contentId: nil, kind: "image", size: 3, mtime: 4, status: "failed", note: "cannot decode")
        XCTAssertEqual(try s.failedFiles().map { "\($0.path)|\($0.note)" }, ["/tmp/bad.png|cannot decode"])
        XCTAssertEqual(try s.counts().filesByStatus, ["failed": 1])
    }

    func testBadVectorLengthLeavesNothingBehind() throws {
        let (s, _) = try open()
        XCTAssertThrowsError(try s.addContent(hash: "h", kind: "image", status: "indexed",
                                              segments: [seg("ok", [1, 0, 0, 0]), seg("bad", [1, 0, 0])])) {
            XCTAssertEqual($0 as? StoreError, .badVector(expected: 4, got: 3))
        }
        XCTAssertEqual(try s.counts().contents, 0)
        XCTAssertEqual(try s.int("select count(*) from segments"), 0)
    }

    func testFilePathsUnderIsLiteral() throws {
        let (s, _) = try open()
        for p in ["/tmp/100%_done/a.png", "/tmp/100x_done/b.png", "/tmp/100%_done2/c.png",
                  "/tmp/ಕನ್ನಡ ಫೋಲ್ಡರ್/it's \"x\".png"] {
            try s.upsertFile(path: p, contentId: nil, kind: "image", size: 1, mtime: 1, status: "failed")
        }
        XCTAssertEqual(try s.filePaths(under: "/tmp/100%_done"), ["/tmp/100%_done/a.png"])
        XCTAssertEqual(try s.filePaths(under: "/tmp/ಕನ್ನಡ ಫೋಲ್ಡರ್/"), ["/tmp/ಕನ್ನಡ ಫೋಲ್ಡರ್/it's \"x\".png"])
        XCTAssertEqual(try s.fileRecord(path: "/tmp/ಕನ್ನಡ ಫೋಲ್ಡರ್/it's \"x\".png")?.kind, "image")
    }
}
