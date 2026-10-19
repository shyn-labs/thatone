import CoreGraphics
import XCTest
@testable import ThatOneCore

final class GoldenTests: XCTestCase {
    func testScoreUsesFirstRelevantResultWithinK() {
        let hits = [["/a"], ["/b", "/c"], ["/d"]]
        XCTAssertEqual(Golden.score(hits: hits, relevant: ["/c"]).hit, true)
        XCTAssertEqual(Golden.score(hits: hits, relevant: ["/c"]).reciprocalRank, 0.5)
        XCTAssertEqual(Golden.score(hits: hits, relevant: ["/z"]).hit, false)
        XCTAssertEqual(Golden.score(hits: hits, relevant: ["/d"], k: 2).hit, false)   // outside the top 2
        XCTAssertEqual(Golden.score(hits: [], relevant: ["/a"]).reciprocalRank, 0)
    }

    func testLoadDecodesJSON() throws {
        let url = TestSupport.tempDir().appendingPathComponent("g.json")
        try Data(#"[{"id":"q1","query":"a b","tag":"image","relevant":["/x.png"]}]"#.utf8).write(to: url)
        XCTAssertEqual(try Golden.load(url), [GoldenQuery(id: "q1", query: "a b", tag: "image", relevant: ["/x.png"])])
    }

    func testEvaluateAggregatesByTagAndReportsUnindexedFiles() throws {
        let folder = TestSupport.tempDir("pics")
        // a.png (width 300) reads "invoice 4471", b.png (width 310) reads "holiday photo"
        let engine = try Engine(paths: Paths(home: TestSupport.tempDir("home")), config: Config(),
                                keyProvider: StaticKeyProvider(TestSupport.key), embedder: FakeEmbedder(),
                                ocr: { $0.width == 300 ? "invoice 4471" : "holiday photo" })
        try makeImage(width: 300, height: 100, text: nil, at: folder.appendingPathComponent("a.png"))
        try makeImage(width: 310, height: 100, text: nil, at: folder.appendingPathComponent("b.png"))
        try engine.addFolder(folder.path)
        _ = try engine.scan()
        try engine.runIndexing()
        let a = RealPath.of(folder.path) + "/a.png", b = RealPath.of(folder.path) + "/b.png"
        let missing = RealPath.of(folder.path) + "/never-indexed.pdf"
        let queries = [
            GoldenQuery(id: "q1", query: "invoice", tag: "image", relevant: [a]),    // a ranks 1st
            GoldenQuery(id: "q2", query: "invoice", tag: "image", relevant: [b]),    // b ranks 2nd of 2
            GoldenQuery(id: "q3", query: "invoice", tag: "pdf", relevant: [missing]),
        ]
        let summary = try Golden.evaluate(engine: engine, queries: queries)
        XCTAssertEqual(summary.byTag["image"], EvalCell(hit10: 1, mrr: 0.75, n: 2))
        XCTAssertEqual(summary.byTag["pdf"], EvalCell(hit10: 0, mrr: 0, n: 1))
        XCTAssertEqual(summary.overall.n, 3)
        XCTAssertEqual(summary.misses, ["q3"])
        XCTAssertEqual(summary.unindexed, ["q3→" + missing])
        let onlyImages = try Golden.evaluate(engine: engine, queries: queries, tags: ["image"])
        XCTAssertEqual(onlyImages.overall, EvalCell(hit10: 1, mrr: 0.75, n: 2))
        XCTAssertTrue(onlyImages.unindexed.isEmpty)
        XCTAssertTrue(Golden.format(summary).contains("image"))
        XCTAssertTrue(Golden.format(summary).contains("q3"))
    }

    func testGoldenKindsReachCodeAndSearchesAreTimed() throws {
        let repo = TestSupport.tempDir("repo")
        CodeIndexingTests.write(CodeIndexingTests.source, "src/retry.swift", in: repo)
        let e = try CodeIndexingTests.makeEngine()
        try CodeIndexingTests.indexAll(e, repo)
        let path = RealPath.of(repo.path) + "/src/retry.swift"
        let queries = [GoldenQuery(id: "c1", query: "retryWithBackoff", tag: "code", relevant: [path], kinds: ["code"]),
                       GoldenQuery(id: "c2", query: "retryWithBackoff", tag: "code", relevant: [path])]      // default search: hidden
        let summary = try Golden.evaluate(engine: e, queries: queries)
        XCTAssertEqual(summary.byTag["code"], EvalCell(hit10: 0.5, mrr: 0.5, n: 2))
        XCTAssertEqual(summary.misses, ["c2"])
        XCTAssertEqual(summary.searchMs.count, 2)
        XCTAssertTrue(Golden.format(summary).contains("p95"))
        let url = TestSupport.tempDir().appendingPathComponent("g.json")
        try Data(#"[{"id":"q1","query":"a","tag":"code","relevant":["/x.ts"],"kinds":["code"],"lines":"3-14"},{"id":"q2","query":"b","tag":"image","relevant":["/y.png"]}]"#.utf8).write(to: url)
        XCTAssertEqual(try Golden.load(url).map { $0.kinds }, [["code"], nil])
    }

    func testPercentile() {
        XCTAssertEqual(Golden.percentile([5, 1, 3, 2, 4], 0.95), 5)
        XCTAssertEqual(Golden.percentile([5, 1, 3, 2, 4], 0.5), 3)
        XCTAssertEqual(Golden.percentile([], 0.95), 0)
    }
}
