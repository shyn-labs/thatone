import XCTest
@testable import ThatOneCore

final class CLITests: XCTestCase {
    struct Result { var code: Int32; var out: [String]; var err: [String] }

    func run(_ args: [String], home: URL, embedder: Embedder? = nil) -> Result {
        var out: [String] = [], err: [String] = []
        let env = ["THATONE_HOME": home.path, "THATONE_KEY_HEX": String(repeating: "07", count: 32)]
        let code = CLI.run(args, environment: env, embedder: embedder, out: { out.append($0) }, err: { err.append($0) })
        return Result(code: code, out: out, err: err)
    }

    func testUsageErrorsReturnTwoAndOpenNoDatabase() {
        let home = TestSupport.tempDir("home")
        for args in [[], ["bogus"], ["search"], ["index"], ["search", "x", "--nope"], ["search", "x", "--limit"],
                     ["forget"], ["index", "--files-from"]] as [[String]] {
            let r = run(args, home: home)
            XCTAssertEqual(r.code, 2, "\(args)")
            XCTAssertTrue(r.err.joined().contains("usage:"), "\(args)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("index.db").path))
    }

    func testHelpPrintsUsage() {
        let r = run(["help"], home: TestSupport.tempDir())
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(r.out.joined().contains("thatone index <folder>"))
    }

    func testCLIIndexAndSearchEndToEnd() throws {
        let home = TestSupport.tempDir("home")
        let folder = TestSupport.tempDir("ಕನ್ನಡ ಫೋಲ್ಡರ್")
        let shot = folder.appendingPathComponent("it's \"invoice\" 100%.png")
        try makeImage(width: 1200, height: 300, text: "INVOICE 4471", at: shot)
        let fake = FakeEmbedder()

        let indexed = run(["index", folder.path], home: home, embedder: fake)
        XCTAssertEqual(indexed.code, 0, indexed.err.joined())
        XCTAssertTrue(indexed.out.contains { $0.contains("queued 1 file(s)") })
        XCTAssertTrue(indexed.out.contains { $0.contains("indexed 1,") })

        let found = run(["search", "4471", "--json"], home: home, embedder: fake)
        XCTAssertEqual(found.code, 0)
        let json = try JSONSerialization.jsonObject(with: Data(found.out.joined(separator: "\n").utf8)) as! [String: Any]
        let hits = json["hits"] as! [[String: Any]]
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0]["paths"] as! [String], [RealPath.of(shot.path)])
        XCTAssertEqual(hits[0]["kind"] as? String, "image")
        XCTAssertTrue(json["notice"] is NSNull)

        let human = run(["search", "invoice"], home: home, embedder: fake)
        XCTAssertTrue(human.out.joined(separator: "\n").contains(RealPath.of(shot.path)))

        let status = run(["status", "--json"], home: home, embedder: fake)
        let report = try JSONSerialization.jsonObject(with: Data(status.out.joined(separator: "\n").utf8)) as! [String: Any]
        XCTAssertEqual((report["files"] as! [String: Int])["indexed"], 1)
        XCTAssertEqual((report["folders"] as! [String]), [RealPath.of(folder.path)])

        XCTAssertEqual(run(["forget", shot.path], home: home, embedder: fake).code, 0)
        let gone = run(["search", "4471", "--json"], home: home, embedder: fake)
        let after = try JSONSerialization.jsonObject(with: Data(gone.out.joined(separator: "\n").utf8)) as! [String: Any]
        XCTAssertEqual((after["hits"] as! [Any]).count, 0)
    }

    func testIndexFilesFromListsExactFiles() throws {
        let home = TestSupport.tempDir("home")
        let dir = TestSupport.tempDir("pics")
        let a = dir.appendingPathComponent("a.png"), b = dir.appendingPathComponent("b.png")
        try makeImage(width: 300, height: 100, text: nil, at: a)
        try makeImage(width: 310, height: 100, text: nil, at: b)
        let list = dir.appendingPathComponent("list.txt")
        try Data((a.path + "\n\n/missing/file.png\n").utf8).write(to: list)
        let r = run(["index", "--files-from", list.path], home: home, embedder: FakeEmbedder())
        XCTAssertEqual(r.code, 0, r.err.joined())
        XCTAssertTrue(r.out.contains { $0.contains("queued 1 file(s)") })
        let status = run(["status", "--json"], home: home, embedder: FakeEmbedder())
        let report = try JSONSerialization.jsonObject(with: Data(status.out.joined(separator: "\n").utf8)) as! [String: Any]
        XCTAssertEqual((report["folders"] as! [String]), [])      // explicit files do not add a watched folder
        XCTAssertEqual((report["files"] as! [String: Int])["indexed"], 1)
    }

    func testRuntimeErrorsReturnOne() {
        let home = TestSupport.tempDir("home")
        let r = run(["index", "/definitely/not/a/folder"], home: home, embedder: FakeEmbedder())
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(r.err.joined().contains("not a folder"))
    }

    func testPrintableEscapesControlAndBidiCharacters() {
        XCTAssertEqual(CLI.printable("a\u{1B}[2Jb"), "a\\u{1B}[2Jb")
        XCTAssertEqual(CLI.printable("tab\there"), "tab\\u{9}here")
        XCTAssertEqual(CLI.printable("x\u{9B}31my"), "x\\u{9B}31my")                 // C1 control (8-bit CSI)
        XCTAssertEqual(CLI.printable("evil\u{202E}gnp.exe"), "evil\\u{202E}gnp.exe")  // right-to-left override
        XCTAssertEqual(CLI.printable("line1\nline2", keeping: [0x0A]), "line1\nline2")
        XCTAssertEqual(CLI.printable("ಕನ್ನಡ ಫೋಲ್ಡರ್ it's \"x\""), "ಕನ್ನಡ ಫೋಲ್ಡರ್ it's \"x\"")   // ordinary text untouched
    }

    func testTerminalControlSequencesInFileNamesNeverReachHumanOutput() throws {
        let home = TestSupport.tempDir("home")
        let folder = TestSupport.tempDir("pics")
        let name = "evil\u{1B}[2Jname.png"
        try makeImage(width: 300, height: 100, text: nil, at: folder.appendingPathComponent(name))
        let fake = FakeEmbedder()
        XCTAssertEqual(run(["index", folder.path], home: home, embedder: fake).code, 0)

        func assertNoEscape(_ args: [String], file: StaticString = #filePath, line: UInt = #line) {
            let r = run(args, home: home, embedder: fake)
            let all = (r.out + r.err).joined(separator: "\n")
            XCTAssertFalse(all.unicodeScalars.contains { $0.value == 0x1B }, "\(args): \(all.debugDescription)", file: file, line: line)
        }
        assertNoEscape(["search", "anything"])
        assertNoEscape(["search", "anything", "--json"])        // JSON escapes it as \u001b, never a raw byte
        assertNoEscape(["status"])
        let shown = run(["search", "anything"], home: home, embedder: fake).out.joined(separator: "\n")
        XCTAssertTrue(shown.contains("evil\\u{1B}[2Jname.png"), shown)   // visible, harmless escape
        assertNoEscape(["forget", folder.path + "/" + name])    // last: it removes the file from the index
    }

    func testJSONOutputStaysValidWithBidiAndC1CharactersInFileNames() throws {
        let home = TestSupport.tempDir("home")
        let folder = TestSupport.tempDir("pics")
        let name = "evil\u{202E}gnp.exe\u{9B}x.png"
        try makeImage(width: 300, height: 100, text: nil, at: folder.appendingPathComponent(name))
        let fake = FakeEmbedder()
        XCTAssertEqual(run(["index", folder.path], home: home, embedder: fake).code, 0)
        let text = run(["search", "anything", "--json"], home: home, embedder: fake).out.joined(separator: "\n")
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]     // must still parse
        let paths = (object["hits"] as! [[String: Any]])[0]["paths"] as! [String]
        XCTAssertEqual(paths, [RealPath.of(folder.path + "/" + name)])                               // and round-trip the name
        XCTAssertFalse(text.unicodeScalars.contains { (0x80...0x9F).contains($0.value) || $0.value == 0x202E })
    }

    func testIndexReportsAPausedRun() throws {
        let home = TestSupport.tempDir("home")
        let folder = TestSupport.tempDir("pics")
        try makeImage(width: 300, height: 100, text: nil, at: folder.appendingPathComponent("a.png"))
        let fake = FakeEmbedder()
        fake.failure = SidecarEmbedder.Failure.unavailable("offline")      // info() still answers, embed() does not
        let r = run(["index", folder.path], home: home, embedder: fake)
        XCTAssertEqual(r.code, 0, r.err.joined())
        XCTAssertTrue(r.out.contains { $0.contains("paused: embedding unavailable: offline") }, "\(r.out)")
        XCTAssertTrue(r.out.contains { $0.contains("failed 0") })
    }

    func testCLISearchShowsCodeOnlyWithKindCode() throws {
        let home = TestSupport.tempDir("home")
        let repo = TestSupport.tempDir("repo")
        try Config(kinds: ["code"]).save(to: Paths(home: home).config)
        CodeIndexingTests.write(CodeIndexingTests.source, "src/retry.swift", in: repo)
        let fake = FakeEmbedder()
        XCTAssertEqual(run(["index", repo.path], home: home, embedder: fake).code, 0)
        func hits(_ args: [String]) throws -> [[String: Any]] {
            let r = run(["search", "retryWithBackoff", "--json"] + args, home: home, embedder: fake)
            XCTAssertEqual(r.code, 0)
            return (try JSONSerialization.jsonObject(with: Data(r.out.joined(separator: "\n").utf8)) as! [String: Any])["hits"] as! [[String: Any]]
        }
        XCTAssertEqual(try hits([]).count, 0)
        let code = try hits(["--kind", "code"])
        XCTAssertEqual(code.count, 1)
        XCTAssertEqual(code[0]["kind"] as? String, "code")
        XCTAssertTrue((code[0]["anchors"] as! [[String: Any]]).contains { ($0["anchor"] as? String)?.contains("\"line0\":3") == true })
    }
}
