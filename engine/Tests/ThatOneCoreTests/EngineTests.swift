import CoreGraphics
import XCTest
@testable import ThatOneCore

final class EngineTests: XCTestCase {
    func makeEngine(home: URL? = nil, embedder: Embedder = FakeEmbedder(), config: Config = Config(),
                    ocr: ((CGImage) throws -> String)? = { _ in "invoice 4471" }) throws -> Engine {
        let paths = Paths(home: home ?? TestSupport.tempDir("home"))
        return try Engine(paths: paths, config: config, keyProvider: StaticKeyProvider(TestSupport.key),
                          embedder: embedder, ocr: ocr)
    }

    func testConfigRoundTripAndDefaults() throws {
        let url = TestSupport.tempDir().appendingPathComponent("config.json")
        XCTAssertEqual(try Config.load(from: url), Config())                       // missing file
        let config = Config(folders: ["/a"], exclude: ["/b"], sidecar: ["/bin/x", "y"], sidecarEnv: ["K": "V"])
        try config.save(to: url)
        XCTAssertEqual(try Config.load(from: url), config)
        try Data(#"{"folders":["/only"]}"#.utf8).write(to: url)
        XCTAssertEqual(try Config.load(from: url), Config(folders: ["/only"]))     // missing keys default
    }

    func testKeyProviders() throws {
        XCTAssertEqual(try HexKeyProvider(hex: String(repeating: "ab", count: 32)).key(), Data(repeating: 0xab, count: 32))
        XCTAssertThrowsError(try HexKeyProvider(hex: "abc").key()) { XCTAssertEqual($0 as? KeyError, .badHex) }
        XCTAssertThrowsError(try HexKeyProvider(hex: String(repeating: "zz", count: 32)).key())
        XCTAssertEqual(try StaticKeyProvider(TestSupport.key).key(), TestSupport.key)
        let env = ["THATONE_KEY_HEX": String(repeating: "01", count: 32)]
        XCTAssertEqual(try Keys.provider(environment: env).key(), Data(repeating: 1, count: 32))
    }

    func testKeychainProviderCreatesAndReusesAKey() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["THATONE_TEST_KEYCHAIN"] == "1",
                          "set THATONE_TEST_KEYCHAIN=1 to touch the real Keychain")
        let provider = KeychainKeyProvider(service: "thatone-test-\(UUID().uuidString)", account: "k")
        let first = try provider.key()
        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(try provider.key(), first)
        provider.deleteForTesting()
    }

    func testPathsRespectThatoneHome() {
        XCTAssertEqual(Paths.current(environment: ["THATONE_HOME": "/tmp/x"]).db.path, "/tmp/x/index.db")
        XCTAssertTrue(Paths.current(environment: [:]).home.path.hasSuffix("Library/Application Support/thatone"))
    }

    func testEngineIndexesAFolderAndSearchFindsIt() throws {
        let folder = TestSupport.tempDir("pics")
        let engine = try makeEngine()
        try makeImage(width: 300, height: 100, text: nil, at: folder.appendingPathComponent("a.png"))
        try engine.addFolder(folder.path)
        XCTAssertEqual(try engine.scan().enqueued, 1)
        let summary = try engine.runIndexing()
        XCTAssertEqual(summary.indexed, 1)
        let response = try engine.search("invoice")
        XCTAssertNil(response.notice)
        XCTAssertEqual(response.hits.flatMap { $0.paths }, [RealPath.of(folder.path) + "/a.png"])
        XCTAssertEqual(try engine.status().counts.filesByStatus, ["indexed": 1])
    }

    func testSearchFallsBackToKeywordWhenEmbedderIsDown() throws {
        let fake = FakeEmbedder()
        let folder = TestSupport.tempDir("pics")
        let engine = try makeEngine(embedder: fake)
        try makeImage(width: 300, height: 100, text: nil, at: folder.appendingPathComponent("a.png"))
        try engine.addFolder(folder.path)
        _ = try engine.scan()
        try engine.runIndexing()
        fake.failWhen = { modality, input in modality == .text && input == "invoice" }   // the query embedding fails
        let response = try engine.search("invoice")
        XCTAssertNotNil(response.notice)
        XCTAssertEqual(response.hits.count, 1)                                          // keyword match still found
    }

    func testBlankQueryReturnsNothingWithoutEmbedding() throws {
        let fake = FakeEmbedder()
        let engine = try makeEngine(embedder: fake)
        XCTAssertEqual(try engine.search("   ").hits.count, 0)
        XCTAssertEqual(fake.infoCalls, 1)     // the dimension probe made while creating the database
        XCTAssertTrue(fake.calls.isEmpty)     // and no embedding for a blank query
    }

    func testReopeningAnExistingDatabaseDoesNotTouchTheEmbedder() throws {
        let home = TestSupport.tempDir("home")
        _ = try makeEngine(home: home)
        let second = FakeEmbedder()
        let engine = try makeEngine(home: home, embedder: second)
        _ = try engine.status()
        try engine.forget(path: "/nowhere")
        XCTAssertEqual(second.infoCalls, 0)
        XCTAssertTrue(second.calls.isEmpty)
    }

    func testWrongKeyCannotOpenTheEngine() throws {
        let home = TestSupport.tempDir("home")
        _ = try makeEngine(home: home)
        XCTAssertThrowsError(try Engine(paths: Paths(home: home), config: Config(),
                                        keyProvider: StaticKeyProvider(TestSupport.otherKey), embedder: FakeEmbedder())) {
            XCTAssertEqual($0 as? StoreError, .wrongKeyOrNotDatabase)
        }
    }

    func testAddFolderRejectsNonFolders() throws {
        let engine = try makeEngine()
        XCTAssertThrowsError(try engine.addFolder("/definitely/not/here")) {
            XCTAssertEqual($0 as? EngineError, .notAFolder("/definitely/not/here"))
        }
    }

    func testRemoveFolderDropsRowsAndJobsImmediately() throws {
        let folder = TestSupport.tempDir("pics")
        let engine = try makeEngine()
        try makeImage(width: 300, height: 100, text: nil, at: folder.appendingPathComponent("a.png"))
        try engine.addFolder(folder.path)
        _ = try engine.scan()
        try engine.runIndexing()
        _ = try engine.scan()
        try makeImage(width: 320, height: 100, text: nil, at: folder.appendingPathComponent("later.png"))
        _ = try engine.scan()                                  // queues later.png, not yet indexed
        try engine.removeFolder(folder.path)
        XCTAssertEqual(try engine.status().counts.filesByStatus, [:])
        XCTAssertEqual(try engine.status().queue, QueueCounts(queued: 0, running: 0, failed: 0))
        XCTAssertEqual(try engine.status().folders, [])
        XCTAssertEqual(try engine.search("invoice").hits.count, 0)
    }

    func testExcludeDropsRowsAndKeepsThePathOutOfLaterScans() throws {
        let folder = TestSupport.tempDir("pics")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("private"), withIntermediateDirectories: true)
        try makeImage(width: 300, height: 100, text: nil, at: folder.appendingPathComponent("keep.png"))
        try makeImage(width: 310, height: 100, text: nil, at: folder.appendingPathComponent("private/hide.png"))
        let engine = try makeEngine()
        try engine.addFolder(folder.path)
        _ = try engine.scan()
        try engine.runIndexing()
        XCTAssertEqual(try engine.status().counts.filesByStatus, ["indexed": 2])
        try engine.exclude(folder.path + "/private")
        XCTAssertEqual(try engine.status().counts.filesByStatus, ["indexed": 1])
        XCTAssertEqual(try engine.scan().enqueued, 0)
        XCTAssertEqual(try engine.status().counts.filesByStatus, ["indexed": 1])
    }

    func testRunIndexingRefusesWhenAnotherIndexerHoldsTheLock() throws {
        let home = TestSupport.tempDir("home")
        let engine = try makeEngine(home: home)
        let held = try IndexLock.acquire(at: home.appendingPathComponent("index.lock"))
        XCTAssertNotNil(held)
        XCTAssertThrowsError(try engine.runIndexing()) { XCTAssertEqual($0 as? EngineError, .alreadyIndexing) }
        held?.release()
        XCTAssertNoThrow(try engine.runIndexing())
    }

    func testOpeningAnEngineDoesNotRequeueAnotherProcessesRunningJobs() throws {
        let home = TestSupport.tempDir("home")
        let folder = TestSupport.tempDir("pics")
        try makeImage(width: 300, height: 100, text: nil, at: folder.appendingPathComponent("a.png"))
        let first = try makeEngine(home: home)
        try first.addFolder(folder.path)
        _ = try first.scan()
        XCTAssertEqual(try first.queue.claim(limit: 8).count, 1)             // the first process is mid-batch
        let second = try makeEngine(home: home)                              // e.g. `thatone search` while indexing
        XCTAssertEqual(try second.status().queue, QueueCounts(queued: 0, running: 1, failed: 0))
    }

    func testJobsLeftRunningByACrashAreRecoveredByTheNextIndexingRun() throws {
        let home = TestSupport.tempDir("home")
        let folder = TestSupport.tempDir("pics")
        try makeImage(width: 300, height: 100, text: nil, at: folder.appendingPathComponent("a.png"))
        do {
            let crashed = try makeEngine(home: home)
            try crashed.addFolder(folder.path)
            _ = try crashed.scan()
            XCTAssertEqual(try crashed.queue.claim(limit: 8).count, 1)       // then the process dies
        }
        let next = try makeEngine(home: home)
        XCTAssertEqual(try next.runIndexing().indexed, 1)
    }

    func testSimilarAndRecentThroughTheEngine() throws {
        let folder = TestSupport.tempDir("pics")
        let engine = try makeEngine(ocr: { $0.width == 300 ? "invoice 4471" : "holiday photo" })
        try makeImage(width: 300, height: 100, text: nil, at: folder.appendingPathComponent("a.png"))
        try makeImage(width: 310, height: 100, text: nil, at: folder.appendingPathComponent("b.png"))
        try engine.addFolder(folder.path)
        _ = try engine.scan()
        try engine.runIndexing()
        let a = RealPath.of(folder.path) + "/a.png", b = RealPath.of(folder.path) + "/b.png"
        XCTAssertEqual(try engine.recent().hits.count, 2)
        XCTAssertEqual(try engine.similar(toPath: a).hits.flatMap { $0.paths }, [b])
        XCTAssertThrowsError(try engine.similar(toPath: "/never/indexed.png")) {
            XCTAssertEqual($0 as? EngineError, .notIndexed("/never/indexed.png"))
        }
    }

    func testRunIndexingPausesWhenTheEmbedderIsUnavailable() throws {
        Engine.deferDelaySeconds = 0
        defer { Engine.deferDelaySeconds = 60 }
        let fake = FakeEmbedder()
        let folder = TestSupport.tempDir("pics")
        try makeImage(width: 300, height: 100, text: nil, at: folder.appendingPathComponent("a.png"))
        try makeImage(width: 310, height: 100, text: nil, at: folder.appendingPathComponent("b.png"))
        let engine = try makeEngine(embedder: fake)
        fake.failure = SidecarEmbedder.Failure.unavailable("offline")
        try engine.addFolder(folder.path)
        _ = try engine.scan()
        let summary = try engine.runIndexing()
        XCTAssertEqual(summary.pausedReason, "embedding unavailable: offline")
        XCTAssertEqual(summary.deferred, 2)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(summary.indexed, 0)
        XCTAssertEqual(try engine.status().queue, QueueCounts(queued: 2, running: 0, failed: 0))
        XCTAssertEqual(try engine.store.int("select max(attempts) from jobs"), 0)          // no attempt was burned
        fake.failure = nil
        XCTAssertEqual(try engine.runIndexing().indexed, 2)
    }

    func testShouldContinueStopsBeforeTheNextBatch() throws {
        let folder = TestSupport.tempDir("pics")
        try makeImage(width: 300, height: 100, text: nil, at: folder.appendingPathComponent("a.png"))
        let engine = try makeEngine()
        try engine.addFolder(folder.path)
        _ = try engine.scan()
        let summary = try engine.runIndexing(shouldContinue: { false })
        XCTAssertTrue(summary.stopped)
        XCTAssertEqual(summary.indexed, 0)
        XCTAssertEqual(try engine.status().queue, QueueCounts(queued: 1, running: 0, failed: 0))
    }

    func testConcurrentExcludeAndFileEventsDoNotRace() throws {
        let folder = TestSupport.tempDir("pics")
        let engine = try makeEngine()
        try engine.addFolder(folder.path)
        let real = RealPath.of(folder.path)
        let finished = expectation(description: "both loops finished")
        finished.expectedFulfillmentCount = 2
        DispatchQueue.global().async {
            for i in 0..<150 { try? engine.exclude(real + "/skip\(i % 5)") }
            finished.fulfill()
        }
        DispatchQueue.global().async {
            for i in 0..<400 {
                try? engine.handle([FileWatcher.Change(path: real + "/f\(i % 7).png", removedOrRenamed: i % 2 == 0)])
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 60)
        XCTAssertEqual(engine.config.exclude.count, 5)
    }

    func testConfigHotKeyRoundTripsAndDefaultsToNil() throws {
        var config = Config()
        XCTAssertNil(config.hotKey)
        config.hotKey = "opt-space"
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.hotKey, "opt-space")
        XCTAssertNil(try JSONDecoder().decode(Config.self, from: Data("{}".utf8)).hotKey)      // older configs still load
    }

    func testRemoveExclusionDeletesOnlyTheUserRule() throws {
        let folder = TestSupport.tempDir("keep")
        let engine = try makeEngine()
        try engine.exclude(folder.path)
        XCTAssertEqual(engine.config.exclude, [RealPath.of(folder.path)])
        try engine.removeExclusion(folder.path)
        try engine.removeExclusion(folder.path)                                  // absent: no error
        XCTAssertEqual(engine.config.exclude, [])
        XCTAssertEqual(try Config.load(from: engine.paths.config).exclude, [])   // and it is saved
    }

    func testRemovingAFolderDuringIndexingLeavesNothingBehind() throws {
        let folder = TestSupport.tempDir("pics")
        for i in 0..<3 { try makeImage(width: 300 + i, height: 100, text: nil, at: folder.appendingPathComponent("p\(i).png")) }
        let fake = FakeEmbedder()
        let engine = try makeEngine(embedder: fake)
        try engine.addFolder(folder.path)
        _ = try engine.scan()
        var removed = false
        fake.onEmbed = { if !removed { removed = true; try? engine.removeFolder(folder.path) } }   // the user removes it mid-batch
        try engine.runIndexing()
        XCTAssertTrue(removed)
        XCTAssertEqual(try engine.status().counts.filesByStatus, [:])
        XCTAssertEqual(try engine.status().queue, QueueCounts(queued: 0, running: 0, failed: 0))
    }

    func testExcludingAPathDuringIndexingLeavesNothingBehind() throws {
        let folder = TestSupport.tempDir("pics")
        for i in 0..<3 { try makeImage(width: 300 + i, height: 100, text: nil, at: folder.appendingPathComponent("p\(i).png")) }
        let fake = FakeEmbedder()
        let engine = try makeEngine(embedder: fake)
        try engine.addFolder(folder.path)
        _ = try engine.scan()
        var excluded = false
        fake.onEmbed = { if !excluded { excluded = true; try? engine.exclude(folder.path) } }
        try engine.runIndexing()
        XCTAssertEqual(try engine.status().counts.filesByStatus, [:])
    }
}
