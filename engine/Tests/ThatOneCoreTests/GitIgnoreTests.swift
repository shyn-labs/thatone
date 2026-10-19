import XCTest
@testable import ThatOneCore

final class GitIgnoreTests: XCTestCase {
    /// A folder holding the given `.gitignore` files (keys are their paths relative to the folder).
    func tree(_ files: [String: String]) -> URL {
        let root = TestSupport.tempDir("gi")
        for (relative, text) in files {
            let url = root.appendingPathComponent(relative)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(text.utf8).write(to: url)
        }
        return root
    }
    func ignored(_ files: [String: String], _ path: String, dir: Bool = false) -> Bool {
        GitIgnoreStack(root: tree(files).path).isIgnored(path, isDirectory: dir)
    }

    func testParseSkipsCommentsAndBlanksAndReadsEscapesFlagsAndAnchors() {
        let rules = GitIgnore.parse("# c\n\n*.log   \n\\#keep\n\\!bang\nfoo\\ \n!important.log\nbuild/\n/out\ndoc/frotz\n")
        XCTAssertEqual(rules.map { $0.pattern }, ["*.log", "#keep", "!bang", "foo\\ ", "important.log", "build", "out", "doc/frotz"])
        XCTAssertEqual(rules.map { $0.negated }, [false, false, false, false, true, false, false, false])
        XCTAssertEqual(rules.map { $0.directoryOnly }, [false, false, false, false, false, true, false, false])
        XCTAssertEqual(rules.map { $0.anchored }, [false, false, false, false, false, false, true, true])
        XCTAssertTrue(rules[3].matches("foo "))
    }

    func testCRLFGitignoreStillIgnores() {
        XCTAssertEqual(GitIgnore.parse("*.log\r\nbuild/\r\n").map { $0.pattern }, ["*.log", "build"])
        XCTAssertTrue(ignored([".gitignore": "*.log\r\nbuild/\r\n"], "a.log"))
        XCTAssertTrue(ignored([".gitignore": "*.log\r\nbuild/\r\n"], "build/x.ts"))
    }

    func testStarAndQuestionAndClasses() {
        let g = [".gitignore": "*.log\nfile?.ts\n[abc].ts\n[!abc].go\n[0-9].rs\n"]
        XCTAssertTrue(ignored(g, "a.log")); XCTAssertTrue(ignored(g, "deep/x/a.log")); XCTAssertFalse(ignored(g, "a.logx"))
        XCTAssertTrue(ignored(g, "file1.ts")); XCTAssertFalse(ignored(g, "file10.ts"))
        XCTAssertTrue(ignored(g, "b.ts")); XCTAssertFalse(ignored(g, "d.ts"))
        XCTAssertTrue(ignored(g, "d.go")); XCTAssertFalse(ignored(g, "a.go"))
        XCTAssertTrue(ignored(g, "5.rs")); XCTAssertFalse(ignored(g, "x.rs"))
    }

    func testAnchoringAndDirectoryOnly() {
        XCTAssertTrue(ignored([".gitignore": "/out\n"], "out/a.ts"))
        XCTAssertFalse(ignored([".gitignore": "/out\n"], "src/out/a.ts"))
        XCTAssertTrue(ignored([".gitignore": "build/\n"], "build/a.ts"))
        XCTAssertTrue(ignored([".gitignore": "build/\n"], "x/build/a.ts"))
        XCTAssertFalse(ignored([".gitignore": "build/\n"], "build", dir: false))         // a file named build
        XCTAssertTrue(ignored([".gitignore": "doc/frotz\n"], "doc/frotz/a.c"))
        XCTAssertFalse(ignored([".gitignore": "doc/frotz\n"], "a/doc/frotz/b.c"))
    }

    func testDoubleStar() {
        XCTAssertTrue(ignored([".gitignore": "**/gen\n"], "gen/a.ts"))
        XCTAssertTrue(ignored([".gitignore": "**/gen\n"], "x/y/gen/a.ts"))
        XCTAssertTrue(ignored([".gitignore": "a/**/b\n"], "a/b"))
        XCTAssertTrue(ignored([".gitignore": "a/**/b\n"], "a/x/y/b"))
        XCTAssertTrue(ignored([".gitignore": "logs/**\n"], "logs/a/b.txt"))
        XCTAssertFalse(ignored([".gitignore": "logs/**\n"], "logs", dir: true))
    }

    func testNegationReincludesAFileWhoseFolderIsNotIgnored() {
        let g = [".gitignore": "*.ts\n!keep.ts\n"]
        XCTAssertTrue(ignored(g, "a.ts"))
        XCTAssertFalse(ignored(g, "keep.ts"))
        XCTAssertFalse(ignored(g, "src/keep.ts"))
    }

    func testNegationCannotReincludeInsideAnIgnoredFolder() {
        XCTAssertTrue(ignored([".gitignore": "build/\n!build/keep.ts\n"], "build/keep.ts"))
        XCTAssertTrue(ignored([".gitignore": "gen/\n", "gen/.gitignore": "!*\n"], "gen/a.ts"))
        XCTAssertTrue(ignored([".gitignore": "cache\n!cache/keep.ts\n"], "cache/keep.ts"))
    }

    func testDeeperGitignoreWinsAndIsRelativeToItsFolder() {
        let g = [".gitignore": "*.ts\n", "sub/.gitignore": "!*.ts\n/local.py\n"]
        XCTAssertTrue(ignored(g, "a.ts"))
        XCTAssertFalse(ignored(g, "sub/a.ts"))
        XCTAssertFalse(ignored(g, "sub/deep/a.ts"))
        XCTAssertTrue(ignored(g, "sub/local.py"))
        XCTAssertFalse(ignored(g, "sub/x/local.py"))
        XCTAssertFalse(ignored(g, "local.py"))
    }

    func testEscapedHashAndMalformedLinesNeverCrash() {
        XCTAssertTrue(ignored([".gitignore": "\\#notes.ts\n"], "#notes.ts"))
        XCTAssertFalse(ignored([".gitignore": "[abc\n"], "[abc"))                  // unclosed class: git matches nothing
        XCTAssertFalse(ignored([".gitignore": "[abc\n"], "a"))
        XCTAssertFalse(ignored([".gitignore": "/\n!\n\\\n"], "a.ts"))
    }

    func testAnUnreadableGitignoreMeansNoRules() {
        let root = TestSupport.tempDir("gi")
        try! FileManager.default.createDirectory(at: root.appendingPathComponent(".gitignore"), withIntermediateDirectories: true)
        XCTAssertFalse(GitIgnoreStack(root: root.path).isIgnored("a.ts", isDirectory: false))
    }

    func testTheLoaderSeesAnEdit() throws {
        let root = tree([".gitignore": "*.ts\n"])
        let loader = GitIgnoreLoader()
        XCTAssertTrue(GitIgnoreStack(root: root.path, loader: loader).isIgnored("a.ts", isDirectory: false))
        let file = root.appendingPathComponent(".gitignore")
        try Data("*.py\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        XCTAssertFalse(GitIgnoreStack(root: root.path, loader: loader).isIgnored("a.ts", isDirectory: false))
        XCTAssertTrue(GitIgnoreStack(root: root.path, loader: loader).isIgnored("a.py", isDirectory: false))
    }

    func testAHugeGitignoreIsCappedAndStaysFast() throws {
        var lines = ["early.ts"]
        for i in 0..<200_000 {                                   // short rules, a quarter of them anchored with a `**`
            let name = String(i, radix: 36)
            lines.append(i % 4 == 0 ? "d\(name)/**/q" : "x\(name)")
        }
        lines.append("src/")                                       // past both caps: never read
        let text = lines.joined(separator: "\n") + "\n"
        XCTAssertGreaterThan(text.utf8.count, 1_000_000)
        let root = tree([".gitignore": text])
        var logged: [String] = []
        let loader = GitIgnoreLoader(log: { logged.append($0) })
        XCTAssertEqual(loader.rules(inDirectory: root.path).count, GitIgnoreLoader.maxRules)
        XCTAssertEqual(GitIgnoreLoader.maxRules, 10_000); XCTAssertEqual(GitIgnoreLoader.maxBytes, 256 * 1024)
        let started = Date()
        let stack = GitIgnoreStack(root: root.path, loader: loader)
        var ignored = 0
        for i in 0..<200 where stack.isIgnored("src/sub\(i % 5)/file\(i).ts", isDirectory: false) { ignored += 1 }
        let seconds = Date().timeIntervalSince(started)
        XCTAssertLessThan(seconds, 1.0, "took \(seconds) s")
        XCTAssertEqual(ignored, 0)                                   // the trailing `src/` was beyond the cap
        XCTAssertTrue(stack.isIgnored("early.ts", isDirectory: false))
        XCTAssertTrue(stack.isIgnored("x1/a.ts", isDirectory: false))
        _ = GitIgnoreStack(root: root.path, loader: loader).isIgnored("a.ts", isDirectory: false)
        XCTAssertEqual(logged.count, 1, "\(logged)")                // once per file
        XCTAssertTrue(logged.first?.contains(root.path + "/.gitignore") == true)
        XCTAssertFalse(logged.joined().contains("early") || logged.joined().contains("x1"))   // never the file's contents
    }

    func testTenThousandDoubleStarRulesJudgeTwoHundredFilesInUnderASecond() {
        let text = (0..<GitIgnoreLoader.maxRules).map { "dir\($0)/**/*.tmp\($0)" }.joined(separator: "\n") + "\n"
        XCTAssertLessThan(text.utf8.count, GitIgnoreLoader.maxBytes)       // within both caps: every rule is kept
        let stack = GitIgnoreStack(root: tree([".gitignore": text]).path)
        let started = Date()
        var ignored = 0
        for i in 0..<200 where stack.isIgnored("src/sub\(i % 5)/file\(i).ts", isDirectory: false) { ignored += 1 }
        let seconds = Date().timeIntervalSince(started)
        XCTAssertLessThan(seconds, 1.0, "took \(seconds) s")
        XCTAssertEqual(ignored, 0)
        XCTAssertTrue(stack.isIgnored("dir9999/a/b/x.tmp9999", isDirectory: false))
        XCTAssertFalse(stack.isIgnored("dir9999/a/b/x.tmp9998", isDirectory: false))
    }

    func testBytesPastTheReadCapAreNotRules() {
        let filler = String(repeating: "# a long comment line that takes up space in the file\n", count: 6_000)   // ~330 KB
        let root = tree([".gitignore": "first.ts\n" + filler + "late.ts\n"])
        var logged: [String] = []
        let stack = GitIgnoreStack(root: root.path, loader: GitIgnoreLoader(log: { logged.append($0) }))
        XCTAssertTrue(stack.isIgnored("first.ts", isDirectory: false))
        XCTAssertFalse(stack.isIgnored("late.ts", isDirectory: false))
        XCTAssertEqual(logged.count, 1)
        XCTAssertFalse(ignored([".gitignore": "first.ts\n" + filler + "late.ts\n"], "late.ts"))
    }

    /// A hostile `.gitignore` from a cloned repo must not stall the indexer: each pattern against a ~200-segment,
    /// ~4,000-character path that does not match finishes at once (a backtracking regex would take exponential time).
    func testAdversarialPatternsFinishFastAndAreCorrect() {
        let deep = (0..<200).map { _ in "aaaaaaaaaaaaaaaaaaa" }.joined(separator: "/")          // 200 segments, 3,999 chars
        let flat = String(repeating: "a", count: 4000)
        let cases: [(pattern: String, path: String)] = [
            ("**/**/**/**/**/**/x", deep),
            ("a*a*a*a*a*a*a*a*b", flat),
            ("*/*/*/*/*/*/*/z", deep),
        ]
        for c in cases {
            let stack = GitIgnoreStack(root: tree([".gitignore": c.pattern + "\n"]).path)
            let start = Date()
            let verdict = stack.isIgnored(c.path, isDirectory: false)
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, c.pattern)
            XCTAssertFalse(verdict, c.pattern)
        }
        XCTAssertTrue(ignored([".gitignore": "**/**/**/x\n"], "a/b/c/d/x"))
        XCTAssertTrue(ignored([".gitignore": "a*a*b\n"], "aXaXb"))
        XCTAssertTrue(ignored([".gitignore": "*/*/z\n"], "p/q/z"))
    }
}
