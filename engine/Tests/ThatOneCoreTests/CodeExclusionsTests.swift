import XCTest
@testable import ThatOneCore

final class CodeExclusionsTests: XCTestCase {
    typealias T = CodeIndexingTests
    func codePaths(_ e: Engine) throws -> [String] {
        try e.store.filePaths(ofKind: "code").filter { try e.store.fileRecord(path: $0)?.status == "indexed" }
    }
    func other(_ name: String) -> String { T.source.replacingOccurrences(of: "retryWithBackoff", with: name) }   // distinct bytes

    func testReasonsForBuildFoldersAndGitignore() {
        let repo = TestSupport.tempDir("repo")
        T.write("tmp/\n", ".gitignore", in: repo)
        let real = RealPath.of(repo.path)
        let rules = CodeExclusions()
        XCTAssertEqual(rules.reason(path: real + "/dist/a.js", root: real), "build folder")
        XCTAssertEqual(rules.reason(path: real + "/src/target/a.rs", root: real), "build folder")
        XCTAssertNil(rules.reason(path: real + "/src/build.ts", root: real))                     // a file named build
        XCTAssertEqual(rules.reason(path: real + "/tmp/a.ts", root: real), "ignored by .gitignore")
        XCTAssertNil(rules.reason(path: real + "/src/a.ts", root: real))
    }

    func testWithoutAWatchedFolderTheEnclosingWorkTreeIsTheRoot() throws {
        let repo = TestSupport.tempDir("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let real = RealPath.of(repo.path)
        XCTAssertEqual(CodeExclusions.effectiveRoot(path: real + "/a/b/c.ts", watchedRoot: nil), real)
        let loose = RealPath.of(TestSupport.tempDir("loose").path)
        XCTAssertEqual(CodeExclusions.effectiveRoot(path: loose + "/x/c.ts", watchedRoot: nil), loose + "/x")
        XCTAssertEqual(CodeExclusions.effectiveRoot(path: "/a/b.ts", watchedRoot: "/w/"), "/w")
    }

    func testBuildFoldersAndGitignoredCodeAreSkippedButOtherKindsInsideThemAreNot() throws {
        let repo = TestSupport.tempDir("repo")
        T.write("generated/\n*.gen.ts\n", ".gitignore", in: repo)
        for (n, rel) in ["src/a.ts", "src/b.gen.ts", "generated/c.ts", "dist/d.js", "build/e.swift", "node_modules/x/f.js",
                         "src/out/g.ts", "src/vendor/h.go"].enumerated() { T.write(other("f\(n)"), rel, in: repo) }
        try makeImage(width: 300, height: 100, text: nil, at: repo.appendingPathComponent("generated/shot.png"))
        try makeImage(width: 310, height: 100, text: nil, at: repo.appendingPathComponent("build/icon.png"))
        let e = try T.makeEngine()
        try T.indexAll(e, repo)
        XCTAssertEqual(try codePaths(e), [RealPath.of(repo.path) + "/src/a.ts"])
        XCTAssertEqual(try e.status().counts.filesByKind, ["code": 1, "image": 2])
    }

    func testNegationCannotReincludeAFileInsideAnIgnoredFolderEndToEnd() throws {
        let repo = TestSupport.tempDir("repo")
        T.write("cache/\n!cache/keep.ts\n*.tmp.ts\n!wanted.tmp.ts\n", ".gitignore", in: repo)
        for (n, rel) in ["cache/keep.ts", "a.tmp.ts", "wanted.tmp.ts", "src/a.ts"].enumerated() { T.write(other("g\(n)"), rel, in: repo) }
        let e = try T.makeEngine()
        try T.indexAll(e, repo)
        let real = RealPath.of(repo.path)
        XCTAssertEqual(try codePaths(e), [real + "/src/a.ts", real + "/wanted.tmp.ts"])
    }

    func testEditingGitignorePurgesNewlyIgnoredCodeAndDeletingItBringsItBack() throws {
        let repo = TestSupport.tempDir("repo")
        T.write(other("alpha"), "src/a.ts", in: repo)
        T.write(other("beta"), "tmp/b.ts", in: repo)
        let e = try T.makeEngine()
        try T.indexAll(e, repo)
        let real = RealPath.of(repo.path)
        XCTAssertEqual(try codePaths(e), [real + "/src/a.ts", real + "/tmp/b.ts"])
        T.write("tmp/\n", ".gitignore", in: repo)
        try e.handle([FileWatcher.Change(path: real + "/.gitignore", removedOrRenamed: false)])
        try e.runIndexing()
        XCTAssertEqual(try codePaths(e), [real + "/src/a.ts"])
        XCTAssertNil(try e.store.fileRecord(path: real + "/tmp/b.ts"))
        try FileManager.default.removeItem(atPath: real + "/.gitignore")
        try e.handle([FileWatcher.Change(path: real + "/.gitignore", removedOrRenamed: true)])
        try e.runIndexing()
        XCTAssertEqual(try codePaths(e), [real + "/src/a.ts", real + "/tmp/b.ts"])
    }

    func testABatchOfGitignoreEditsRescansEachFolderOnceAndNeverInsideAnotherRescan() throws {
        let repo = TestSupport.tempDir("repo")
        for rel in ["pkg/.gitignore", "pkg2/.gitignore", ".gitignore", "pkg/deep/.gitignore"] { T.write("gen/\n", rel, in: repo) }
        let real = RealPath.of(repo.path)
        let store = try Store.open(path: TestSupport.tempDir().appendingPathComponent("c.db").path, key: TestSupport.key, dim: 4)
        let crawler = Crawler(store: store, queue: JobQueue(store: store), enabledKinds: { Kinds.defaultEnabled.union(["code"]) })
        var rescans: [String] = []
        crawler.onRescan = { rescans.append($0) }
        func change(_ rel: String) -> FileWatcher.Change { FileWatcher.Change(path: real + "/" + rel, removedOrRenamed: false) }
        try crawler.handle([change("pkg/.gitignore"), change(".gitignore"), change("pkg/deep/.gitignore")], roots: [real])
        XCTAssertEqual(rescans, [real])                                   // the root once; pkg/ and pkg/deep/ are inside it
        rescans = []
        try crawler.handle([change("pkg/deep/.gitignore"), change("pkg2/.gitignore"), change("pkg/.gitignore"),
                            change("pkg/.gitignore")], roots: [real])
        XCTAssertEqual(rescans.sorted(), [real + "/pkg", real + "/pkg2"])   // pkg2 only shares a name prefix with pkg
    }

    func testANestedGitignoreEditRescansOnlyItsFolder() throws {
        let repo = TestSupport.tempDir("repo")
        T.write(other("alpha"), "pkg/src/a.ts", in: repo)
        T.write(other("beta"), "pkg/gen/b.ts", in: repo)
        T.write(other("gamma"), "pkg2/gen/c.ts", in: repo)       // a sibling whose name starts with "pkg"
        T.write(other("delta"), "top/d.ts", in: repo)
        let e = try T.makeEngine()
        try T.indexAll(e, repo)
        let real = RealPath.of(repo.path)
        // Changed on disk without an event: a rescan of anything wider than pkg/ would queue them.
        T.write(other("epsilon"), "top/new.ts", in: repo)
        T.write(other("zeta"), "pkg2/new.ts", in: repo)
        T.write("gen/\n", "pkg/.gitignore", in: repo)
        try e.handle([FileWatcher.Change(path: real + "/pkg/.gitignore", removedOrRenamed: false)])
        // Nothing outside pkg/ is queued: only the purge job for the code pkg/.gitignore now ignores.
        XCTAssertEqual(try e.queue.claim(limit: 100), [real + "/pkg/gen/b.ts"])
        try e.queue.recoverRunning()
        try e.runIndexing()
        XCTAssertEqual(try codePaths(e), [real + "/pkg/src/a.ts", real + "/pkg2/gen/c.ts", real + "/top/d.ts"])
    }

    func testAlreadyIndexedCodeThatBecomesIgnoredIsPurgedByTheNextScan() throws {
        let repo = TestSupport.tempDir("repo")
        T.write(other("alpha"), "src/a.ts", in: repo)
        T.write(other("beta"), "lib/b.ts", in: repo)
        let e = try T.makeEngine()
        try T.indexAll(e, repo)
        T.write("lib/\n", ".gitignore", in: repo)
        _ = try e.scan(); try e.runIndexing()
        XCTAssertEqual(try codePaths(e), [RealPath.of(repo.path) + "/src/a.ts"])
    }

    func testChangesToIgnoredCodeFilesQueueNothing() throws {
        let repo = TestSupport.tempDir("repo")
        T.write("tmp/\n", ".gitignore", in: repo)
        T.write(other("alpha"), "src/a.ts", in: repo)
        let e = try T.makeEngine()
        try T.indexAll(e, repo)
        let real = RealPath.of(repo.path)
        T.write(other("beta"), "tmp/new.ts", in: repo)
        try e.handle([FileWatcher.Change(path: real + "/tmp/new.ts", removedOrRenamed: false)])
        XCTAssertEqual(try e.queue.counts().queued, 0)
        T.write(other("gamma"), "src/new.ts", in: repo)
        try e.handle([FileWatcher.Change(path: real + "/src/new.ts", removedOrRenamed: false)])
        XCTAssertEqual(try e.queue.counts().queued, 1)
    }

    func testExplicitFileListsFollowTheSameRules() throws {
        let repo = TestSupport.tempDir("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        T.write("skip/\n", ".gitignore", in: repo)
        T.write(other("alpha"), "skip/a.ts", in: repo)
        T.write(other("beta"), "dist/b.ts", in: repo)
        T.write(other("gamma"), "ok.ts", in: repo)
        let e = try T.makeEngine()
        let real = RealPath.of(repo.path)
        XCTAssertEqual(try e.enqueue(files: [real + "/skip/a.ts", real + "/dist/b.ts", real + "/ok.ts"]), 1)
    }

    func testASymlinkedRootStillAppliesGitignore() throws {
        let repo = TestSupport.tempDir("repo")
        T.write("tmp/\n", ".gitignore", in: repo)
        T.write(other("alpha"), "src/a.ts", in: repo)
        T.write(other("beta"), "tmp/b.ts", in: repo)
        let link = TestSupport.tempDir("links").appendingPathComponent("repo-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo)
        let e = try T.makeEngine()
        try T.indexAll(e, link)
        XCTAssertEqual(try codePaths(e), [RealPath.of(repo.path) + "/src/a.ts"])
    }
}
