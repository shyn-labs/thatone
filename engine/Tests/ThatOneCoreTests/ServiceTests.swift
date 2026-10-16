import CoreGraphics
import XCTest
@testable import ThatOneCore

/// Records every call and answers with canned data. Safe to call from the socket's worker threads.
final class FakeService: EngineService {
    private let lock = NSLock()
    private(set) var queries: [ServiceQuery] = []
    private(set) var similarPaths: [String] = []
    private(set) var indexedFolders: [[String]] = []
    private(set) var forgotten: [String] = []
    private(set) var excluded: [String] = []
    private(set) var uiActions: [String] = []
    var statusSequence: [ServiceStatus] = [FakeService.idle]
    var searchResult = ServiceSearchResult(hits: [], notice: nil)
    var failWith: String?
    var queuedOnIndex = 3
    static let idle = ServiceStatus(state: "idle", detail: "", folders: ["/pics"], files: ["indexed": 2], segments: ["image": 2],
                                    queue: ServiceQueue(queued: 0, running: 0, failed: 0), failedFiles: [])

    private func record(_ body: () -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        if let failWith { throw ServiceError.remote(failWith) }
        body()
    }
    func search(_ q: ServiceQuery) throws -> ServiceSearchResult { try record { queries.append(q) }; return searchResult }
    func similar(path: String, limit: Int) throws -> ServiceSearchResult { try record { similarPaths.append(path) }; return searchResult }
    func status() throws -> ServiceStatus {
        lock.lock(); defer { lock.unlock() }
        if let failWith { throw ServiceError.remote(failWith) }
        return statusSequence.count > 1 ? statusSequence.removeFirst() : statusSequence[0]
    }
    func index(folders: [String]) throws -> Int { try record { indexedFolders.append(folders) }; return queuedOnIndex }
    func forget(path: String) throws { try record { forgotten.append(path) } }
    func exclude(path: String) throws { try record { excluded.append(path) } }
    func ui(action: String) throws { try record { uiActions.append(action) } }
}

final class ServiceTests: XCTestCase {
    func call(_ json: String, _ service: EngineService) throws -> [String: Any] {
        let reply = ServiceDispatcher.handle(Data(json.utf8), service: service)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
    }

    func testDispatcherRoutesEveryOperation() throws {
        let fake = FakeService()
        fake.searchResult = ServiceSearchResult(hits: [ServiceHit(paths: ["/a.png"], kind: "image", score: 0.5, modified: 7, anchors: [])], notice: "n")
        XCTAssertEqual(try call(#"{"v":1,"op":"ping"}"#, fake)["ok"] as? Bool, true)
        let search = try call(#"{"v":1,"op":"search","query":{"query":"pipe","kinds":["image"],"folder":"/p","since":5,"limit":7}}"#, fake)
        XCTAssertEqual(fake.queries, [ServiceQuery(query: "pipe", kinds: ["image"], folder: "/p", since: 5, limit: 7)])
        XCTAssertEqual(((search["search"] as? [String: Any])?["hits"] as? [[String: Any]])?.first?["paths"] as? [String], ["/a.png"])
        _ = try call(#"{"v":1,"op":"similar","path":"/a.png","limit":9}"#, fake)
        XCTAssertEqual(fake.similarPaths, ["/a.png"])
        XCTAssertEqual((try call(#"{"v":1,"op":"status"}"#, fake)["status"] as? [String: Any])?["state"] as? String, "idle")
        XCTAssertEqual(try call(#"{"v":1,"op":"index","folders":["/x","/y"]}"#, fake)["queued"] as? Int, 3)
        XCTAssertEqual(fake.indexedFolders, [["/x", "/y"]])
        _ = try call(#"{"v":1,"op":"forget","path":"/f"}"#, fake)
        _ = try call(#"{"v":1,"op":"exclude","path":"/e"}"#, fake)
        _ = try call(#"{"v":1,"op":"ui","action":"show_panel"}"#, fake)
        XCTAssertEqual(fake.forgotten, ["/f"]); XCTAssertEqual(fake.excluded, ["/e"]); XCTAssertEqual(fake.uiActions, ["show_panel"])
    }

    func testUnknownOperationAndWrongVersionAreRejected() throws {
        let fake = FakeService()
        XCTAssertEqual(try call(#"{"v":1,"op":"format_disk"}"#, fake)["ok"] as? Bool, false)
        XCTAssertEqual(try call(#"{"v":2,"op":"status"}"#, fake)["ok"] as? Bool, false)
        XCTAssertEqual(try call("not json at all", fake)["ok"] as? Bool, false)
        XCTAssertEqual(try call(#"{"v":1,"op":"search"}"#, fake)["ok"] as? Bool, false)           // missing query
        XCTAssertEqual(try call(#"{"v":1,"op":"forget"}"#, fake)["ok"] as? Bool, false)           // missing path
        XCTAssertTrue(fake.queries.isEmpty && fake.forgotten.isEmpty)
    }

    func testServiceErrorsBecomeErrorReplies() throws {
        let fake = FakeService()
        fake.failWith = "model exploded"
        let reply = try call(#"{"v":1,"op":"status"}"#, fake)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "model exploded")
    }

    func testRemoteServiceTalksToARealServer() throws {
        let fake = FakeService()
        fake.searchResult = ServiceSearchResult(hits: [ServiceHit(paths: ["/ಕನ್ನಡ/it's \"x\".png"], kind: "image", score: 1, modified: 9,
                                                                  anchors: [ServiceAnchor(modality: "text", anchor: "{}", text: "ಬೆಂಗಳೂರು", viaKeyword: true, viaVector: false)])],
                                                notice: nil)
        let path = TestSupport.shortDir().appendingPathComponent("s.sock").path
        let server = try ServiceSocket.start(path: path, service: fake)
        defer { server.stop() }
        let remote = try XCTUnwrap(RemoteEngineService.ifRunning(socketPath: path))
        let result = try remote.search(ServiceQuery(query: "x"))
        XCTAssertEqual(result, fake.searchResult)                                     // Unicode and quotes survive the wire
        XCTAssertEqual(try remote.index(folders: ["/a"]), 3)
        try remote.ui(action: "quit")
        XCTAssertEqual(fake.uiActions, ["quit"])
        fake.failWith = "nope"
        XCTAssertThrowsError(try remote.forget(path: "/x")) { XCTAssertEqual($0 as? ServiceError, .remote("nope")) }
    }

    func testIfRunningIsNilWithoutAServer() {
        XCTAssertNil(RemoteEngineService.ifRunning(socketPath: TestSupport.shortDir().appendingPathComponent("none.sock").path))
        let r = RemoteEngineService(socketPath: TestSupport.shortDir().appendingPathComponent("none.sock").path)
        XCTAssertThrowsError(try r.status()) { XCTAssertEqual($0 as? ServiceError, .notRunning) }
    }

    func testBigStatusSurvivesTheWire() throws {
        let fake = FakeService()
        let failures = (0..<4000).map { ServiceFailedFile(path: "/files/number \($0)/ಕನ್ನಡ.png", note: String(repeating: "why ", count: 12)) }
        fake.statusSequence = [ServiceStatus(state: "indexing", detail: "12 of 5000", folders: ["/pics"], files: ["failed": 4000],
                                             segments: [:], queue: ServiceQueue(queued: 1, running: 2, failed: 3), failedFiles: failures)]
        let path = TestSupport.shortDir().appendingPathComponent("s.sock").path
        let server = try ServiceSocket.start(path: path, service: fake)
        defer { server.stop() }
        let status = try RemoteEngineService(socketPath: path).status()
        XCTAssertEqual(status.failedFiles.count, 4000)
        XCTAssertEqual(status, fake.statusSequence[0])
    }

    func testLocalServiceOverARealEngine() throws {
        let folder = TestSupport.tempDir("pics")
        try makeImage(width: 300, height: 100, text: nil, at: folder.appendingPathComponent("a.png"))
        try makeImage(width: 310, height: 100, text: nil, at: folder.appendingPathComponent("b.png"))
        let engine = try Engine(paths: Paths(home: TestSupport.tempDir("home")), config: Config(),
                                keyProvider: StaticKeyProvider(TestSupport.key), embedder: FakeEmbedder(),
                                ocr: { $0.width == 300 ? "invoice 4471" : "holiday photo" })
        let path = TestSupport.shortDir().appendingPathComponent("s.sock").path
        let server = try ServiceSocket.start(path: path, service: LocalEngineService(engine: engine))
        defer { server.stop() }
        let remote = RemoteEngineService(socketPath: path)
        XCTAssertEqual(try remote.index(folders: [folder.path]), 2)
        try engine.runIndexing()
        let a = RealPath.of(folder.path) + "/a.png", b = RealPath.of(folder.path) + "/b.png"
        XCTAssertEqual(try remote.search(ServiceQuery(query: "invoice")).hits.first?.paths, [a])
        XCTAssertEqual(try remote.search(ServiceQuery(query: "")).hits.count, 2)                   // empty query browses
        XCTAssertEqual(try remote.search(ServiceQuery(query: "", kinds: ["pdf"])).hits.count, 0)
        XCTAssertEqual(try remote.similar(path: a, limit: 5).hits.flatMap { $0.paths }, [b])
        XCTAssertEqual(try remote.status().files, ["indexed": 2])
        XCTAssertThrowsError(try remote.ui(action: "show_panel")) { XCTAssertEqual($0 as? ServiceError, .remote("this process has no user interface")) }
        try remote.forget(path: a)
        XCTAssertEqual(try remote.status().files, ["indexed": 1])
        try remote.exclude(path: b)
        XCTAssertEqual(try remote.status().files, [:])
    }

    func testLimitsAreClampedAndRelativePathsRejected() throws {
        let fake = FakeService()
        _ = try call(#"{"v":1,"op":"search","query":{"query":"x","kinds":[],"limit":-1}}"#, fake)
        _ = try call(#"{"v":1,"op":"search","query":{"query":"x","kinds":[],"limit":9999999}}"#, fake)
        _ = try call(#"{"v":1,"op":"similar","path":"/a.png","limit":-4}"#, fake)
        XCTAssertEqual(fake.queries.map { $0.limit }, [1, 500])
        for json in [#"{"v":1,"op":"forget","path":"rel.png"}"#, #"{"v":1,"op":"exclude","path":"../x"}"#,
                     #"{"v":1,"op":"similar","path":"rel.png"}"#, #"{"v":1,"op":"index","folders":["pics"]}"#] {
            XCTAssertEqual(try call(json, fake)["ok"] as? Bool, false, json)
        }
        XCTAssertTrue(fake.forgotten.isEmpty && fake.excluded.isEmpty && fake.indexedFolders.isEmpty)
    }

    func testStatusFromAnOlderAppWithoutPhotosStillDecodes() throws {
        let old = #"{"state":"idle","detail":"","folders":[],"files":{},"segments":{},"queue":{"queued":0,"running":0,"failed":0},"failedFiles":[]}"#
        XCTAssertEqual(try JSONDecoder().decode(ServiceStatus.self, from: Data(old.utf8)).photos, "off")
    }

    func testIndexStillNeedsRealFolders() throws {
        let fake = FakeService()
        XCTAssertEqual(try call(#"{"v":1,"op":"index","folders":["photos:A/L0/001/x.jpg"]}"#, fake)["ok"] as? Bool, false)
    }
}
