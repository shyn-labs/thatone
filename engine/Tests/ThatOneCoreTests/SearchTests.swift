import XCTest
@testable import ThatOneCore

final class SearchTests: XCTestCase {
    func makeStore() throws -> Store {
        try Store.open(path: TestSupport.tempDir().appendingPathComponent("a.db").path, key: TestSupport.key, dim: 4)
    }

    @discardableResult
    func add(_ s: Store, hash: String, paths: [String], kind: String = "image", mtime: Int64 = 100,
             segments: [(String, String, [Float])]) throws -> Int64 {
        let id = try s.addContent(hash: hash, kind: kind, status: "indexed",
                                  segments: segments.map { SegmentInput(modality: $0.0, text: $0.1, vector: $0.2) })
        for p in paths { try s.upsertFile(path: p, contentId: id, kind: kind, size: 1, mtime: mtime, status: "indexed") }
        return id
    }

    func testFtsExpressionIsSafeAndDeduplicated() {
        XCTAssertEqual(Tokens.ftsExpression("Invoice #4471, it's \"x\" invoice"),
                       "\"invoice\" OR \"4471\" OR \"it\" OR \"s\" OR \"x\"")
        XCTAssertNil(Tokens.ftsExpression("!!! ,,, ---"))
        XCTAssertEqual(Tokens.words("ಬೆಂಗಳೂರು ಮನೆ"), ["ಬೆಂಗಳೂರು", "ಮನೆ"])
    }

    func testHostileQueryDoesNotThrow() throws {
        let s = try makeStore()
        try add(s, hash: "h", paths: ["/a.png"], segments: [("text", "hello", [1, 0, 0, 0])])
        XCTAssertNoThrow(try Searcher(store: s).search(query: "\" OR ) AND NOT * NEAR(", queryVector: nil))
    }

    func testPooledSearchDoesNotForceEveryModalityIntoTheTop() throws {
        let s = try makeStore()
        let img1 = try add(s, hash: "i1", paths: ["/i1.png"], segments: [("image", "", [1, 0, 0, 0])])
        let img2 = try add(s, hash: "i2", paths: ["/i2.png"], segments: [("image", "", [0.4, 0.9, 0, 0])])
        for n in 0..<5 {   // unrelated audio clips must not be injected above relevant images
            try add(s, hash: "a\(n)", paths: ["/a\(n).wav"], kind: "audio", segments: [("audio", "", [0, 0, 1, Float(n)])])
        }
        let hits = try Searcher(store: s).search(query: "zzz", queryVector: [1, 0.1, 0, 0])
        XCTAssertEqual(hits.prefix(2).map { $0.contentId }, [img1, img2])
    }

    func testKeywordOnlyMatchesWhenTermIsInEverySegment() throws {
        let s = try makeStore()
        for n in 0..<3 {
            try add(s, hash: "h\(n)", paths: ["/\(n).png"], segments: [("text", "biochar trial notes \(n)", [1, 0, 0, 0])])
        }
        let hits = try Searcher(store: s).search(query: "biochar trial", queryVector: nil)
        XCTAssertEqual(hits.count, 3)
    }

    func testKannadaFragmentDoesNotMatchWholeWord() throws {
        let s = try makeStore()
        try add(s, hash: "k", paths: ["/k.png"], segments: [("text", "ಬೆಂಗಳೂರು ಮನೆ", [1, 0, 0, 0])])
        let searcher = Searcher(store: s)
        XCTAssertEqual(try searcher.search(query: "ಬೆಂಗಳೂರು", queryVector: nil).count, 1)
        XCTAssertEqual(try searcher.search(query: "ಬ", queryVector: nil).count, 0)
    }

    func testGroupingKeepsBestThreeAnchorsPerContent() throws {
        let s = try makeStore()
        try add(s, hash: "p", paths: ["/p.png"], segments: (0..<5).map { ("text", "pipe number \($0)", [1, 0, 0, 0]) })
        let hits = try Searcher(store: s).search(query: "pipe", queryVector: nil)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].anchors.count, 3)
    }

    func testDuplicateContentListsEveryPathOnce() throws {
        let s = try makeStore()
        try add(s, hash: "d", paths: ["/one/a.png", "/two/a copy.png"], segments: [("text", "shared words", [1, 0, 0, 0])])
        let hits = try Searcher(store: s).search(query: "shared", queryVector: nil)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].paths, ["/one/a.png", "/two/a copy.png"])
    }

    func testFiltersByKindFolderAndDate() throws {
        let s = try makeStore()
        try add(s, hash: "1", paths: ["/photos/100%_done/a.png"], mtime: 100, segments: [("text", "pipe", [1, 0, 0, 0])])
        try add(s, hash: "2", paths: ["/photos/100x_done/b.png"], mtime: 200, segments: [("text", "pipe", [1, 0, 0, 0])])
        try add(s, hash: "3", paths: ["/docs/c.pdf"], kind: "pdf", mtime: 300, segments: [("text", "pipe", [1, 0, 0, 0])])
        let searcher = Searcher(store: s)
        func paths(_ f: SearchFilters) throws -> [String] {
            try searcher.search(query: "pipe", queryVector: nil, filters: f).flatMap { $0.paths }.sorted()
        }
        XCTAssertEqual(try paths(SearchFilters(kinds: ["pdf"])), ["/docs/c.pdf"])
        XCTAssertEqual(try paths(SearchFilters(folder: "/photos/100%_done")), ["/photos/100%_done/a.png"])
        XCTAssertEqual(try paths(SearchFilters(since: 150, until: 250)), ["/photos/100x_done/b.png"])
        XCTAssertEqual(try paths(SearchFilters()).count, 3)
    }

    func testQueryVectorWithWrongDimensionThrows() throws {
        let s = try makeStore()
        XCTAssertThrowsError(try Searcher(store: s).search(query: "x", queryVector: [1, 0])) {
            XCTAssertEqual($0 as? StoreError, .badVector(expected: 4, got: 2))
        }
    }

    func testFilesWithoutIndexedStatusAreNeverReturned() throws {
        let s = try makeStore()
        // The content has segments, but the file row is not 'indexed', so it must not be returned.
        let id = try s.addContent(hash: "sk", kind: "image", status: "indexed",
                                  segments: [SegmentInput(modality: "text", text: "secret words", vector: [1, 0, 0, 0])])
        try s.upsertFile(path: "/secret.png", contentId: id, kind: "image", size: 1, mtime: 1, status: "skipped", note: "secret")
        XCTAssertEqual(try Searcher(store: s).search(query: "secret", queryVector: [1, 0, 0, 0]).count, 0)
    }

    func testAnchorsReportHowTheyMatched() throws {
        let s = try makeStore()
        try add(s, hash: "a", paths: ["/a.png"],
                segments: [("image", "invoice 4471", [1, 0, 0, 0]), ("text", "invoice 4471", [0, 1, 0, 0])])
        let searcher = Searcher(store: s)
        let both = try XCTUnwrap(searcher.search(query: "invoice", queryVector: [1, 0.05, 0, 0]).first)
        let image = try XCTUnwrap(both.anchors.first { $0.modality == "image" })
        XCTAssertTrue(image.viaVector)
        XCTAssertTrue(image.viaKeyword)                       // its text matched the word too
        let vectorOnly = try XCTUnwrap(searcher.search(query: "zzz", queryVector: [1, 0, 0, 0]).first)
        XCTAssertTrue(vectorOnly.anchors.allSatisfy { !$0.viaKeyword })
        XCTAssertTrue(vectorOnly.anchors.contains { $0.viaVector })
        let keywordOnly = try XCTUnwrap(searcher.search(query: "invoice", queryVector: nil).first)
        XCTAssertTrue(keywordOnly.anchors.allSatisfy { !$0.viaVector })
        XCTAssertTrue(keywordOnly.anchors.contains { $0.viaKeyword })
    }

    func testHitsCarryTheNewestModificationTime() throws {
        let s = try makeStore()
        let id = try add(s, hash: "m", paths: ["/one.png"], mtime: 100, segments: [("text", "pipe", [1, 0, 0, 0])])
        try s.upsertFile(path: "/two.png", contentId: id, kind: "image", size: 1, mtime: 300, status: "indexed")
        let hit = try XCTUnwrap(Searcher(store: s).search(query: "pipe", queryVector: nil).first)
        XCTAssertEqual(hit.modified, 300)
    }

    func testRecentOrdersByModificationTimeDedupesAndFilters() throws {
        let s = try makeStore()
        try add(s, hash: "1", paths: ["/p/old.png"], mtime: 100, segments: [("text", "a", [1, 0, 0, 0])])
        let shared = try add(s, hash: "2", paths: ["/p/new.png"], mtime: 300, segments: [("text", "b", [0, 1, 0, 0])])
        try s.upsertFile(path: "/p/new copy.png", contentId: shared, kind: "image", size: 1, mtime: 250, status: "indexed")
        try add(s, hash: "3", paths: ["/docs/x.pdf"], kind: "pdf", mtime: 200, segments: [("text", "c", [0, 0, 1, 0])])
        let searcher = Searcher(store: s)
        let all = try searcher.recent()
        XCTAssertEqual(all.map { $0.paths.sorted().first }, ["/p/new copy.png", "/docs/x.pdf", "/p/old.png"])
        XCTAssertEqual(all.first?.paths.count, 2)                               // duplicate content: one hit, both paths
        XCTAssertTrue(all.allSatisfy { $0.anchors.isEmpty && $0.score == 0 })
        XCTAssertEqual(try searcher.recent(filters: SearchFilters(kinds: ["pdf"])).count, 1)
        XCTAssertEqual(try searcher.recent(filters: SearchFilters(folder: "/p")).count, 2)
        XCTAssertEqual(try searcher.recent(limit: 1).count, 1)
    }

    func testSimilarRanksNearestFirstAndExcludesItself() throws {
        let s = try makeStore()
        let anchor = try add(s, hash: "a", paths: ["/a.png"], segments: [("image", "", [1, 0, 0, 0])])
        let near = try add(s, hash: "n", paths: ["/near.png"], segments: [("image", "", [0.9, 0.3, 0, 0])])
        let far = try add(s, hash: "f", paths: ["/far.png"], segments: [("image", "", [0, 0, 1, 0])])
        let hits = try Searcher(store: s).similar(toContentId: anchor)
        XCTAssertEqual(hits.map { $0.contentId }, [near, far])
        XCTAssertFalse(hits.contains { $0.contentId == anchor })
        XCTAssertTrue(hits[0].anchors.allSatisfy { $0.viaVector && !$0.viaKeyword })
        XCTAssertEqual(try Searcher(store: s).similar(toContentId: anchor, limit: 1).map { $0.contentId }, [near])
    }

    func testSimilarOfAContentWithoutVectorsIsEmpty() throws {
        let s = try makeStore()
        let id = try s.addContent(hash: "sk", kind: "image", status: "skipped", note: "secret", segments: [])
        XCTAssertEqual(try Searcher(store: s).similar(toContentId: id), [])
        XCTAssertEqual(try Searcher(store: s).similar(toContentId: 9999), [])
    }

    func testHostileLimitsDoNotCrash() throws {
        let s = try makeStore()
        let id = try add(s, hash: "l", paths: ["/a.png"], segments: [("image", "word", [1, 0, 0, 0])])
        let searcher = Searcher(store: s)
        XCTAssertEqual(try searcher.search(query: "word", queryVector: nil, limit: -5), [])
        XCTAssertEqual(try searcher.search(query: "word", queryVector: nil, limit: Int.max).count, 1)
        XCTAssertEqual(try searcher.recent(limit: -1), [])
        XCTAssertEqual(try searcher.recent(limit: Int.max).count, 1)
        XCTAssertEqual(try searcher.similar(toContentId: id, limit: Int.max), [])
        XCTAssertEqual(try searcher.similar(toContentId: id, limit: -3), [])
    }
}
