import XCTest
@testable import ThatOneCore

final class CLISocketTests: XCTestCase {
    struct Result { var code: Int32; var out: [String]; var err: [String] }

    /// A short home so the socket path stays under 104 bytes.
    func startApp(_ fake: FakeService) throws -> (home: URL, server: LineSocketServer) {
        let home = TestSupport.shortDir()
        let server = try ServiceSocket.start(path: home.appendingPathComponent("thatone.sock").path, service: fake)
        return (home, server)
    }

    func run(_ args: [String], home: URL) -> Result {
        var out: [String] = [], err: [String] = []
        let env = ["THATONE_HOME": home.path, "THATONE_KEY_HEX": String(repeating: "07", count: 32)]
        let code = CLI.run(args, environment: env, out: { out.append($0) }, err: { err.append($0) })
        return Result(code: code, out: out, err: err)
    }

    func testSearchGoesToTheRunningAppFirst() throws {
        let fake = FakeService()
        fake.searchResult = ServiceSearchResult(hits: [ServiceHit(paths: ["/from/the/app.png"], kind: "image", score: 0.5, modified: 1,
                                                                  anchors: [ServiceAnchor(modality: "text", anchor: "{}", text: "words", viaKeyword: true, viaVector: false)])],
                                                notice: nil)
        let (home, server) = try startApp(fake)
        defer { server.stop() }
        let r = run(["search", "pipe", "code", "--kind", "image", "--folder", "/p", "--limit", "5", "--json"], home: home)
        XCTAssertEqual(r.code, 0, r.err.joined())
        XCTAssertEqual(fake.queries, [ServiceQuery(query: "pipe code", kinds: ["image"], folder: "/p", since: nil, limit: 5)])
        let object = try JSONSerialization.jsonObject(with: Data(r.out.joined(separator: "\n").utf8)) as! [String: Any]
        let hit = (object["hits"] as! [[String: Any]])[0]
        XCTAssertEqual(hit["paths"] as? [String], ["/from/the/app.png"])
        XCTAssertEqual((hit["anchors"] as! [[String: Any]])[0]["via_keyword"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("index.db").path))   // no engine opened
    }

    func testStatusShowsTheAppState() throws {
        let fake = FakeService()
        fake.statusSequence = [ServiceStatus(state: "indexing", detail: "12 of 40", folders: ["/pics"], files: ["indexed": 12],
                                             segments: ["image": 12], queue: ServiceQueue(queued: 28, running: 0, failed: 0), failedFiles: [])]
        let (home, server) = try startApp(fake)
        defer { server.stop() }
        let r = run(["status"], home: home)
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(r.out.joined(separator: "\n").contains("app: indexing (12 of 40)"), "\(r.out)")
        XCTAssertTrue(r.out.joined(separator: "\n").contains("indexed 12"))
    }

    func testIndexFoldersAreHandedToTheAppAndFollowed() throws {
        CLI.statusPollInterval = 0.01
        defer { CLI.statusPollInterval = 1.0 }
        let fake = FakeService()
        fake.queuedOnIndex = 3
        let indexing = ServiceStatus(state: "indexing", detail: "1 of 3", folders: ["/pics"], files: [:], segments: [:],
                                     queue: ServiceQueue(queued: 2, running: 0, failed: 0), failedFiles: [])
        fake.statusSequence = [FakeService.idle, indexing, indexing, FakeService.idle]   // 1st: the "is an app running?" probe
        let (home, server) = try startApp(fake)
        defer { server.stop() }
        let folder = TestSupport.tempDir("pics")
        let r = run(["index", folder.path], home: home)
        XCTAssertEqual(r.code, 0, r.err.joined())
        XCTAssertEqual(fake.indexedFolders, [[folder.path]])
        XCTAssertTrue(r.out.contains { $0.contains("queued 3 file(s)") }, "\(r.out)")
        XCTAssertTrue(r.out.joined(separator: "\n").contains("indexed 2"), "\(r.out)")
    }

    func testIndexFilesFromIsRefusedWhileTheAppRuns() throws {
        let fake = FakeService()
        let (home, server) = try startApp(fake)
        defer { server.stop() }
        let list = home.appendingPathComponent("list.txt")
        try Data("/a.png\n".utf8).write(to: list)
        let r = run(["index", "--files-from", list.path], home: home)
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(r.err.joined().contains("quit"), "\(r.err)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("index.db").path))
    }

    func testForgetAndExcludeGoToTheApp() throws {
        let fake = FakeService()
        let (home, server) = try startApp(fake)
        defer { server.stop() }
        XCTAssertEqual(run(["forget", "/x/a.png"], home: home).code, 0)
        XCTAssertEqual(run(["exclude", "/x/private"], home: home).code, 0)
        XCTAssertEqual(fake.forgotten, ["/x/a.png"])
        XCTAssertEqual(fake.excluded, ["/x/private"])
    }

    func testUiForwardsToTheAppAndNeedsOne() throws {
        let fake = FakeService()
        let (home, server) = try startApp(fake)
        XCTAssertEqual(run(["ui", "show_panel"], home: home).code, 0)
        XCTAssertEqual(fake.uiActions, ["show_panel"])
        XCTAssertEqual(run(["ui"], home: home).code, 2)                     // usage error
        server.stop()
        let r = run(["ui", "show_panel"], home: home)
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(r.err.joined().contains("not running"), "\(r.err)")
    }

    func testAnAppThatFailsItsStatusProbeIsTreatedAsNotRunning() throws {
        let fake = FakeService()
        fake.failWith = "index is locked"
        let (home, server) = try startApp(fake)
        defer { server.stop() }
        let r = run(["ui", "show_panel"], home: home)
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(r.err.joined().contains("not running"), "\(r.err)")
    }

    func testRelativePathsAreResolvedBeforeTheyReachTheApp() throws {
        let fake = FakeService()
        let (home, server) = try startApp(fake)
        defer { server.stop() }
        let cwd = FileManager.default.currentDirectoryPath
        XCTAssertEqual(run(["exclude", "pics/a.png"], home: home).code, 0)
        XCTAssertEqual(run(["forget", "~/x.png"], home: home).code, 0)
        XCTAssertEqual(fake.excluded, [URL(fileURLWithPath: cwd).appendingPathComponent("pics/a.png").path])
        XCTAssertEqual(fake.forgotten, [NSHomeDirectory() + "/x.png"])
    }

    func testPhotosPathsAreNotMadeAbsoluteAndStatusShowsPhotos() throws {
        let fake = FakeService()
        var status = FakeService.idle
        status.photos = "on (limited)"
        fake.statusSequence = [status]
        let (home, server) = try startApp(fake)
        defer { server.stop() }
        XCTAssertEqual(run(["forget", "photos:A/L0/001/IMG 1.JPG"], home: home).code, 0)
        XCTAssertEqual(fake.forgotten, ["photos:A/L0/001/IMG 1.JPG"])
        XCTAssertTrue(run(["status"], home: home).out.contains("photos: on (limited)"))
    }
}
