import AVFoundation
import XCTest
@testable import ThatOneCore

/// What the M4 final review found: each test failed before its fix.
final class M4FinalFixTests: XCTestCase {
    let on = Kinds.defaultEnabled.union(["audio", "video"])
    let speech = [TranscriptSegment(start: 0.5, end: 2.5, text: "the architecture review is on friday")]

    func folderWithVideo() throws -> URL {
        let folder = TestSupport.tempDir("films")
        try FileManager.default.copyItem(at: VideoFixtures.mp4(scenes: [(1.5, (0, 90, 200)), (1.5, (240, 240, 20))], sine: true),
                                         to: folder.appendingPathComponent("talk.mp4"))
        try makeImage(width: 300, height: 100, text: nil, at: folder.appendingPathComponent("p.png"))
        return folder
    }

    func makeEngine(home: URL, transcriber: Transcriber?, cutter: FrameCutting = FakeFrameCutter()) throws -> Engine {
        try Engine(paths: Paths(home: home), config: Config(kinds: on), keyProvider: StaticKeyProvider(TestSupport.key),
                   embedder: FakeEmbedder(), ocr: { _ in "" }, transcriber: transcriber, frameCutter: cutter)
    }

    // MARK: I1 the CLI never claims app-owned jobs

    func testClaimSkipsPathsWithTheGivenExtensions() throws {
        let store = try Store.open(path: TestSupport.tempDir("q").appendingPathComponent("a.db").path, key: TestSupport.key, dim: 4)
        let queue = JobQueue(store: store)
        let paths = ["/a/talk.mp4", "/a/LOUD.MOV", "/a/memo.wav", "/a/p.png", "/a/noext", "/a/mp4", "/a/x.mp4.png",
                     "photos:abc/clip.mov", "/a/.mp4", "/a/y.mx4", "/a/z.m_4"]
        for p in paths { try queue.enqueue(path: p, priority: 1) }
        let claimed = Set(try queue.claim(limit: 100, skippingExtensions: ["mp4", "mov", "wav", "m_4"]))
        // A Photos path is triaged as an asset (never read as a file), a hidden ".mp4" has no extension, and "_" in an
        // extension is a literal, not a LIKE wildcard.
        XCTAssertEqual(claimed, ["/a/p.png", "/a/noext", "/a/mp4", "/a/x.mp4.png", "photos:abc/clip.mov", "/a/.mp4", "/a/y.mx4"])
        XCTAssertEqual(try queue.counts().queued, 4)                                        // the skipped ones stay queued
        XCTAssertEqual(Set(try queue.claim(limit: 100)), ["/a/talk.mp4", "/a/LOUD.MOV", "/a/memo.wav", "/a/z.m_4"])
    }

    func testTheCLILeavesAJobForAChangedVideoQueuedForTheApp() throws {
        let home = TestSupport.tempDir("home")
        let t = FakeTranscriber(); t.segments = speech
        let app = try makeEngine(home: home, transcriber: t)
        let folder = try folderWithVideo()
        let video = RealPath.of(folder.appendingPathComponent("talk.mp4").path)
        try app.addFolder(folder.path)
        _ = try app.scan(); try app.runIndexing()
        XCTAssertEqual(try app.status().counts.filesByKind["video"], 1)

        let cli = try makeEngine(home: home, transcriber: nil)
        try cli.addFolder(folder.path)
        let changed = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: changed], ofItemAtPath: video)
        XCTAssertEqual(try app.scan().enqueued, 1)                                       // the app's watcher queued it
        try cli.runIndexing()                                                            // a long CLI run holds the lock
        XCTAssertEqual(try cli.queue.counts().queued, 1)                                 // not claimed, not eaten
        try app.runIndexing()                                                            // the app's retry, without a scan
        XCTAssertEqual(try app.store.fileRecord(path: video)?.mtime, Int64(changed.timeIntervalSince1970))
        XCTAssertEqual(try app.queue.counts().queued, 0)
    }

    /// A job this process may not claim is not a pending retry either: the app would otherwise wake every minute for it.
    func testAJobLeftForTheOwnerIsNotCountedAsARetryPending() throws {
        let e = try makeEngine(home: TestSupport.tempDir("home"), transcriber: nil)
        try e.queue.enqueue(path: "/gone/talk.mp4", priority: Int64.min)                 // the watcher saw a video deleted
        let summary = try e.runIndexing()
        XCTAssertEqual(summary.retryPending, 0)
        XCTAssertEqual(try e.queue.counts().queued, 1)                                   // still there for the app
    }

    /// The second layer: a job for a kind this process cannot read that is claimed anyway is left alone (no purge).
    func testTriageLeavesAnUnavailableKindAlone() throws {
        let dir = TestSupport.tempDir("triage")
        let store = try Store.open(path: dir.appendingPathComponent("index.db").path, key: TestSupport.key, dim: FakeEmbedder.dim)
        let video = VideoIndexTests.clip
        let id = try store.addContent(hash: "v", kind: "video", status: "indexed",
                                      segments: [SegmentInput(modality: "text", text: "kept", vector: oneHot(1))])
        try store.upsertFile(path: video.path, contentId: id, kind: "video", size: 1, mtime: 1, status: "indexed")
        let indexer = Indexer(store: store, embedder: FakeEmbedder(), workDir: dir.appendingPathComponent("work"),
                              ocr: { _ in "" }, enabledKinds: { Kinds.defaultEnabled }, unavailableKinds: { ["audio", "video"] })
        XCTAssertEqual(indexer.index(paths: [video.path]), [video.path: .unchanged])
        XCTAssertEqual(try store.fileRecord(path: video.path)?.status, "indexed")
        XCTAssertEqual(try store.fileRecord(path: video.path)?.contentId, id)
    }

    // MARK: I2 frames do not crowd the pooled vector search

    private func add(_ s: Store, hash: String, path: String, kind: String, modality: String, vectors: [[Float]]) throws {
        let id = try s.addContent(hash: hash, kind: kind, status: "indexed",
                                  segments: vectors.map { SegmentInput(modality: modality, text: "", vector: $0) })
        try s.upsertFile(path: path, contentId: id, kind: kind, size: 1, mtime: 1, status: "indexed")
    }

    /// A unit vector at `degrees` from the query axis (e0), leaning into dims chosen by `seed` so each one is distinct.
    private func at(_ degrees: Double, seed: Int) -> [Float] {
        var v = [Float](repeating: 0, count: FakeEmbedder.dim)
        let a = degrees * .pi / 180, b = Double(seed) * 0.37
        v[0] = Float(cos(a))
        v[1 + seed % 7] += Float(sin(a) * cos(b))
        v[8 + seed % 7] += Float(sin(a) * sin(b))
        return v
    }

    /// Two hour-long screen recordings (300 distinct frames each) and 20 images. `closer`: how many frames of each video
    /// are nearer the query than every image.
    private func crowdedStore(closer: Int) throws -> Store {
        let s = try Store.open(path: TestSupport.tempDir("crowd").appendingPathComponent("a.db").path, key: TestSupport.key, dim: FakeEmbedder.dim)
        for video in 0..<2 {
            let frames = (0..<300).map { i in at(i < closer ? 5 + Double(i) * 0.06 : 40 + Double(i) * 0.1, seed: i + video * 300) }
            try add(s, hash: "v\(video)", path: "/rec/screen\(video).mov", kind: "video", modality: "frame", vectors: frames)
        }
        for j in 0..<20 {
            var v = [Float](repeating: 0, count: FakeEmbedder.dim)
            let a = (30 + Double(j) * 0.1) * .pi / 180
            v[0] = Float(cos(a)); v[15] = Float(sin(a))
            try add(s, hash: "i\(j)", path: "/pics/\(j).png", kind: "image", modality: "image", vectors: [v])
        }
        return s
    }

    func testFramesOfLongVideosDoNotPushImagesOutOfAll() throws {
        let s = try crowdedStore(closer: 150)                                            // 300 frames beat every image
        let hits = try Searcher(store: s).search(query: "", queryVector: oneHot(0), limit: 10)
        XCTAssertTrue(hits.contains { $0.kind == "image" }, "\(hits.map(\.kind))")
        XCTAssertEqual(hits.filter { $0.kind == "video" }.count, 2)
        XCTAssertTrue(hits.allSatisfy { $0.anchors.count <= Searcher.maxAnchors })
    }

    func testFramesOfLongVideosDoNotEmptyTheImagesFilter() throws {
        let s = try crowdedStore(closer: 300)                                            // all 600 frames beat every image
        let hits = try Searcher(store: s).search(query: "", queryVector: oneHot(0), filters: SearchFilters(kinds: ["image"]), limit: 10)
        XCTAssertEqual(hits.count, 10, "\(hits.map(\.kind))")
        XCTAssertTrue(hits.allSatisfy { $0.kind == "image" })
    }

    // MARK: I3 transient decoder errors defer the file

    func testTransientAVFoundationErrorsAreEnvironmentErrors() {
        for code in [-11819, -11839, -11847] {
            XCTAssertTrue(AVFrameCutter.isEnvironmentError(NSError(domain: AVFoundationErrorDomain, code: code)), "\(code)")
        }
        XCTAssertFalse(AVFrameCutter.isEnvironmentError(NSError(domain: AVFoundationErrorDomain, code: -11800)))
        XCTAssertFalse(AVFrameCutter.isEnvironmentError(NSError(domain: AVFoundationErrorDomain, code: -11829)))
        XCTAssertFalse(AVFrameCutter.isEnvironmentError(NSError(domain: NSOSStatusErrorDomain, code: -11839)))
    }

    func testADecoderTemporarilyUnavailableDefersTheVideo() throws {
        let s = try VideoIndexTests.Setup()
        s.cutter.failure = { $0 > 50 ? FrameCutError.mediaServices("\(NSError(domain: AVFoundationErrorDomain, code: -11839))") : nil }
        guard case .deferred(let why) = s.index() else { return XCTFail("expected a deferral") }
        XCTAssertTrue(why.hasPrefix(Indexer.frameCuttingUnavailable), why)
        XCTAssertNil(try s.store.fileRecord(path: s.video.path))                         // not stored as "no frames could be read"
        XCTAssertEqual(s.jpegsLeft, [])
    }

    // MARK: I4 frame-cutting deferrals are bounded

    func testAFileWhoseFramesCannotBeCutFailsOnItsFifthDeferral() throws {
        let t = FakeTranscriber(); t.segments = speech
        let cutter = FakeFrameCutter(); cutter.failure = { _ in FrameCutError.cannotWrite("finalize failed") }
        let e = try makeEngine(home: TestSupport.tempDir("home"), transcriber: t, cutter: cutter)
        let folder = try folderWithVideo()
        let video = RealPath.of(folder.appendingPathComponent("talk.mp4").path)
        try e.addFolder(folder.path)
        _ = try e.scan()
        func run() throws -> IndexingSummary {
            let summary = try e.runIndexing()
            try e.store.run("update jobs set next_attempt = 0")                          // the 10-minute wait, skipped
            return summary
        }
        XCTAssertEqual(try run().indexed, 1)                                             // the png
        for n in 2...4 { XCTAssertEqual(try run().deferred, 1, "run \(n)") }
        let fifth = try run()
        XCTAssertEqual(fifth.deferred, 0)
        XCTAssertEqual(fifth.failed, 1)
        XCTAssertEqual(try e.store.fileRecord(path: video)?.status, "failed")
        let note = try XCTUnwrap(e.status().failedFiles.first { $0.path == video }).note
        XCTAssertTrue(note.hasPrefix("frame cutting failed repeatedly: frame cutting unavailable"), note)
    }

    func testAnotherOutcomeResetsTheDeferralCount() throws {
        let t = FakeTranscriber(); t.segments = speech
        let cutter = FakeFrameCutter()
        var failing = true
        cutter.failure = { _ in failing ? FrameCutError.cannotWrite("finalize failed") : nil }
        let e = try makeEngine(home: TestSupport.tempDir("home"), transcriber: t, cutter: cutter)
        let folder = try folderWithVideo()
        let video = RealPath.of(folder.appendingPathComponent("talk.mp4").path)
        try e.addFolder(folder.path)
        _ = try e.scan()
        func run() throws -> IndexingSummary {
            let summary = try e.runIndexing()
            try e.store.run("update jobs set next_attempt = 0")
            return summary
        }
        for _ in 0..<4 { _ = try run() }                                                 // png indexed, 4 deferrals
        failing = false
        XCTAssertEqual(try run().indexed, 1)                                             // the video, at last
        failing = true
        try FileManager.default.removeItem(atPath: video)                                // new bytes: not linked by hash
        try FileManager.default.copyItem(at: VideoFixtures.mp4(scenes: [(2, (30, 200, 30))], sine: true, name: "edited.mp4"),
                                         to: URL(fileURLWithPath: video))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: video)
        XCTAssertEqual(try e.scan().enqueued, 1)
        for n in 1...4 { XCTAssertEqual(try run().deferred, 1, "run \(n)") }            // counted afresh
    }

    func testTheDeferralCounterRemembersAtMost256FilesDroppingTheOldest() {
        let d = FrameDeferrals()
        for i in 0..<300 { _ = d.note("/v/\(i).mp4") }
        XCTAssertEqual(d.count, 256)
        XCTAssertEqual(d.note("/v/299.mp4"), 2)
        XCTAssertEqual(d.note("/v/0.mp4"), 1)                                            // dropped, counted afresh
    }

    // MARK: minor items

    func testAZeroLengthVideoIsEmptyNotFailed() throws {
        let url = TestSupport.tempDir("zero").appendingPathComponent("placeholder.mp4")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        var probed = false
        let reader = VideoReader(audio: AudioReader(transcriber: FakeTranscriber(), probe: fakeProbe(duration: 61)),
                                 probe: VideoProbe(info: { _ in probed = true; return VideoInfo(duration: 61, hasVideoTrack: true) }))
        XCTAssertThrowsError(try reader.read(url)) { XCTAssertEqual($0 as? ReadFailure, .empty("no video")) }
        XCTAssertFalse(probed)
    }

    func testTheSoundtracksGateTextReachesTheResult() throws {
        struct Sound: FileReader {
            func read(_ url: URL) throws -> ReadResult {
                ReadResult(segments: [ReadSegment(modality: "text", anchor: "{}", text: "hello")], gateText: "beyond the cut")
            }
        }
        let url = TestSupport.tempDir("gate").appendingPathComponent("v.mp4")
        FileManager.default.createFile(atPath: url.path, contents: Data(count: 10))
        let result = try VideoReader(audio: Sound(), probe: fakeVideoProbe(duration: 12)).read(url)
        XCTAssertEqual(result.gateText, "beyond the cut")
    }

    func testANonFiniteDurationPlansNoFrames() {
        XCTAssertEqual(FrameSchedule.plan(duration: .infinity).times, [])
        XCTAssertEqual(FrameSchedule.plan(duration: .nan).times, [])
    }

    func testTheVectorOfAVideoIsAFrameEvenWhenTheSoundtrackCameFirst() throws {
        let s = try Store.open(path: TestSupport.tempDir("vec").appendingPathComponent("a.db").path, key: TestSupport.key, dim: FakeEmbedder.dim)
        let id = try s.addContent(hash: "v", kind: "video", status: "indexed", segments: [
            SegmentInput(modality: "audio", text: "", vector: oneHot(1)),
            SegmentInput(modality: "text", text: "words", vector: oneHot(2)),
            SegmentInput(modality: "frame", text: "", vector: oneHot(3)),
        ])
        XCTAssertEqual(try Searcher(store: s).vector(ofContent: id), oneHot(3))
    }

    func testSwitchingVideoOffStopsTheFrameLoop() throws {
        let s = try VideoIndexTests.Setup()
        s.cutter.onCut = { time in if time > 35 { s.kinds = [] } }                       // the 8th cut (37.5 s) ends the first group
        XCTAssertEqual(s.index(), .removed)
        XCTAssertEqual(s.cutter.calls.count, 8)
        XCTAssertEqual(s.jpegsLeft, [])
        XCTAssertNil(try s.store.fileRecord(path: s.video.path))
    }

    func testRetryFailedResetsTheFrameCuttersBreaker() throws {
        final class Counting: FrameCutting {
            var resets = 0
            func cut(source: URL, time: Double, maxSide: Int, to destination: URL) throws -> Bool { false }
            func resetBreaker() { resets += 1 }
        }
        let cutter = Counting()
        let e = try makeEngine(home: TestSupport.tempDir("home"), transcriber: nil, cutter: cutter)
        try e.retryFailed()
        XCTAssertEqual(cutter.resets, 1)
    }
}
