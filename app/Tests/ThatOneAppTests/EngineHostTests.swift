import ThatOneCore
import XCTest
@testable import ThatOneApp

final class EngineHostTests: XCTestCase {
    final class Box<T> { var value: T; init(_ v: T) { value = v } }

    struct Setup { let host: EngineHost; let engine: Engine; let embedder: AppFakeEmbedder; let folder: URL }

    /// A host over an engine whose watched folder holds `images` distinct PNGs.
    func setup(images: Int = 3, power: @escaping () -> String? = { nil }) throws -> Setup {
        let folder = Fixtures.tempDir("pics")
        for i in 0..<images { try Fixtures.writePNG(width: 300 + i, height: 100, to: folder.appendingPathComponent("img\(i).png")) }
        let embedder = AppFakeEmbedder()
        let engine = try Fixtures.makeEngine(embedder: embedder)
        try engine.addFolder(folder.path)
        let host = EngineHost(engine: engine, power: power, memory: FakeMemory(), onChange: { _ in })
        host.kickDebounce = 0.02
        host.retryDelay = 0.3
        return Setup(host: host, engine: engine, embedder: embedder, folder: folder)
    }

    func testStartScansIndexesAndGoesIdle() async throws {
        let s = try setup()
        defer { s.host.stop() }
        s.host.start()
        let ok = await eventually { s.host.snapshot.state == .idle && s.host.snapshot.files["indexed"] == 3 }
        XCTAssertTrue(ok, "\(s.host.snapshot)")
        XCTAssertEqual(s.host.snapshot.segments["image"], 3)
    }

    func testPauseByTheUserHoldsIndexingUntilResume() async throws {
        let s = try setup()
        defer { s.host.stop() }
        s.host.pause()
        s.host.start()
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(s.host.snapshot.state, .pausedByUser)
        XCTAssertNil(s.host.snapshot.files["indexed"])
        s.host.resume()
        let ok = await eventually { s.host.snapshot.state == .idle && s.host.snapshot.files["indexed"] == 3 }
        XCTAssertTrue(ok, "\(s.host.snapshot)")
    }

    func testUnavailableEmbedderPausesTheHost() async throws {
        Engine.deferDelaySeconds = 0
        defer { Engine.deferDelaySeconds = 60 }
        let s = try setup()
        defer { s.host.stop() }
        s.embedder.failure = SidecarEmbedder.Failure.unavailable("offline")
        s.host.start()
        let paused = await eventually { s.host.snapshot.state == .paused("embedding unavailable: offline") }
        XCTAssertTrue(paused, "\(s.host.snapshot)")
        XCTAssertEqual(s.host.snapshot.queue.failed, 0)                      // waiting is not failing
        s.embedder.failure = nil                                              // the retry timer picks it up
        let recovered = await eventually { s.host.snapshot.state == .idle && s.host.snapshot.files["indexed"] == 3 }
        XCTAssertTrue(recovered, "\(s.host.snapshot)")
    }

    func testLowPowerPausesAndRecovers() async throws {
        let reason = Box<String?>("Low Power Mode is on")
        let s = try setup(power: { reason.value })
        defer { s.host.stop() }
        s.host.start()
        let paused = await eventually { s.host.snapshot.state == .paused("Low Power Mode is on") }
        XCTAssertTrue(paused, "\(s.host.snapshot)")
        XCTAssertNil(s.host.snapshot.files["indexed"])
        reason.value = nil
        s.host.kick()
        let ok = await eventually { s.host.snapshot.state == .idle && s.host.snapshot.files["indexed"] == 3 }
        XCTAssertTrue(ok, "\(s.host.snapshot)")
    }

    func testIndexFoldersThroughTheServiceQueuesAndIndexes() async throws {
        let folder = Fixtures.tempDir("pics")
        for i in 0..<2 { try Fixtures.writePNG(width: 300 + i, height: 100, to: folder.appendingPathComponent("img\(i).png")) }
        let engine = try Fixtures.makeEngine()
        let host = EngineHost(engine: engine, power: { nil }, memory: FakeMemory(), onChange: { _ in })
        host.kickDebounce = 0.02
        defer { host.stop() }
        host.start()
        let queued = try host.index(folders: [folder.path])
        XCTAssertEqual(queued, 2)
        let ok = await eventually { host.snapshot.state == .idle && host.snapshot.files["indexed"] == 2 }
        XCTAssertTrue(ok, "\(host.snapshot)")
        XCTAssertEqual(host.snapshot.folders, [RealPath.of(folder.path)])
    }

    func testANewFileInAWatchedFolderIsIndexed() async throws {
        let s = try setup(images: 2)
        defer { s.host.stop() }
        s.host.start()
        let first = await eventually { s.host.snapshot.state == .idle && s.host.snapshot.files["indexed"] == 2 }
        XCTAssertTrue(first, "\(s.host.snapshot)")
        try Fixtures.writePNG(width: 411, height: 100, to: s.folder.appendingPathComponent("late.png"))
        let second = await eventually { s.host.snapshot.files["indexed"] == 3 }
        XCTAssertTrue(second, "\(s.host.snapshot)")
    }

    func testStatusMirrorsTheSnapshot() async throws {
        let s = try setup()
        defer { s.host.stop() }
        s.host.pause()
        XCTAssertEqual(try s.host.status().state, "paused")
        XCTAssertEqual(try s.host.status().detail, "paused by you")
        s.host.resume()
        s.host.start()
        _ = await eventually { s.host.snapshot.state == .idle && s.host.snapshot.files["indexed"] == 3 }
        let status = try s.host.status()
        XCTAssertEqual(status.state, "idle")
        XCTAssertEqual(status.files, ["indexed": 3])
        XCTAssertEqual(status.queue, ServiceQueue(queued: 0, running: 0, failed: 0))
    }

    func testStatusCarriesSkippedFilesWithTheirReasons() async throws {
        let s = try setup()
        defer { s.host.stop() }
        try s.engine.store.upsertFile(path: "/elsewhere/app.min.js", contentId: nil, kind: "code", size: 1, mtime: 1,
                                      status: "skipped", note: "minified")
        s.host.start()
        _ = await eventually { s.host.snapshot.state == .idle && s.host.snapshot.files["indexed"] == 3 }
        let status = try s.host.status()
        XCTAssertEqual(status.skippedFiles, [ServiceFailedFile(path: "/elsewhere/app.min.js", note: "minified")])
        XCTAssertEqual(status.skippedFilesTotal, 1)
    }

    func testSearchThroughTheServiceFindsIndexedImages() async throws {
        let s = try setup()
        defer { s.host.stop() }
        s.host.start()
        _ = await eventually { s.host.snapshot.files["indexed"] == 3 }
        XCTAssertEqual(try s.host.search(ServiceQuery(query: "words")).hits.count, 3)
        XCTAssertEqual(try s.host.search(ServiceQuery(query: "")).hits.count, 3)             // browse
        let first = try XCTUnwrap(try s.host.search(ServiceQuery(query: "")).hits.first?.paths.first)
        XCTAssertEqual(try s.host.similar(path: first, limit: 5).hits.count, 2)
    }

    func testUiActionsNeedAHandler() throws {
        let s = try setup()
        XCTAssertThrowsError(try s.host.ui(action: "show_panel")) {
            guard case .unsupported? = $0 as? ServiceError else { return XCTFail("\($0)") }
        }
        let seen = Box<[String]>([])
        s.host.uiHandler = { seen.value.append($0) }
        try s.host.ui(action: "show_panel")
        XCTAssertEqual(seen.value, ["show_panel"])
    }

    func testRemoveFolderDropsRowsAndStopsWatching() async throws {
        let s = try setup()
        defer { s.host.stop() }
        s.host.start()
        _ = await eventually { s.host.snapshot.files["indexed"] == 3 }
        try s.host.removeFolder(s.folder.path)
        XCTAssertEqual(s.host.snapshot.files, [:])
        XCTAssertEqual(s.host.snapshot.folders, [])
    }

    func testIndexMarksTheHostIndexingBeforeItReturns() throws {
        let folder = Fixtures.tempDir("pics")
        try Fixtures.writePNG(width: 300, height: 100, to: folder.appendingPathComponent("a.png"))
        let engine = try Fixtures.makeEngine()
        let host = EngineHost(engine: engine, power: { nil }, memory: FakeMemory(), onChange: { _ in })
        host.kickDebounce = 30                                  // the real pass is far away: a CLI polling now must still see "indexing"
        defer { host.stop() }
        XCTAssertEqual(try host.index(folders: [folder.path]), 1)
        guard case .indexing = host.snapshot.state else { return XCTFail("\(host.snapshot.state)") }
    }

    // MARK: Apple Photos

    struct PhotosSetup { let host: EngineHost; let engine: Engine; let assets: AppFakeAssets; let watchers: Box<[FakeWatcher]> }

    func photosSetup(auth: AssetAuthorization = .authorized, request: AssetAuthorization? = nil, photos: Bool = false) throws -> PhotosSetup {
        let assets = AppFakeAssets()
        assets.auth = auth
        assets.add("A/L0/001", filename: "cake 1.HEIC", width: 300)
        assets.add("B/L0/001", filename: "cake 2.HEIC", width: 310)
        let engine = try Engine(paths: Paths(home: Fixtures.tempDir("home")), config: Config(photos: photos),
                                keyProvider: StaticKeyProvider(Fixtures.key), embedder: AppFakeEmbedder(), ocr: { _ in "birthday cake" },
                                assets: assets)
        let watchers = Box<[FakeWatcher]>([])
        let host = EngineHost(engine: engine, power: { nil }, memory: FakeMemory(), assets: assets,
                              requestPhotosAccess: request.map { answer in { done in assets.auth = answer; done(answer) } },
                              makePhotosWatcher: { _ in let w = FakeWatcher(); watchers.value.append(w); return w },
                              onChange: { _ in })
        host.kickDebounce = 0.02
        return PhotosSetup(host: host, engine: engine, assets: assets, watchers: watchers)
    }

    func testEnablingPhotosAsksPermissionIndexesAndReportsState() async throws {
        let s = try photosSetup(auth: .notDetermined, request: .authorized)
        defer { s.host.stop() }
        s.host.start()
        s.host.setPhotos(true)
        let ok = await eventually { s.host.snapshot.photosCount == 2 && s.host.snapshot.state == .idle }
        XCTAssertTrue(ok, "\(s.host.snapshot)")
        XCTAssertEqual(s.host.snapshot.photos, .on(limited: false))
        XCTAssertTrue(s.engine.config.photos)
        XCTAssertEqual(try s.host.status().photos, "on")
        XCTAssertEqual(s.watchers.value.count, 1)
        XCTAssertEqual(s.watchers.value.first?.started, 1)
        XCTAssertEqual(try s.host.search(ServiceQuery(query: "cake")).hits.count, 2)
    }

    func testDeniedPermissionLeavesPhotosOffAndSaysSo() async throws {
        let s = try photosSetup(auth: .notDetermined, request: .denied)
        defer { s.host.stop() }
        s.host.start()
        s.host.setPhotos(true)
        let ok = await eventually { s.host.snapshot.photos == .denied }
        XCTAssertTrue(ok, "\(s.host.snapshot.photos)")
        XCTAssertFalse(s.engine.config.photos)
        XCTAssertEqual(try s.host.status().photos, "denied")
        XCTAssertEqual(s.host.snapshot.photosCount, 0)
        XCTAssertTrue(s.watchers.value.isEmpty)
    }

    func testDisablingPhotosForgetsEverythingAndStopsWatching() async throws {
        let s = try photosSetup(photos: true)
        defer { s.host.stop() }
        s.host.start()
        let on = await eventually { s.host.snapshot.photosCount == 2 }
        XCTAssertTrue(on, "\(s.host.snapshot)")
        s.host.setPhotos(false)
        let off = await eventually { s.host.snapshot.photos == .off && s.host.snapshot.photosCount == 0 }
        XCTAssertTrue(off, "\(s.host.snapshot)")
        XCTAssertEqual(s.watchers.value.first?.stopped, 1)
        XCTAssertEqual(try s.host.search(ServiceQuery(query: "cake")).hits.count, 0)
    }

    func testAlreadyEnabledPhotosStartOnLaunchAndLimitedAccessIsReported() async throws {
        let s = try photosSetup(auth: .limited, photos: true)
        defer { s.host.stop() }
        s.host.start()
        let ok = await eventually { s.host.snapshot.photosCount == 2 }
        XCTAssertTrue(ok)
        XCTAssertEqual(s.host.snapshot.photos, .on(limited: true))
        XCTAssertEqual(try s.host.status().photos, "on (limited)")
    }

    func testRevokedPermissionIsShownAndKeepsTheIndex() async throws {
        let s = try photosSetup(photos: true)
        defer { s.host.stop() }
        s.host.start()
        _ = await eventually { s.host.snapshot.photosCount == 2 }
        s.assets.auth = .denied
        s.host.kick()
        let shown = await eventually { s.host.snapshot.photos == .denied }
        XCTAssertTrue(shown, "\(s.host.snapshot.photos)")
        XCTAssertEqual(s.host.snapshot.photosCount, 2)                         // nothing was purged
    }

    func testTurningPhotosOffDoesNotWaitForARunningIndexingPass() async throws {
        let assets = AppFakeAssets()
        for i in 0..<3 { assets.add("A\(i)/L0/001", width: 300 + i) }
        let embedder = AppFakeEmbedder()
        embedder.delay = 0.6                                                    // each embedding call is slow: the pass lasts a while
        let engine = try Engine(paths: Paths(home: Fixtures.tempDir("home")), config: Config(photos: true),
                                keyProvider: StaticKeyProvider(Fixtures.key), embedder: embedder, ocr: { _ in "birthday cake" }, assets: assets)
        let host = EngineHost(engine: engine, power: { nil }, memory: FakeMemory(), assets: assets, onChange: { _ in })
        host.kickDebounce = 0.02
        defer { host.stop() }
        host.start()
        let running = await eventually { if case .indexing = host.snapshot.state { return true } else { return false } }
        XCTAssertTrue(running, "\(host.snapshot.state)")
        host.setPhotos(false)
        let off = await eventually(timeout: 1.0) { !engine.config.photos }
        XCTAssertTrue(off, "the setting waited behind the indexing pass")
        if case .indexing = host.snapshot.state {} else { XCTFail("the pass should still have been running: \(host.snapshot.state)") }
        let gone = await eventually { host.snapshot.photosCount == 0 && host.snapshot.state == .idle }
        XCTAssertTrue(gone, "\(host.snapshot)")
        XCTAssertEqual(try engine.photoCount(), 0)
    }

    func testRevokedAccessCanStillBeTurnedOffToForgetThePhotos() async throws {
        let s = try photosSetup(photos: true)
        defer { s.host.stop() }
        s.host.start()
        _ = await eventually { s.host.snapshot.photosCount == 2 }
        s.assets.auth = .denied
        s.host.kick()
        _ = await eventually { s.host.snapshot.photos == .denied }
        XCTAssertTrue(s.host.snapshot.photosEnabled)                           // the toggle can show "on" and be switched off
        s.host.setPhotos(false)
        let ok = await eventually { !s.host.snapshot.photosEnabled && s.host.snapshot.photosCount == 0 }
        XCTAssertTrue(ok, "\(s.host.snapshot)")
    }

    func testAnUnansweredPermissionPromptDoesNotStallIndexing() async throws {
        let assets = AppFakeAssets()
        assets.auth = .notDetermined
        assets.add("A/L0/001", filename: "cake.HEIC", width: 300)
        let engine = try Engine(paths: Paths(home: Fixtures.tempDir("home")), config: Config(),
                                keyProvider: StaticKeyProvider(Fixtures.key), embedder: AppFakeEmbedder(), ocr: { _ in "cake" }, assets: assets)
        let answer = Box<((AssetAuthorization) -> Void)?>(nil)
        let host = EngineHost(engine: engine, power: { nil }, memory: FakeMemory(), assets: assets,
                              requestPhotosAccess: { answer.value = $0 }, makePhotosWatcher: { _ in FakeWatcher() }, onChange: { _ in })
        host.kickDebounce = 0.02
        defer { host.stop() }
        host.start()
        host.setPhotos(true)
        let waiting = await eventually { host.snapshot.photos == .needsPermission && answer.value != nil }
        XCTAssertTrue(waiting, "\(host.snapshot.photos)")
        let folder = Fixtures.tempDir("pics")
        try Fixtures.writePNG(width: 301, height: 100, to: folder.appendingPathComponent("a.png"))
        _ = try host.index(folders: [folder.path])
        let indexed = await eventually { host.snapshot.files["indexed"] == 1 }                // not stuck behind the prompt
        XCTAssertTrue(indexed, "\(host.snapshot)")
        assets.auth = .authorized
        answer.value?(.authorized)
        let on = await eventually { host.snapshot.photosCount == 1 }
        XCTAssertTrue(on, "\(host.snapshot)")
    }

    func testAGrantInSystemSettingsClearsACachedRefusal() async throws {
        let s = try photosSetup(auth: .notDetermined, request: .denied)
        defer { s.host.stop() }
        s.host.start()
        s.host.setPhotos(true)
        let denied = await eventually { s.host.snapshot.photos == .denied }
        XCTAssertTrue(denied)
        s.assets.auth = .authorized                                            // allowed later in System Settings
        s.host.kick()
        let cleared = await eventually { s.host.snapshot.photos == .off }
        XCTAssertTrue(cleared, "\(s.host.snapshot.photos)")
    }

    func testAudioStateFiresForVideoWithoutTheModel() async throws {
        let engine = try Fixtures.makeEngine()
        let host = EngineHost(engine: engine, power: { nil }, memory: FakeMemory(), audioAvailable: { false }, onChange: { _ in })
        defer { host.stop() }
        host.start()
        host.setKinds(["video"])
        let missing = await eventually { host.snapshot.audio == .modelMissing }
        XCTAssertTrue(missing, "\(host.snapshot.audio)")
        host.setKinds(["image"])
        let off = await eventually { host.snapshot.audio == .off }
        XCTAssertTrue(off, "\(host.snapshot.audio)")
    }

    func testSetKindsPurgesWhatIsSwitchedOffAndRestoresWhatIsSwitchedOn() async throws {
        let folder = Fixtures.tempDir("docs")
        PDFFixturesApp.make("Contract text about the notice period and payment terms.", at: folder.appendingPathComponent("a.pdf"))
        try Fixtures.writePNG(width: 300, height: 100, to: folder.appendingPathComponent("b.png"))
        let engine = try Fixtures.makeEngine(ocr: { _ in "words" })
        try engine.addFolder(folder.path)
        let host = EngineHost(engine: engine, power: { nil }, memory: FakeMemory(), onChange: { _ in })
        host.kickDebounce = 0.02
        defer { host.stop() }
        host.start()
        let both = await eventually { host.snapshot.kinds == ["pdf": 1, "image": 1] }
        XCTAssertTrue(both, "\(host.snapshot.kinds)")
        host.setKinds(["image"])
        let off = await eventually { host.snapshot.kinds == ["image": 1] && host.snapshot.enabledKinds == ["image"] }
        XCTAssertTrue(off, "\(host.snapshot.kinds)")
        XCTAssertEqual(try host.status().kinds, ["image": 1])
        host.setKinds(["image", "pdf"])
        let back = await eventually { host.snapshot.kinds == ["pdf": 1, "image": 1] }
        XCTAssertTrue(back, "\(host.snapshot.kinds)")
    }

    func testQuickKindTogglesStickAndApplyInOrder() async throws {
        let engine = try Fixtures.makeEngine()
        let host = EngineHost(engine: engine, power: { nil }, memory: FakeMemory(), onChange: { _ in })
        host.kickDebounce = 0.02
        defer { host.stop() }
        host.start()
        _ = await eventually { host.snapshot.state == .idle }
        host.setKinds(["image"])
        XCTAssertEqual(host.snapshot.enabledKinds, ["image"])                       // visible at once, before the engine has applied it
        host.setKinds(["image", "text"])
        host.setKinds(["image", "text", "pdf"])
        XCTAssertEqual(host.snapshot.enabledKinds, ["image", "text", "pdf"])
        host.kick()                                                                 // a refresh in between must not revert the display
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(host.snapshot.enabledKinds, ["image", "text", "pdf"])
        let applied = await eventually { engine.config.kinds == ["image", "text", "pdf"] }
        XCTAssertTrue(applied, "\(engine.config.kinds)")                           // the last choice won, applied in order
        XCTAssertEqual(host.snapshot.enabledKinds, ["image", "text", "pdf"])
    }

    // MARK: quitting

    func testStopPutsTheClaimedBatchBackWithoutWaitingForIt() async throws {
        let s = try setup(images: 3)
        s.embedder.delay = 2                                                              // a long read is in progress at quit
        s.host.start()
        let claimed = await eventually { (try? s.engine.queue.counts().running) == 3 && s.embedder.calls > 0 }
        XCTAssertTrue(claimed)
        let started = Date()
        s.host.stop()                                                                     // what applicationWillTerminate runs
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)                           // does not wait for the read
        let counts = try s.engine.queue.counts()
        XCTAssertEqual([counts.queued, counts.running, counts.failed], [3, 0, 0])
        let history = try s.engine.store.query("select attempts, last_error from jobs") { "\($0.int(0))|\($0.text(1))" }
        XCTAssertEqual(history, ["0|", "0|", "0|"])                                       // the next launch sees no crash
        let settled = await eventually { (try? s.engine.queue.counts()).map { $0.queued + $0.running + $0.failed } == 0 }
        XCTAssertTrue(settled)                                                            // the read in progress still lands
    }

    // MARK: memory pressure

    func testLowMemoryStopsIndexingBetweenBatchesAndItResumesWhenMemoryFrees() async throws {
        let folder = Fixtures.tempDir("many")
        for i in 0..<30 { try Fixtures.writePNG(width: 300 + i, height: 100, to: folder.appendingPathComponent("p\(i).png")) }
        let embedder = AppFakeEmbedder()
        embedder.delay = 0.15
        let engine = try Fixtures.makeEngine(embedder: embedder)
        try engine.addFolder(folder.path)
        let memory = FakeMemory()
        let host = EngineHost(engine: engine, power: { nil }, memory: memory, onChange: { _ in })
        host.kickDebounce = 0.02
        host.retryDelay = 60
        defer { host.stop() }
        host.start()
        let started = await eventually { (host.snapshot.files["indexed"] ?? 0) >= 1 }
        XCTAssertTrue(started)
        memory.set(.warning)                                                              // memory gets tight mid-run
        let paused = await eventually { host.snapshot.state == .paused("memory is low") }
        XCTAssertTrue(paused, "\(host.snapshot.state)")
        let atPause = host.snapshot.files["indexed"] ?? 0
        XCTAssertLessThan(atPause, 30)
        XCTAssertEqual(host.snapshot.queue.failed, 0)                                     // waiting is not failing
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(host.snapshot.files["indexed"] ?? 0, atPause)                      // nothing moves while memory is low
        memory.set(.normal)                                                               // the system says it is fine again
        let done = await eventually { host.snapshot.files["indexed"] == 30 && host.snapshot.state == .idle }
        XCTAssertTrue(done, "\(host.snapshot)")
    }

    func testMemoryPressureAtStartPausesBeforeAnyWork() async throws {
        let folder = Fixtures.tempDir("few")
        try Fixtures.writePNG(width: 300, height: 100, to: folder.appendingPathComponent("a.png"))
        let engine = try Fixtures.makeEngine()
        try engine.addFolder(folder.path)
        let memory = FakeMemory()
        memory.set(.critical)
        let host = EngineHost(engine: engine, power: { nil }, memory: memory, onChange: { _ in })
        host.kickDebounce = 0.02
        defer { host.stop() }
        host.start()
        let paused = await eventually { host.snapshot.state == .paused("memory is low") }
        XCTAssertTrue(paused)
        XCTAssertNil(host.snapshot.files["indexed"])
    }
}
