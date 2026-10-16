import AVFoundation
import CoreGraphics
import ImageIO
import XCTest
@testable import ThatOneCore

/// The real cutter and probe on tiny generated clips (real AVFoundation, no models).
final class AVFrameCutterTests: XCTestCase {
    static let scenes: [VideoFixtures.Scene] = [(1, (200, 40, 40)), (1, (40, 180, 60)), (1, (40, 60, 200))]
    static let threeScenes = VideoFixtures.mp4(scenes: scenes, sine: false, name: "scenes.mp4", marker: true)

    private func out(_ name: String = "f.jpg") -> URL { TestSupport.tempDir("cut").appendingPathComponent(name) }

    private func image(at url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// The centre pixel as RGB, drawn into an sRGB context.
    private func centre(_ image: CGImage) -> (Int, Int, Int) {
        var px = [UInt8](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .none
            let w = CGFloat(image.width), h = CGFloat(image.height)
            ctx.draw(image, in: CGRect(x: -w / 2 + 0.5, y: -h / 2 + 0.5, width: w, height: h))
        }
        return (Int(px[0]), Int(px[1]), Int(px[2]))
    }

    private func assertColour(_ got: (Int, Int, Int), _ want: (UInt8, UInt8, UInt8), file: StaticString = #filePath, line: UInt = #line) {
        let ok = abs(got.0 - Int(want.0)) <= 12 && abs(got.1 - Int(want.1)) <= 12 && abs(got.2 - Int(want.2)) <= 12
        XCTAssertTrue(ok, "got \(got), want \(want)", file: file, line: line)
    }

    // MARK: cutter

    func testEachSceneIsCutAtItsMidpointWithItsColour() throws {
        let cutter = AVFrameCutter()
        for (i, scene) in Self.scenes.enumerated() {
            let url = out("s\(i).jpg")
            XCTAssertTrue(try cutter.cut(source: Self.threeScenes, time: Double(i) + 0.5, maxSide: 1024, to: url))
            let picture = try image(at: url)
            XCTAssertEqual([picture.width, picture.height], [64, 48])                   // upright, never scaled up
            assertColour(centre(picture), scene.rgb)
        }
    }

    func testARotatedClipIsCutUpright() throws {
        let clip = VideoFixtures.mp4(scenes: [(1, (40, 180, 60))], sine: false, name: "turned.mp4",
                                     transform: CGAffineTransform(rotationAngle: .pi / 2), marker: true)
        let url = out()
        XCTAssertTrue(try AVFrameCutter().cut(source: clip, time: 0.5, maxSide: 1024, to: url))
        let picture = try image(at: url)
        XCTAssertEqual([picture.width, picture.height], [48, 64])
    }

    func testTheLongSideIsCappedAtMaxSide() throws {
        let url = out()
        XCTAssertTrue(try AVFrameCutter().cut(source: Self.threeScenes, time: 0.5, maxSide: 32, to: url))
        let picture = try image(at: url)
        XCTAssertEqual(max(picture.width, picture.height), 32)
    }

    func testABlackFrameIsBlankAndWritesNothing() throws {
        let clip = VideoFixtures.mp4(scenes: [(1, (0, 0, 0))], sine: false, name: "black.mp4")
        let url = out()
        XCTAssertFalse(try AVFrameCutter().cut(source: clip, time: 0.5, maxSide: 1024, to: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testBlankCheckUsesTheSpreadLimit() throws {
        func flat(_ grey: CGFloat, stripe: CGFloat?) -> CGImage {
            let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.setFillColor(gray: grey, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            if let stripe { ctx.setFillColor(gray: stripe, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 48)) }
            return ctx.makeImage()!
        }
        XCTAssertTrue(AVFrameCutter.isBlank(flat(0.5, stripe: nil)))
        XCTAssertTrue(AVFrameCutter.isBlank(flat(0.5, stripe: 0.5 + 2 / 255)))            // a spread of 2 <= 3
        XCTAssertFalse(AVFrameCutter.isBlank(flat(0.5, stripe: 0.5 + 10 / 255)))
    }

    func testATimePastTheEndIsFalse() throws {
        let url = out()
        XCTAssertFalse(try AVFrameCutter().cut(source: Self.threeScenes, time: 30, maxSide: 1024, to: url))
        XCTAssertFalse(try AVFrameCutter().cut(source: Self.threeScenes, time: 3.4, maxSide: 1024, to: url))   // within the 1 s tolerance
        XCTAssertFalse(try AVFrameCutter().cut(source: Self.threeScenes, time: -1, maxSide: 1024, to: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAFrameThatTakesTooLongIsSkipped() throws {
        let url = out()
        let start = Date()
        XCTAssertFalse(try AVFrameCutter(timeout: 0).cut(source: Self.threeScenes, time: 0.5, maxSide: 1024, to: url))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // A file whose decoder stalls: the first timeout skips that frame, the second fails the file, and every later cut
    // of that file throws at once without starting another generation. Other files are not affected.
    func testAStalledFileTripsTheBreakerAfterTwoTimeouts() throws {
        let cutter = AVFrameCutter(timeout: 0)
        let start = Date()
        var outcomes: [String] = []
        for k in 0..<10 {
            do { outcomes.append(try cutter.cut(source: Self.threeScenes, time: 0.1 + Double(k) * 0.25, maxSide: 1024, to: out()) ? "true" : "false") }
            catch ReadFailure.timedOut { outcomes.append("timedOut") }
        }
        XCTAssertEqual(outcomes, ["false"] + Array(repeating: "timedOut", count: 9))
        XCTAssertEqual(cutter.generationsStarted, 2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        let other = VideoFixtures.mp4(scenes: [(1, (40, 180, 60))], sine: false, name: "other.mp4", marker: true)
        XCTAssertFalse(try cutter.cut(source: other, time: 0.5, maxSide: 1024, to: out()))          // its own first timeout
        XCTAssertEqual(cutter.generationsStarted, 3)
        cutter.resetBreaker()
        XCTAssertFalse(try cutter.cut(source: Self.threeScenes, time: 0.5, maxSide: 1024, to: out()))
        XCTAssertEqual(cutter.generationsStarted, 4)
    }

    func testTheBreakerRemembersAtMost64Files() throws {
        let cutter = AVFrameCutter(timeout: 0)
        for i in 0..<70 { cutter.noteTimeout(path: "/x/\(i).mp4") }
        XCTAssertEqual(cutter.breakerCount, 64)
    }

    func testAMediaServicesResetIsAnEnvironmentError() {
        XCTAssertTrue(AVFrameCutter.isEnvironmentError(NSError(domain: AVFoundationErrorDomain, code: -11819)))
        XCTAssertFalse(AVFrameCutter.isEnvironmentError(NSError(domain: AVFoundationErrorDomain, code: -11800)))
        XCTAssertFalse(AVFrameCutter.isEnvironmentError(NSError(domain: NSOSStatusErrorDomain, code: -11819)))
    }

    func testAFailedJPEGWriteIsAnEnvironmentErrorNotAFileError() {
        let blocker = TestSupport.tempDir("cut").appendingPathComponent("a-file")
        FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))
        let url = blocker.appendingPathComponent("f.jpg")                                   // its parent is a file: cannot write
        XCTAssertThrowsError(try AVFrameCutter().cut(source: Self.threeScenes, time: 0.5, maxSide: 1024, to: url)) { error in
            XCTAssertFalse(error is ReadFailure, "\(error)")
            XCTAssertFalse(error is ImagePrepError, "\(error)")
            XCTAssertTrue(error is FrameCutError, "\(error)")
        }
    }

    func testARandomBytesFileIsNotCutAndDoesNotHang() throws {
        let junk = TestSupport.tempDir("cut").appendingPathComponent("junk.mp4")
        var bytes = [UInt8](repeating: 0, count: 4096)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        FileManager.default.createFile(atPath: junk.path, contents: Data(bytes))
        let start = Date()
        do { let made = try AVFrameCutter().cut(source: junk, time: 0.5, maxSide: 1024, to: out()); XCTAssertFalse(made) }
        catch { XCTAssertTrue(error is ReadFailure, "\(error)") }                          // a file problem, never an environment one
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    // MARK: through the reader and the indexer (real probe, real cutter, fake speech and embedder)

    private func indexer(_ dir: URL, store: Store, transcriber: FakeTranscriber) -> Indexer {
        let audio = AudioReader(transcriber: transcriber, maxBytes: ReadLimits.maxVideoBytes)
        return Indexer(store: store, embedder: FakeEmbedder(), workDir: dir.appendingPathComponent("work"), exclusions: Exclusions(),
                       roots: { [] }, ocr: { _ in "" }, enabledKinds: { ["video"] },
                       readers: ["video": VideoReader(audio: audio, probe: .system)], frameCutter: AVFrameCutter())
    }

    // Through the indexer: a stalled file fails as "reading took too long" after two generations, in bounded time.
    func testAStalledFileFailsAsReadingTookTooLong() throws {
        let dir = TestSupport.tempDir("stalled")
        let store = try Store.open(path: dir.appendingPathComponent("index.db").path, key: TestSupport.key, dim: FakeEmbedder.dim)
        let cutter = AVFrameCutter(timeout: 0)
        let t = FakeTranscriber(); t.segments = [TranscriptSegment(start: 0.2, end: 1.0, text: "a short line")]
        let audio = AudioReader(transcriber: t, probe: fakeProbe(duration: 2), maxBytes: ReadLimits.maxVideoBytes)
        let indexer = Indexer(store: store, embedder: FakeEmbedder(), workDir: dir.appendingPathComponent("work"), exclusions: Exclusions(),
                              roots: { [] }, ocr: { _ in "" }, enabledKinds: { ["video"] },
                              readers: ["video": VideoReader(audio: audio, probe: fakeVideoProbe(duration: 3600))], frameCutter: cutter)
        let start = Date()
        let clip = VideoIndexTests.clip                                                         // 2 s with a soundtrack
        let outcome = indexer.index(paths: [clip.path])[clip.path]
        XCTAssertEqual(outcome, .failed("reading took too long"))
        XCTAssertEqual(cutter.generationsStarted, 2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        let work = dir.appendingPathComponent("work")
        let left = (FileManager.default.enumerator(atPath: work.path)?.compactMap { $0 as? String } ?? []).filter { $0.hasSuffix(".jpg") }
        XCTAssertEqual(left, [], "no JPEG left in the run folder")
    }

    func testACorruptFileFailsWithCannotReadThisVideo() throws {
        let dir = TestSupport.tempDir("corrupt")
        let store = try Store.open(path: dir.appendingPathComponent("index.db").path, key: TestSupport.key, dim: FakeEmbedder.dim)
        let junk = dir.appendingPathComponent("junk.mp4")
        var bytes = [UInt8](repeating: 0, count: 8192)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        FileManager.default.createFile(atPath: junk.path, contents: Data(bytes))
        XCTAssertThrowsError(try VideoProbe.system.info(junk))
        let outcome = indexer(dir, store: store, transcriber: FakeTranscriber()).index(paths: [junk.path])[junk.path]
        guard case .failed(let why) = outcome else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertTrue(why.contains("cannot read this video"), why)
        XCTAssertEqual(try store.fileRecord(path: junk.path)?.status, "failed")
    }

    func testATruncatedClipIsReadOrFailsCleanlyInBoundedTime() throws {
        let dir = TestSupport.tempDir("truncated")
        let store = try Store.open(path: dir.appendingPathComponent("index.db").path, key: TestSupport.key, dim: FakeEmbedder.dim)
        let whole = try Data(contentsOf: VideoFixtures.mp4(scenes: [(1.5, (200, 40, 40)), (1.5, (40, 60, 200))], sine: true, name: "whole.mp4"))
        let cut = dir.appendingPathComponent("cut.mp4")
        try whole.prefix(whole.count * 40 / 100).write(to: cut)
        let t = FakeTranscriber(); t.segments = [TranscriptSegment(start: 0.2, end: 1.0, text: "a short line")]
        let start = Date()
        let outcome = indexer(dir, store: store, transcriber: t).index(paths: [cut.path])[cut.path]
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        switch outcome {
        case .indexed?, .skipped?, .failed?: break
        default: XCTFail("\(String(describing: outcome))")
        }
        XCTAssertNotNil(try store.fileRecord(path: cut.path))
        let left = (FileManager.default.enumerator(atPath: dir.appendingPathComponent("work").path)?.allObjects as? [String] ?? [])
        XCTAssertEqual(left.filter { $0.hasSuffix(".jpg") }, [])
    }

    func testAVideoWithoutASoundtrackKeepsItsFrames() throws {
        let clip = VideoFixtures.mp4(scenes: [(1, (200, 40, 40)), (1, (40, 60, 200))], sine: false, name: "mute.mp4", marker: true)
        let t = FakeTranscriber()
        let reader = VideoReader(audio: AudioReader(transcriber: t, probe: .system, maxBytes: ReadLimits.maxVideoBytes), probe: .system)
        let result = try reader.read(clip)
        XCTAssertFalse(result.segments.filter { $0.modality == "frame" }.isEmpty)
        XCTAssertTrue(result.note.contains("no soundtrack"), result.note)
        XCTAssertTrue(t.calls.isEmpty)
    }

    func testAnAudioOnlyFileNamedMP4IsNoVideo() throws {
        let sound = VideoFixtures.audioOnlyMP4()
        XCTAssertFalse(try VideoProbe.system.info(sound).hasVideoTrack)
        let reader = VideoReader(audio: AudioReader(transcriber: FakeTranscriber(), probe: .system, maxBytes: ReadLimits.maxVideoBytes),
                                 probe: .system)
        XCTAssertThrowsError(try reader.read(sound)) { error in
            guard case ReadFailure.empty(let why) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(why, "no video")
        }
    }
}

/// Image vectors from the picture itself (its centre colour), text through the usual fake: lets a test see that real
/// frames of different scenes were cut, without a model.
final class ColourEmbedder: Embedder {
    let text = FakeEmbedder()
    func info() throws -> SidecarClient.Info { try text.info() }
    func embed(_ modality: EmbedModality, role: EmbedRole, inputs: [String]) throws -> [[Float]] {
        guard modality == .image else { return try text.embed(modality, role: role, inputs: inputs) }
        return inputs.map { path in
            var v = [Float](repeating: 0, count: FakeEmbedder.dim)
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return v }
            var px = [UInt8](repeating: 0, count: 4)
            px.withUnsafeMutableBytes { raw in
                let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            v[0] = Float(px[0]); v[1] = Float(px[1]); v[2] = Float(px[2]); v[3] = 1
            return v
        }
    }
}

/// The real cutter, or an error the test chooses.
final class SwitchCutter: FrameCutting {
    let real = AVFrameCutter()
    var failure: Error?
    func cut(source: URL, time: Double, maxSide: Int, to destination: URL) throws -> Bool {
        if let failure { throw failure }
        return try real.cut(source: source, time: time, maxSide: maxSide, to: destination)
    }
}

final class VideoEngineCutterTests: XCTestCase {
    let on = Kinds.defaultEnabled.union(["audio", "video"])
    let speech = [TranscriptSegment(start: 0.2, end: 2.5, text: "the architecture review is on friday")]

    private var savedStep = ReadLimits.minFrameStep
    override func setUp() { savedStep = ReadLimits.minFrameStep }
    override func tearDown() { ReadLimits.minFrameStep = savedStep }

    func frameCount(_ e: Engine) throws -> Int { try e.store.counts().segmentsByModality["frame"] ?? 0 }

    // Ruling 1: an engine built the normal way cuts real frames with AVFoundation.
    func testAnEngineBuiltTheNormalWayCutsRealFrames() throws {
        ReadLimits.minFrameStep = 1.0                                     // a 3 s clip gets frames at 0.5, 1.5 and 2.5
        let t = FakeTranscriber(); t.segments = speech
        let e = try Engine(paths: Paths(home: TestSupport.tempDir("home")), config: Config(kinds: on), keyProvider: StaticKeyProvider(TestSupport.key),
                           embedder: ColourEmbedder(), ocr: { _ in "" }, transcriber: t)
        let folder = TestSupport.tempDir("films")
        try FileManager.default.copyItem(at: AVFrameCutterTests.threeScenes, to: folder.appendingPathComponent("scenes.mp4"))
        try e.addFolder(folder.path)
        let end = Date().addingTimeInterval(30)
        _ = try e.scan(); XCTAssertFalse(try e.runIndexing(shouldContinue: { Date() < end }).stopped)     // bounded
        XCTAssertEqual(try e.status().counts.filesByKind["video"], 1)
        XCTAssertGreaterThanOrEqual(try frameCount(e), AVFrameCutterTests.scenes.count)

        // An exclusion change rebuilds the workers; the rebuilt indexer still cuts real frames.
        try e.exclude(TestSupport.tempDir("elsewhere").path)
        let before = try frameCount(e)
        try FileManager.default.copyItem(at: VideoFixtures.mp4(scenes: [(1, (200, 40, 40)), (1, (40, 60, 200))], sine: false,
                                                               name: "second.mp4", marker: true),
                                         to: folder.appendingPathComponent("second.mp4"))
        let again = Date().addingTimeInterval(30)
        _ = try e.scan(); XCTAssertFalse(try e.runIndexing(shouldContinue: { Date() < again }).stopped)
        XCTAssertEqual(try e.status().counts.filesByKind["video"], 2)
        XCTAssertGreaterThanOrEqual(try frameCount(e) - before, 2)
    }

    // Ruling 2: an environment error from the cutter defers the video without pausing the run; a file error fails it.
    func testACutterEnvironmentErrorDefersWithoutPausingAndAFileErrorFails() throws {
        let t = FakeTranscriber(); t.segments = speech
        let cutter = SwitchCutter()
        let e = try Engine(paths: Paths(home: TestSupport.tempDir("home")), config: Config(kinds: on), keyProvider: StaticKeyProvider(TestSupport.key),
                           embedder: ColourEmbedder(), ocr: { _ in "" }, transcriber: t, frameCutter: cutter)
        // Every run is bounded: a deferral that came straight back would otherwise loop here instead of failing.
        func run() throws -> IndexingSummary { let end = Date().addingTimeInterval(30); return try e.runIndexing(shouldContinue: { Date() < end }) }
        let folder = TestSupport.tempDir("films")
        let video = RealPath.of(folder.appendingPathComponent("talk.mp4").path)
        try FileManager.default.copyItem(at: AVFrameCutterTests.threeScenes, to: URL(fileURLWithPath: video))
        try e.addFolder(folder.path)
        _ = try e.scan(); try run()
        let before = try XCTUnwrap(e.store.fileRecord(path: video))
        XCTAssertEqual(before.status, "indexed")
        let framesBefore = try frameCount(e)
        XCTAssertGreaterThan(framesBefore, 0)

        // The video changes, a new picture arrives, and the cutter hits an environment error.
        try FileManager.default.removeItem(atPath: video)
        try FileManager.default.copyItem(at: VideoFixtures.mp4(scenes: [(2, (40, 60, 200))], sine: true, name: "other.mp4", marker: true),
                                         to: URL(fileURLWithPath: video))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: video)
        try makeImage(width: 300, height: 100, text: nil, at: folder.appendingPathComponent("new.png"))
        cutter.failure = NSError(domain: "AVFoundationErrorDomain", code: -11819)
        XCTAssertEqual(try e.scan().enqueued, 2)
        let summary = try run()
        XCTAssertFalse(summary.stopped)
        XCTAssertEqual(summary.deferred, 1)
        XCTAssertNil(summary.pausedReason)
        XCTAssertEqual(summary.retryPending, 1)
        let next = try e.store.query("select next_attempt from jobs where path = ?", [.text(video)]) { $0.int(0) }.first ?? 0
        XCTAssertGreaterThan(next, Int64(Date().timeIntervalSince1970) + Engine.deferDelaySeconds * 5)   // the long back-off
        XCTAssertEqual(summary.indexed, 1)                                                      // the picture, same run
        XCTAssertEqual(summary.failed, 0)
        let kept = try XCTUnwrap(e.store.fileRecord(path: video))
        XCTAssertEqual(kept.status, "indexed")
        XCTAssertEqual(kept.contentId, before.contentId)                                       // the old content still serves
        XCTAssertEqual(try frameCount(e), framesBefore)

        cutter.failure = ReadFailure.unreadable("broken stream")
        try e.queue.enqueue(path: video, priority: 0)                                           // retry now, not in ten minutes
        let second = try run()
        XCTAssertEqual(second.failed, 1)
        XCTAssertEqual(try e.store.fileRecord(path: video)?.status, "failed")
    }
}
