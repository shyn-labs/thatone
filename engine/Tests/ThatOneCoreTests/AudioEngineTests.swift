import XCTest
@testable import ThatOneCore

final class AudioEngineTests: XCTestCase {
    func folderWithAudio() throws -> URL {
        let folder = TestSupport.tempDir("rec")
        try FileManager.default.copyItem(at: AudioFixtures.wav(seconds: 12), to: folder.appendingPathComponent("memo.wav"))
        try makeImage(width: 300, height: 100, text: nil, at: folder.appendingPathComponent("p.png"))
        return folder
    }

    func makeEngine(transcriber: Transcriber?, kinds: Set<String>, embedder: FakeEmbedder = FakeEmbedder()) throws -> Engine {
        try Engine(paths: Paths(home: TestSupport.tempDir("home")), config: Config(kinds: kinds), keyProvider: StaticKeyProvider(TestSupport.key),
                   embedder: embedder, ocr: { _ in "" }, transcriber: transcriber)
    }

    func testWithoutATranscriberAudioIsNeverQueuedEvenWhenSwitchedOn() throws {
        let e = try makeEngine(transcriber: nil, kinds: Kinds.defaultEnabled.union(["audio"]))
        let folder = try folderWithAudio()
        try e.addFolder(folder.path)
        XCTAssertEqual(try e.scan().enqueued, 1)                                              // only the png
        XCTAssertEqual(try e.enqueue(files: [folder.appendingPathComponent("memo.wav").path]), 0)
        try e.runIndexing()
        XCTAssertEqual(try e.status().counts.filesByKind, ["image": 1])
        XCTAssertTrue(try e.status().folders.count == 1)
    }

    func testAudioIsIndexedWhenSwitchedOnAndATranscriberExists() throws {
        let t = FakeTranscriber()
        t.segments = [TranscriptSegment(start: 1, end: 6, text: "the harvest review is in march")]
        let e = try makeEngine(transcriber: t, kinds: Kinds.defaultEnabled.union(["audio"]))
        let folder = try folderWithAudio()
        try e.addFolder(folder.path)
        _ = try e.scan(); try e.runIndexing()
        XCTAssertEqual(try e.status().counts.filesByKind, ["image": 1, "audio": 1])
        XCTAssertEqual(try Searcher(store: e.store).search(query: "harvest review", queryVector: nil, filters: SearchFilters(kinds: ["audio"])).count, 1)
    }

    func testAudioIsOffByDefaultEvenWithATranscriber() throws {
        let e = try makeEngine(transcriber: FakeTranscriber(), kinds: Kinds.defaultEnabled)
        let folder = try folderWithAudio()
        try e.addFolder(folder.path)
        _ = try e.scan(); try e.runIndexing()
        XCTAssertEqual(try e.status().counts.filesByKind, ["image": 1])
    }

    func testAudioSwitchedOffWhileARecordingIsBeingEmbeddedLeavesNothing() throws {
        let t = FakeTranscriber()
        t.segments = [TranscriptSegment(start: 1, end: 6, text: "words that must not stay behind")]
        let fake = FakeEmbedder()
        let e = try makeEngine(transcriber: t, kinds: Kinds.defaultEnabled.union(["audio"]), embedder: fake)
        let folder = try folderWithAudio()
        try e.addFolder(folder.path)
        _ = try e.scan()
        var flipped = false
        fake.onEmbed = { if !flipped { flipped = true; try? e.setKinds(Kinds.defaultEnabled); _ = try? e.scan() } }
        try e.runIndexing()
        XCTAssertTrue(flipped)
        XCTAssertEqual(try e.status().counts.filesByKind["audio"] ?? 0, 0)
        XCTAssertEqual(try e.queue.counts(), QueueCounts(queued: 0, running: 0, failed: 0))
    }

    func testSwitchingAudioOffPurgesIt() throws {
        let t = FakeTranscriber()
        t.segments = [TranscriptSegment(start: 1, end: 6, text: "some spoken words")]
        let e = try makeEngine(transcriber: t, kinds: Kinds.defaultEnabled.union(["audio"]))
        let folder = try folderWithAudio()
        try e.addFolder(folder.path)
        _ = try e.scan(); try e.runIndexing()
        try e.setKinds(Kinds.defaultEnabled)
        XCTAssertEqual(try e.status().counts.filesByKind["audio"] ?? 0, 0)
        XCTAssertEqual(try e.status().counts.segmentsByModality["audio"] ?? 0, 0)
    }

    func testAPauseRequestedThroughRunIndexingReachesALongRecording() throws {
        let t = FakeTranscriber()
        t.segments = [TranscriptSegment(start: 1, end: 6, text: "words in a long recording")]
        let fake = FakeEmbedder()
        let e = try makeEngine(transcriber: t, kinds: ["audio"], embedder: fake)
        let folder = TestSupport.tempDir("long")
        try FileManager.default.copyItem(at: AudioFixtures.wav(seconds: 130), to: folder.appendingPathComponent("long.wav"))
        try e.addFolder(folder.path)
        _ = try e.scan()
        var pause = false
        fake.onEmbed = { if fake.callCount(.audio) >= 1 { pause = true } }
        let summary = try e.runIndexing(shouldContinue: { !pause })
        XCTAssertEqual(summary.deferred, 1)                                                     // yielded between windows, not after the whole file
        XCTAssertEqual(try e.status().counts.filesByKind["audio"] ?? 0, 0)
        XCTAssertEqual(try e.queue.counts().failed, 0)
    }
}
