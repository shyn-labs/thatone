import XCTest
@testable import ThatOneCore

/// A reader that only counts: proves a path never reached the video reader.
private final class SpyReader: FileReader {
    private(set) var calls = 0
    func read(_ url: URL) throws -> ReadResult { calls += 1; return ReadResult(segments: []) }
}

final class VideoIndexTests: XCTestCase {
    /// A real 2 s clip with a sine soundtrack: the audio windows are cut from it for real; frame times come from a fake probe.
    static let clip = VideoFixtures.mp4(scenes: [(2, (200, 30, 30))], sine: true, name: "talk.mp4")

    final class Setup {
        let dir = TestSupport.tempDir("videoidx")
        let store: Store
        let embedder = FakeEmbedder()
        let transcriber = FakeTranscriber()
        let cutter = FakeFrameCutter()
        var keepGoing = true
        var kinds: Set<String> = ["video"]
        let indexer: Indexer
        let video = VideoIndexTests.clip

        /// `duration` sets the frame schedule (one frame every 5 s up to 720); `sound: false` makes the soundtrack silent.
        init(duration: Double = 100, sound: Bool = true) throws {
            store = try Store.open(path: dir.appendingPathComponent("index.db").path, key: TestSupport.key, dim: FakeEmbedder.dim)
            var go: (() -> Bool) = { true }
            var enabled: (() -> Set<String>) = { ["video"] }
            let audio = AudioReader(transcriber: transcriber, probe: fakeProbe(duration: 2, loudness: { _ in sound ? 0.2 : 0 }),
                                    shouldContinue: { go() }, maxBytes: ReadLimits.maxVideoBytes)
            let reader = VideoReader(audio: audio, probe: fakeVideoProbe(duration: duration))
            indexer = Indexer(store: store, embedder: embedder, workDir: dir.appendingPathComponent("work"), exclusions: Exclusions(),
                              roots: { [] }, ocr: { _ in "" }, enabledKinds: { enabled() }, readers: ["video": reader],
                              frameCutter: cutter, shouldContinue: { go() })
            go = { [unowned self] in self.keepGoing }
            enabled = { [unowned self] in self.kinds }
            embedder.imageVector = { label in oneHot(Int((Double(label) ?? 0) / 5)) }      // every frame distinct by default
            transcriber.segments = [TranscriptSegment(start: 0.2, end: 1.8, text: "the whiteboard shows the architecture")]
        }

        func index() -> IndexOutcome? { indexer.index(paths: [video.path])[video.path] }

        var jpegsLeft: [String] {
            let work = dir.appendingPathComponent("work")
            guard let walk = FileManager.default.enumerator(atPath: work.path) else { return [] }
            return walk.compactMap { $0 as? String }.filter { $0.hasSuffix(".jpg") }
        }

        func frameRows() throws -> [(anchor: String, text: String)] {
            try store.query("select anchor, text from segments where modality = 'frame' order by id") { ($0.text(0), $0.text(1)) }
        }
    }

    // MARK: dedupe (pure)

    func testDedupeEmptyInputKeepsNothing() {
        XCTAssertEqual(FrameDedupe.kept([]), [])
        XCTAssertEqual(FrameDedupe.kept([], after: oneHot(0)), [])
    }

    func testDedupeAlwaysKeepsTheFirstFrame() {
        XCTAssertEqual(FrameDedupe.kept([oneHot(2)]), [0])
        XCTAssertEqual(FrameDedupe.kept([[0, 0, 0], oneHot(2)]), [1])                    // the first usable one
    }

    // Hardening: a vector with no direction or with a NaN/inf is never kept and never the comparison base.
    func testDedupeAZeroVectorInTheMiddleIsDroppedAndIsNotTheBase() {
        let zero = [Float](repeating: 0, count: FakeEmbedder.dim)
        XCTAssertEqual(FrameDedupe.kept([oneHot(0), zero, oneHot(0)]), [0])               // still compared with frame 0
        XCTAssertEqual(FrameDedupe.kept([oneHot(0), zero, oneHot(1)]), [0, 2])
        XCTAssertEqual(FrameDedupe.kept([oneHot(1)], after: zero), [0])                    // a bad base is no base
    }

    func testDedupeANonFiniteVectorIsDropped() {
        XCTAssertEqual(FrameDedupe.kept([[.nan, 1], [0, 1]]), [1])
        XCTAssertEqual(FrameDedupe.kept([[1, 0], [.nan, 0], [1, 0]]), [0])
        XCTAssertEqual(FrameDedupe.kept([[.infinity, 0], [1, 0]]), [1])
        XCTAssertEqual(FrameDedupe.kept([[0, 1]], after: [.nan, 1]), [0])
    }

    func testDedupeVectorsOfDifferentLengthsAreNotDuplicates() {
        XCTAssertEqual(FrameDedupe.kept([[1, 0], [1, 0, 0]]), [0, 1])                      // not truncated into a match
        XCTAssertEqual(FrameDedupe.kept([[1, 0, 0]], after: [1, 0]), [0])
    }

    func testDedupeAllZeroInputKeepsNothing() {
        XCTAssertEqual(FrameDedupe.kept([[0, 0], [0, 0], [0, 0]]), [])
    }

    func testDedupeIdenticalFramesKeepOne() {
        XCTAssertEqual(FrameDedupe.kept(Array(repeating: oneHot(4), count: 9)), [0])
    }

    func testDedupeOrthogonalFramesAreAllKept() {
        XCTAssertEqual(FrameDedupe.kept([oneHot(0), oneHot(1), oneHot(0), oneHot(1)]), [0, 1, 2, 3])
    }

    func testDedupeNearTheThresholdOnBothSides() {
        func at(_ c: Float) -> [Float] { [c, (1 - c * c).squareRoot()] }
        let base: [Float] = [1, 0]
        XCTAssertEqual(FrameDedupe.cosine(base, at(0.969)), 0.969, accuracy: 1e-5)
        XCTAssertEqual(FrameDedupe.kept([base, at(0.969)], threshold: 0.97), [0, 1])      // just below: a new view
        XCTAssertEqual(FrameDedupe.kept([base, at(0.971)], threshold: 0.97), [0])         // just above: a duplicate
    }

    func testDedupeNormalizesVectors() {
        // A raw dot product would call the first pair a duplicate (100 >= 0.97) and keep the second (0.01 < 0.97).
        XCTAssertEqual(FrameDedupe.kept([[10, 0], [10, 10]]), [0, 1])
        XCTAssertEqual(FrameDedupe.kept([[0.1, 0], [0.1, 0]]), [0])
        XCTAssertEqual(FrameDedupe.cosine([3, 4], [300, 400]), 1, accuracy: 1e-5)
        XCTAssertEqual(FrameDedupe.cosine([0, 0], [1, 0]), 0)                             // no direction: never a duplicate
    }

    func testDedupeComparesWithTheLastKeptFrameAcrossGroups() {
        func angle(_ deg: Float) -> [Float] { [cos(deg * .pi / 180), sin(deg * .pi / 180)] }
        // A slow pan: each step is a near-duplicate of the one before, but the drift from the last kept frame adds up.
        XCTAssertEqual(FrameDedupe.kept([angle(0), angle(11), angle(22)]), [0, 2])
        XCTAssertEqual(FrameDedupe.kept([oneHot(0), oneHot(1)], after: oneHot(0)), [1])  // the previous group's last kept frame
    }

    // MARK: indexer

    // (1) Two scenes alternating every four frames: one stored frame per scene, starting with the first.
    func testAlternatingScenesStoreOneFramePerScene() throws {
        let s = try Setup()
        s.embedder.imageVector = { label in oneHot((Int((Double(label) ?? 0) / 5) / 4) % 2) }
        XCTAssertEqual(s.index(), .indexed)
        XCTAssertEqual(s.cutter.calls.count, 20)
        XCTAssertEqual(try s.frameRows().map(\.anchor),
                       [#"{"t0":0,"t1":5}"#, #"{"t0":20,"t1":25}"#, #"{"t0":40,"t1":45}"#, #"{"t0":60,"t1":65}"#, #"{"t0":80,"t1":85}"#])
    }

    // (2) A static video keeps one frame, even across groups.
    func testIdenticalFramesKeepOne() throws {
        let s = try Setup()
        s.embedder.imageVector = { _ in oneHot(3) }
        XCTAssertEqual(s.index(), .indexed)
        XCTAssertEqual(try s.frameRows().map(\.anchor), [#"{"t0":0,"t1":5}"#])
    }

    // (3) A spoken secret skips the whole video before any frame is cut.
    func testASpokenSecretSkipsTheVideoBeforeAnyFrameIsCut() throws {
        let s = try Setup()
        s.transcriber.segments = [TranscriptSegment(start: 0.2, end: 1.8, text: AudioIndexingTests.secret)]
        XCTAssertEqual(s.index(), .skipped("secret"))
        XCTAssertTrue(s.cutter.calls.isEmpty)
        XCTAssertEqual(s.embedder.callCount(.image), 0)
        XCTAssertEqual(s.jpegsLeft, [])
        XCTAssertEqual(try s.store.fileRecord(path: s.video.path)?.note, "secret")
    }

    // (4) Frame files never outlive the call, whatever happens.
    func testFrameFilesAreGoneAfterSuccess() throws {
        let s = try Setup()
        XCTAssertEqual(s.index(), .indexed)
        XCTAssertEqual(s.cutter.calls.count, 20)
        XCTAssertEqual(s.jpegsLeft, [])
    }

    func testFrameFilesAreGoneAfterAPause() throws {
        let s = try Setup()
        s.embedder.onEmbed = { if s.embedder.callCount(.image) >= 1 { s.keepGoing = false } }
        XCTAssertEqual(s.index(), .deferred("paused"))
        XCTAssertEqual(s.cutter.calls.count, 8)
        XCTAssertEqual(s.jpegsLeft, [])
    }

    func testFrameFilesAreGoneAfterAnEmbedError() throws {
        let s = try Setup()
        s.embedder.failWhen = { modality, _ in modality == .image }
        guard case .failed = s.index() else { return XCTFail("expected a failed file") }
        XCTAssertGreaterThan(s.cutter.calls.count, 0)
        XCTAssertEqual(s.jpegsLeft, [])
    }

    func testAnEmbeddingEnvironmentErrorDefersAndLeavesNoFrameFiles() throws {
        let s = try Setup()
        s.embedder.onEmbed = { if s.embedder.calls.last?.0 == .image { s.embedder.failure = SidecarEmbedder.Failure.unavailable("gone") } }
        guard case .deferred = s.index() else { return XCTFail("expected a deferral") }
        XCTAssertNil(try s.store.fileRecord(path: s.video.path))
        XCTAssertEqual(s.jpegsLeft, [])
    }

    func testACutterErrorFailsTheFileAndLeavesNoFrameFiles() throws {
        let s = try Setup()
        s.cutter.failure = { $0 > 50 ? ReadFailure.unreadable("broken stream") : nil }
        guard case .failed(let why) = s.index() else { return XCTFail("expected a failed file") }
        XCTAssertTrue(why.contains("broken stream"), why)
        XCTAssertEqual(try s.store.fileRecord(path: s.video.path)?.status, "failed")
        XCTAssertEqual(s.jpegsLeft, [])
    }

    // Any other cutter error is the environment (a full disk, AVFoundation's media services reset): the file waits.
    func testAnyOtherCutterErrorDefersTheFile() throws {
        let s = try Setup()
        s.cutter.failure = { $0 > 50 ? NSError(domain: "AVFoundationErrorDomain", code: -11819) : nil }
        guard case .deferred(let why) = s.index() else { return XCTFail("expected a deferral") }
        XCTAssertTrue(why.hasPrefix("frame cutting unavailable"), why)
        XCTAssertNil(try s.store.fileRecord(path: s.video.path))
        XCTAssertEqual(s.jpegsLeft, [])
    }

    func testAMediaServicesResetDefersTheFile() throws {
        let s = try Setup()
        s.cutter.failure = { _ in FrameCutError.mediaServices("reset") }
        guard case .deferred(let why) = s.index() else { return XCTFail("expected a deferral") }
        XCTAssertTrue(why.hasPrefix("frame cutting unavailable"), why)
    }

    // Some frames skipped (blank, undecodable, timed out): the note says how many; none skipped: no such note.
    func testSomeSkippedFramesAreCountedInTheNote() throws {
        let s = try Setup()
        s.cutter.written = { $0 >= 30 }                                                   // 2.5 ... 27.5: six frames return false
        XCTAssertEqual(s.index(), .indexed)
        let note = try XCTUnwrap(s.store.fileRecord(path: s.video.path)).note
        XCTAssertTrue(note.components(separatedBy: "; ").contains("6 frames skipped (blank or unreadable)"), note)
        XCTAssertFalse(note.contains("no frames could be read"), note)
        XCTAssertEqual(try s.frameRows().count, 14)
    }

    func testNoSkippedFramesMeansNoSkipNote() throws {
        let s = try Setup()
        XCTAssertEqual(s.index(), .indexed)
        let note = try XCTUnwrap(s.store.fileRecord(path: s.video.path)).note
        XCTAssertFalse(note.contains("skipped"), note)
    }

    // (5) A pause between frame groups keeps the transcript; the retry cuts the frames again and finishes.
    func testAPauseBetweenGroupsKeepsTheTranscriptForTheRetry() throws {
        let s = try Setup()
        s.embedder.onEmbed = { if s.embedder.callCount(.image) >= 1 { s.keepGoing = false } }
        XCTAssertEqual(s.index(), .deferred("paused"))
        XCTAssertEqual(s.transcriber.calls.count, 1)
        XCTAssertEqual(s.jpegsLeft, [])
        s.keepGoing = true; s.embedder.onEmbed = nil
        XCTAssertEqual(s.index(), .indexed)
        XCTAssertEqual(s.transcriber.calls.count, 1)                                     // the kept transcript was used
        XCTAssertEqual(s.cutter.calls.count, 8 + 20)                                     // the retry cuts every frame again (the first group's 8 twice)
        XCTAssertEqual(s.jpegsLeft, [])
        XCTAssertEqual(try s.frameRows().count, 20)
    }

    // (8) Frames that cannot be read: the transcript still indexes, with a note.
    func testEveryFrameUnreadableWithATranscriptIndexesWithANote() throws {
        let s = try Setup()
        s.cutter.written = { _ in false }
        XCTAssertEqual(s.index(), .indexed)
        let record = try XCTUnwrap(s.store.fileRecord(path: s.video.path))
        XCTAssertEqual(record.status, "indexed")
        XCTAssertTrue(record.note.contains("no frames could be read"), record.note)
        XCTAssertFalse(record.note.contains("frames skipped"), record.note)
        XCTAssertEqual(try s.frameRows().count, 0)
        XCTAssertEqual(try s.store.counts().segmentsByModality["text"], 1)
        XCTAssertEqual(s.embedder.callCount(.image), 0)
    }

    func testOneUnreadableFrameSkipsOnlyThatFrame() throws {
        let s = try Setup()
        s.cutter.written = { Int($0 / 5) % 2 == 0 }
        XCTAssertEqual(s.index(), .indexed)
        XCTAssertEqual(try s.frameRows().count, 10)
        XCTAssertFalse(try XCTUnwrap(s.store.fileRecord(path: s.video.path)).note.contains("no frames"))
    }

    func testASilentVideoIsIndexedByItsFramesAlone() throws {
        let s = try Setup(sound: false)
        XCTAssertEqual(s.index(), .indexed)                                              // no audio window ran first to make the run folder
        XCTAssertEqual(try s.frameRows().count, 20)
        XCTAssertEqual(try s.store.fileRecord(path: s.video.path)?.note, "silent soundtrack")
        XCTAssertEqual(s.jpegsLeft, [])
    }

    func testNoFramesAndNoSoundIsSkipped() throws {
        let s = try Setup(sound: false)
        s.cutter.written = { _ in false }
        XCTAssertEqual(s.index(), .skipped("no usable frames or sound"))
        XCTAssertEqual(try s.store.fileRecord(path: s.video.path)?.status, "skipped")
        XCTAssertTrue(s.transcriber.calls.isEmpty)
    }

    // (9) Frames are stored as `frame` rows (no text, timed anchors) of a `video` file.
    func testFramesAreStoredAsFrameRowsOfAVideo() throws {
        let s = try Setup()
        XCTAssertEqual(s.index(), .indexed)
        let counts = try s.store.counts()
        XCTAssertEqual(counts.filesByKind, ["video": 1])
        XCTAssertEqual(counts.segmentsByModality["frame"], 20)
        XCTAssertNil(counts.segmentsByModality["image"])
        let rows = try s.frameRows()
        XCTAssertTrue(rows.allSatisfy { $0.text.isEmpty })
        XCTAssertEqual(rows.last?.anchor, #"{"t0":95,"t1":100}"#)
        XCTAssertEqual(s.cutter.maxSides, [ImagePrep.embedMaxSide])
        XCTAssertEqual(try s.store.fileRecord(path: s.video.path)?.kind, "video")
    }

    // (10) A 720-frame video never has more than one group of 8 frames on disk.
    func testAtMostEightFramesAreOnDiskAtOnce() throws {
        let s = try Setup(duration: 3600)
        XCTAssertEqual(s.index(), .indexed)
        XCTAssertEqual(s.cutter.calls.count, 720)
        XCTAssertEqual(s.cutter.peakOutstanding, 8)
        XCTAssertTrue(s.embedder.calls.filter { $0.0 == .image }.allSatisfy { $0.2.count <= 8 })
        XCTAssertEqual(s.jpegsLeft, [])
    }

    // MARK: wiring

    /// Ruling 2: the soundtrack of a video between 2 and 8 GB is not refused by the audio part.
    func testTheIndexersVideoReaderAcceptsAThreeGigabyteFile() throws {
        let url = TestSupport.tempDir("bigvideo").appendingPathComponent("big.mp4")
        FileManager.default.createFile(atPath: url.path, contents: Data(count: 10))
        let h = try FileHandle(forWritingTo: url); try h.truncate(atOffset: 3_000_000_000); try h.close()   // sparse: no real disk use
        let t = FakeTranscriber(); t.segments = [TranscriptSegment(start: 1, end: 5, text: "a long recorded lecture")]
        let readers = Indexer.makeReaders(ocr: { _ in "" }, transcriber: t, shouldContinue: { true },
                                          audioProbe: fakeProbe(duration: 61), videoProbe: fakeVideoProbe(duration: 61))
        let result = try XCTUnwrap(readers["video"]).read(url)
        XCTAssertTrue(result.segments.contains { $0.modality == "text" })
        XCTAssertEqual(t.calls.count, 1)
        XCTAssertNil(Indexer.makeReaders(ocr: { _ in "" }, transcriber: nil, shouldContinue: { true })["video"])
    }

    /// Ruling 3: a Photos video path detects as "video" but is triaged as an asset first: skipped as before, in a process
    /// with or without the speech model, and never read, cut or loaded.
    func testAPhotosVideoStaysSkippedAndNeverReachesTheVideoReader() throws {
        for unavailable in [Set<String>(), ["audio", "video"]] {
            let dir = TestSupport.tempDir("photosvideo")
            let store = try Store.open(path: dir.appendingPathComponent("index.db").path, key: TestSupport.key, dim: FakeEmbedder.dim)
            let assets = FakeAssetProvider()
            let path = assets.add("v1", filename: "clip.mov", width: 10, video: true)
            XCTAssertEqual(Kinds.detect(path), "video")
            let spy = SpyReader(), cutter = FakeFrameCutter()
            let indexer = Indexer(store: store, embedder: FakeEmbedder(), workDir: dir.appendingPathComponent("work"),
                                  ocr: { _ in "" }, assets: assets, enabledKinds: { Kinds.defaultEnabled.union(["video"]) },
                                  unavailableKinds: { unavailable }, readers: ["video": spy], frameCutter: cutter)
            XCTAssertEqual(indexer.index(paths: [path]), [path: .skipped(AssetNotes.video)], "\(unavailable)")
            XCTAssertEqual(spy.calls, 0); XCTAssertTrue(cutter.calls.isEmpty); XCTAssertTrue(assets.loads.isEmpty)
            let record = try XCTUnwrap(store.fileRecord(path: path))
            XCTAssertEqual([record.kind, record.status, record.note], ["video", "skipped", AssetNotes.video])
        }
    }
}

/// Video through the whole engine: what a process without a usable speech model may and may not do.
final class VideoEngineTests: XCTestCase {
    let on = Kinds.defaultEnabled.union(["audio", "video"])
    let segments = [TranscriptSegment(start: 0.5, end: 2.5, text: "the architecture review is on friday")]

    func folderWithVideo() throws -> URL {
        let folder = TestSupport.tempDir("films")
        try FileManager.default.copyItem(at: VideoFixtures.mp4(scenes: [(1.5, (0, 90, 200)), (1.5, (240, 240, 20))], sine: true),
                                         to: folder.appendingPathComponent("talk.mp4"))
        try makeImage(width: 300, height: 100, text: nil, at: folder.appendingPathComponent("p.png"))
        return folder
    }

    func makeEngine(home: URL, transcriber: Transcriber?) throws -> Engine {
        try Engine(paths: Paths(home: home), config: Config(kinds: on), keyProvider: StaticKeyProvider(TestSupport.key),
                   embedder: FakeEmbedder(), ocr: { _ in "" }, transcriber: transcriber)
    }

    // (6) The CLI (no transcriber) on the app's home never queues, purges or claims video.
    func testAProcessWithoutATranscriberNeverQueuesPurgesOrClaimsVideo() throws {
        let home = TestSupport.tempDir("home")
        let t = FakeTranscriber(); t.segments = segments
        let app = try makeEngine(home: home, transcriber: t)
        let folder = try folderWithVideo()
        let video = RealPath.of(folder.appendingPathComponent("talk.mp4").path)
        try app.addFolder(folder.path)
        _ = try app.scan(); try app.runIndexing()
        XCTAssertEqual(try app.status().counts.filesByKind["video"], 1)

        let cli = try makeEngine(home: home, transcriber: nil)
        try cli.addFolder(folder.path)                                                   // the CLI scans the same folder
        XCTAssertEqual(try cli.scan().purgeQueued, 0)                                    // crawler guard
        XCTAssertEqual(try cli.enqueue(files: [video]), 0)
        try cli.runIndexing()
        XCTAssertEqual(try cli.status().counts.filesByKind["video"], 1)
        // A job the app queued for a really changed video is not eaten by the CLI (triage guard).
        let changed = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: changed], ofItemAtPath: video)
        XCTAssertEqual(try app.scan().enqueued, 1)
        try cli.runIndexing()
        XCTAssertEqual(try cli.queue.counts().queued, 1)                                 // never claimed (claim filter)
        XCTAssertEqual(try cli.status().counts.filesByKind["video"], 1)
        XCTAssertEqual(try cli.store.fileRecord(path: video)?.status, "indexed")
        XCTAssertNotEqual(try cli.store.fileRecord(path: video)?.mtime, Int64(changed.timeIntervalSince1970))   // the CLI did not take it on
        try app.runIndexing()                                                            // no rescan needed: the job is still there
        XCTAssertEqual(try app.status().counts.filesByKind["video"], 1)
        XCTAssertEqual(try app.store.fileRecord(path: video)?.mtime, Int64(changed.timeIntervalSince1970))      // the owner did
    }

    // (7) A speech model that is not there queues no video, does not pause the run, and images still index.
    func testAMissingModelQueuesNoVideoAndImagesStillIndex() throws {
        let t = FakeTranscriber(); t.segments = segments; t.isAvailable = false
        let e = try makeEngine(home: TestSupport.tempDir("home"), transcriber: t)
        let folder = try folderWithVideo()
        try e.addFolder(folder.path)
        XCTAssertEqual(try e.scan().enqueued, 1)                                         // only the png
        XCTAssertEqual(try e.enqueue(files: [folder.appendingPathComponent("talk.mp4").path]), 0)
        let summary = try e.runIndexing()
        XCTAssertNil(summary.pausedReason); XCTAssertEqual(summary.deferred, 0)
        XCTAssertEqual(try e.status().counts.filesByKind, ["image": 1])
        XCTAssertTrue(t.calls.isEmpty)
        t.isAvailable = true                                                             // the model shows up
        XCTAssertEqual(try e.scan().enqueued, 1)
        try e.runIndexing()
        XCTAssertEqual(try e.status().counts.filesByKind, ["image": 1, "video": 1])
    }
}
