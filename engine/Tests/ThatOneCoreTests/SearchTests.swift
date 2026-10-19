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

    func testCodeIsLeftOutUnlessASearchNamesIt() throws {
        let s = try makeStore()
        let img = try add(s, hash: "i", paths: ["/p/a.png"], segments: [("text", "retry backoff photo", [1, 0, 0, 0])])
        let code = try add(s, hash: "c", paths: ["/r/retry.ts"], kind: "code", segments: [("text", "retry backoff", [1, 0, 0, 0])])
        let searcher = Searcher(store: s)
        XCTAssertEqual(try searcher.search(query: "retry", queryVector: [1, 0, 0, 0]).map { $0.contentId }, [img])
        XCTAssertEqual(try searcher.search(query: "retry", queryVector: [1, 0, 0, 0], filters: SearchFilters(kinds: ["code"])).map { $0.contentId }, [code])
        XCTAssertEqual(Set(try searcher.search(query: "retry", queryVector: [1, 0, 0, 0],
                                               filters: SearchFilters(kinds: ["code", "image"])).map { $0.contentId }), [img, code])
        XCTAssertEqual(try searcher.search(query: "retry", queryVector: nil, filters: SearchFilters(folder: "/r")).count, 0)
        XCTAssertEqual(try searcher.recent().map { $0.contentId }, [img])
        XCTAssertEqual(try searcher.recent(filters: SearchFilters(kinds: ["code"])).map { $0.contentId }, [code])
        XCTAssertEqual(try searcher.similar(toContentId: img).map { $0.contentId }, [])
        XCTAssertEqual(try searcher.similar(toContentId: img, filters: SearchFilters(kinds: ["code"])).map { $0.contentId }, [code])
    }

    func testALargeCodeIndexDoesNotPushOtherKindsOutOfADefaultSearch() throws {
        let s = try makeStore()
        for n in 0..<450 {        // more code segments nearer to the query than the whole vector pool (100 x 4)
            try add(s, hash: "c\(n)", paths: ["/r/f\(n).ts"], kind: "code", segments: [("text", "", [1, 0.001 * Float(n), 0, 0])])
        }
        let img = try add(s, hash: "i", paths: ["/p/a.png"], segments: [("image", "", [0.5, 0.5, 0.5, 0.5])])
        XCTAssertEqual(try Searcher(store: s).search(query: "", queryVector: [1, 0, 0, 0]).map { $0.contentId }, [img])
    }

    func testCodeKeywordHitsDoNotCrowdTheKeywordPool() throws {
        let s = try makeStore()
        for n in 0..<150 {        // more keyword hits than the keyword pool (100), each scoring higher than the image
            try add(s, hash: "k\(n)", paths: ["/r/k\(n).ts"], kind: "code", segments: [("text", "invoice invoice invoice", [0, 0, 0, 1])])
        }
        let img = try add(s, hash: "i", paths: ["/p/a.png"], segments: [("text", "invoice total due in thirty days", [0, 0, 1, 0])])
        XCTAssertEqual(try Searcher(store: s).search(query: "invoice", queryVector: nil).map { $0.contentId }, [img])
    }

    func testMoreLikeThisFromCodeReturnsCodeAndFromAnImageReturnsNone() throws {
        let s = try makeStore()
        let img = try add(s, hash: "i", paths: ["/p/a.png"], segments: [("image", "", [1, 0, 0, 0])])
        let code = try add(s, hash: "c", paths: ["/r/retry.ts"], kind: "code", segments: [("text", "retry", [1, 0, 0, 0])])
        let other = try add(s, hash: "d", paths: ["/r/backoff.ts"], kind: "code", segments: [("text", "backoff", [0.9, 0.1, 0, 0])])
        let searcher = Searcher(store: s)
        XCTAssertEqual(try searcher.similar(toContentId: code).map { $0.contentId }, [other])          // the source's hidden kind is named
        XCTAssertEqual(try searcher.similar(toContentId: img).map { $0.contentId }, [])               // unchanged: no code
        XCTAssertEqual(try searcher.similar(toContentId: code, filters: SearchFilters(kinds: ["image"])).map { $0.contentId }, [img])
    }

    func testANamedKindSearchIsNotCrowdedByHiddenKindsItDoesNotName() throws {
        let s = try makeStore()
        try s.transaction {
            for n in 0..<2000 {   // more code nearer to the query than a named-kind vector fetch (400 x 4), and more keyword
                                  // hits, each outscoring the image, than any widened keyword fetch (400 x 4) would reach
                try add(s, hash: "c\(n)", paths: ["/r/f\(n).ts"], kind: "code",
                        segments: [("text", "invoice invoice invoice", [1, 0.0001 * Float(n), 0, 0])])
            }
        }
        let img = try add(s, hash: "i", paths: ["/p/a.png"], segments: [("image", "invoice total due", [0.5, 0.5, 0.5, 0.5])])
        let searcher = Searcher(store: s)
        let images = SearchFilters(kinds: ["image"])
        XCTAssertEqual(try searcher.search(query: "", queryVector: [1, 0, 0, 0], filters: images).map { $0.contentId }, [img])
        XCTAssertEqual(try searcher.search(query: "invoice", queryVector: nil, filters: images).map { $0.contentId }, [img])
        XCTAssertEqual(try searcher.search(query: "invoice", queryVector: nil).map { $0.contentId }, [img])      // default search
    }

    func testACodeOnlySearchIsNotCrowdedByOutrankingProse() throws {
        let s = try makeStore()
        try s.transaction {
            for n in 0..<2000 {   // PDF segments that beat the code chunk on both sides, more than either fetch reaches
                try add(s, hash: "p\(n)", paths: ["/docs/p\(n).pdf"], kind: "pdf",
                        segments: [("text", "retry retry retry", [1, 0.0001 * Float(n), 0, 0])])
            }
        }
        let code = try add(s, hash: "c", paths: ["/r/retry.ts"], kind: "code",
                           segments: [("text", "export function retry(fn, attempts, delay, jitter, signal, onError, log)", [0.2, 0.9, 0.3, 0.1])])
        let searcher = Searcher(store: s)
        let codeOnly = SearchFilters(kinds: ["code"])
        let keyword = try searcher.search(query: "retry", queryVector: nil, filters: codeOnly)
        XCTAssertEqual(keyword.map { $0.contentId }, [code])
        XCTAssertEqual(keyword.first?.anchors.first?.viaKeyword, true)
        let vector = try searcher.search(query: "", queryVector: [1, 0, 0, 0], filters: codeOnly)
        XCTAssertEqual(vector.map { $0.contentId }, [code])
        XCTAssertEqual(vector.first?.anchors.first?.viaVector, true)
        // Nothing changes for a search that names no kind: prose wins and code stays out.
        let open = try searcher.search(query: "retry", queryVector: [1, 0, 0, 0], limit: 3)
        XCTAssertEqual(open.map { $0.kind }, ["pdf", "pdf", "pdf"])
    }

    func testAnExistingDatabaseGainsTheContentsKindIndex() throws {
        let path = TestSupport.tempDir().appendingPathComponent("old.db").path
        func hasIndex(_ s: Store) throws -> Bool {
            try s.int("select count(*) from sqlite_master where type = 'index' and name = 'contents_kind'") == 1
        }
        do {   // a database as the previous release left it: schema 2, no index on contents(kind)
            let s = try Store.open(path: path, key: TestSupport.key, dim: 4)
            try s.run("drop index contents_kind")
            try s.run("update meta set value = '2' where key = 'schema_version'")
            _ = try add(s, hash: "c", paths: ["/r/a.ts"], kind: "code", segments: [("text", "kept", [1, 0, 0, 0])])
            XCTAssertFalse(try hasIndex(s))
            s.close()
        }
        let s = try Store.open(path: path, key: TestSupport.key, dim: 4)
        XCTAssertTrue(try hasIndex(s))
        XCTAssertEqual(try s.int("select value from meta where key = 'schema_version'"), Int64(Schema.migrations.count))
        XCTAssertEqual(try Searcher(store: s).search(query: "kept", queryVector: nil, filters: SearchFilters(kinds: ["code"])).count, 1)
        let plan = try s.query("explain query plan select 1 from contents where status = 'indexed' and kind in ('code')") { $0.text(3) }
        XCTAssertTrue(plan.contains { $0.contains("contents_kind") }, "\(plan)")
    }
}
