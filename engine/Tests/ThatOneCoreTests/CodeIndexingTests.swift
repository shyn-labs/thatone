import XCTest
@testable import ThatOneCore

final class CodeIndexingTests: XCTestCase {
    /// Line 1 import, 2 blank, 3...14 `retryWithBackoff`.
    static let source = (["import Foundation", "", "func retryWithBackoff(attempts: Int) -> Double {"]
        + (0..<10).map { "    delay *= 2 // step \($0)" } + ["}"]).joined(separator: "\n") + "\n"

    static func makeEngine(kinds: Set<String> = Kinds.defaultEnabled.union(["code"]), embedder: FakeEmbedder = FakeEmbedder()) throws -> Engine {
        try Engine(paths: Paths(home: TestSupport.tempDir("home")), config: Config(kinds: kinds),
                   keyProvider: StaticKeyProvider(TestSupport.key), embedder: embedder, ocr: { _ in "" })
    }
    static func write(_ text: String, _ relative: String, in root: URL) {
        let url = root.appendingPathComponent(relative)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: url)
    }
    static func indexAll(_ e: Engine, _ root: URL) throws { try e.addFolder(root.path); _ = try e.scan(); try e.runIndexing() }
    func keyword(_ e: Engine, _ q: String, kinds: Set<String> = ["code"]) throws -> [SearchHit] {
        try Searcher(store: e.store).search(query: q, queryVector: nil, filters: SearchFilters(kinds: kinds))
    }

    func testCodeIsIndexedWithLineAnchorsAndFoundByKeyword() throws {
        let repo = TestSupport.tempDir("repo")
        Self.write(Self.source, "src/retry.swift", in: repo)
        let e = try Self.makeEngine()
        try Self.indexAll(e, repo)
        XCTAssertEqual(try e.status().counts.filesByKind["code"], 1)
        let hit = try XCTUnwrap(keyword(e, "retryWithBackoff").first)
        XCTAssertEqual(hit.kind, "code")
        XCTAssertEqual(hit.paths, [RealPath.of(repo.path) + "/src/retry.swift"])
        XCTAssertTrue(hit.anchors.contains { $0.anchor == #"{"line0":3,"line1":14,"symbol":"retryWithBackoff"}"# })
        XCTAssertTrue(hit.anchors.allSatisfy { $0.modality == "text" })
    }

    func testCodeIsOffByDefault() throws {
        let repo = TestSupport.tempDir("repo")
        Self.write(Self.source, "src/retry.swift", in: repo)
        let e = try Self.makeEngine(kinds: Kinds.defaultEnabled)
        try Self.indexAll(e, repo)
        XCTAssertNil(try e.status().counts.filesByKind["code"])
    }

    func testASecretAnywhereSkipsTheWholeFile() throws {
        let repo = TestSupport.tempDir("repo")
        Self.write(Self.source + "// " + DocumentIndexingTests.secretText + "\n", "src/leaky.swift", in: repo)
        let fake = FakeEmbedder()
        let e = try Self.makeEngine(embedder: fake)
        try Self.indexAll(e, repo)
        let record = try XCTUnwrap(e.store.fileRecord(path: RealPath.of(repo.path) + "/src/leaky.swift"))
        XCTAssertEqual(record.status, "skipped"); XCTAssertEqual(record.note, "secret")
        XCTAssertEqual(try keyword(e, "retryWithBackoff").count, 0)
        XCTAssertFalse(fake.calls.contains { $0.2.contains { $0.contains("retryWithBackoff") } })
    }

    func testSkippedCodeFilesAreRecordedWithTheirReason() throws {
        let repo = TestSupport.tempDir("repo")
        Self.write("var a=1\n", "web/app.min.js", in: repo)
        Self.write(String(repeating: "let a = 1\n", count: 100_001), "big.swift", in: repo)
        let e = try Self.makeEngine()
        try Self.indexAll(e, repo)
        let real = RealPath.of(repo.path)
        XCTAssertEqual(try e.store.fileRecord(path: real + "/web/app.min.js")?.note, "minified")
        XCTAssertEqual(try e.store.fileRecord(path: real + "/big.swift")?.note, "too large")
        XCTAssertEqual(try e.store.fileRecord(path: real + "/big.swift")?.status, "skipped")
        XCTAssertEqual(try e.status().queue.failed, 0)
    }

    func testSwitchingCodeOffPurgesIt() throws {
        let repo = TestSupport.tempDir("repo")
        Self.write(Self.source, "src/retry.swift", in: repo)
        let e = try Self.makeEngine()
        try Self.indexAll(e, repo)
        try e.setKinds(Kinds.defaultEnabled)
        XCTAssertNil(try e.status().counts.filesByKind["code"])
        XCTAssertEqual(try keyword(e, "retryWithBackoff").count, 0)
    }

    func testABinaryCodeFileIsRecordedAsNotATextFile() throws {
        let repo = TestSupport.tempDir("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data([0x7F, 0x45, 0x4C, 0x46, 0x00, 0x01, 0x02]).write(to: repo.appendingPathComponent("src/blob.ts"))
        try Data(repeating: 0xFF, count: 400).write(to: repo.appendingPathComponent("src/latin.ts"))
        let e = try Self.makeEngine()
        try Self.indexAll(e, repo)
        let real = RealPath.of(repo.path)
        for name in ["blob.ts", "latin.ts"] {
            let record = try XCTUnwrap(e.store.fileRecord(path: real + "/src/" + name))
            XCTAssertEqual(record.status, "skipped", name); XCTAssertEqual(record.note, "not a text file", name)
        }
        XCTAssertEqual(try e.status().queue.failed, 0)
    }

    func testASecretDeepInACRLFFileSkipsItWithNothingSearchable() throws {
        let repo = TestSupport.tempDir("repo")
        let long = (0..<300).map { "    total += \($0)" }.joined(separator: "\r\n")
        Self.write(Self.source.replacingOccurrences(of: "\n", with: "\r\n") + "func tail() {\r\n" + long + "\r\n    // "
                   + DocumentIndexingTests.secretText + "\r\n}\r\n", "src/deep.swift", in: repo)
        let e = try Self.makeEngine()
        try Self.indexAll(e, repo)
        let record = try XCTUnwrap(e.store.fileRecord(path: RealPath.of(repo.path) + "/src/deep.swift"))
        XCTAssertEqual(record.status, "skipped"); XCTAssertEqual(record.note, "secret")
        XCTAssertEqual(try keyword(e, "retryWithBackoff").count, 0)
        XCTAssertEqual(try keyword(e, "total").count, 0)
    }

    func testTheServiceLeavesCodeOutUnlessAsked() throws {
        let repo = TestSupport.tempDir("repo")
        Self.write(Self.source, "src/retry.swift", in: repo)
        let e = try Self.makeEngine()
        try Self.indexAll(e, repo)
        let service = LocalEngineService(engine: e)
        XCTAssertEqual(try service.search(ServiceQuery(query: "retryWithBackoff")).hits.count, 0)
        XCTAssertEqual(try service.search(ServiceQuery(query: "retryWithBackoff", kinds: ["code"])).hits.map { $0.kind }, ["code"])
        XCTAssertEqual(try service.search(ServiceQuery(query: "", kinds: [])).hits.count, 0)          // browsing: no code
    }

    func testMoreLikeThisOverTheSocketFollowsTheSourceKind() throws {
        let repo = TestSupport.tempDir("repo")
        Self.write(Self.source, "src/retry.swift", in: repo)
        Self.write(Self.source.replacingOccurrences(of: "retryWithBackoff", with: "retryLater"), "src/later.swift", in: repo)
        try makeImage(width: 300, height: 100, text: nil, at: repo.appendingPathComponent("a.png"))
        let e = try Self.makeEngine()
        try Self.indexAll(e, repo)
        let path = TestSupport.shortDir().appendingPathComponent("s.sock").path
        let server = try ServiceSocket.start(path: path, service: LocalEngineService(engine: e))
        defer { server.stop() }
        let remote = RemoteEngineService(socketPath: path)
        let root = RealPath.of(repo.path)
        let fromCode = try remote.similar(path: root + "/src/retry.swift", limit: 10).hits
        XCTAssertEqual(fromCode.map { $0.kind }, ["code"])
        XCTAssertEqual(fromCode.flatMap { $0.paths }, [root + "/src/later.swift"])
        XCTAssertFalse(try remote.similar(path: root + "/a.png", limit: 10).hits.contains { $0.kind == "code" })
    }
}
