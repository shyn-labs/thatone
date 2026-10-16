import XCTest
@testable import ThatOneCore

/// What the M3 review found: each test failed before its fix.
final class AudioReviewFixTests: XCTestCase {
    let on = Kinds.defaultEnabled.union(["audio"])

    func folderWithAudio() throws -> URL {
        let folder = TestSupport.tempDir("rec")
        try FileManager.default.copyItem(at: AudioFixtures.wav(seconds: 12), to: folder.appendingPathComponent("memo.wav"))
        try makeImage(width: 300, height: 100, text: nil, at: folder.appendingPathComponent("p.png"))
        return folder
    }

    func makeEngine(home: URL, transcriber: Transcriber?) throws -> Engine {
        try Engine(paths: Paths(home: home), config: Config(kinds: on), keyProvider: StaticKeyProvider(TestSupport.key),
                   embedder: FakeEmbedder(), ocr: { _ in "" }, transcriber: transcriber)
    }

    func segments() -> [TranscriptSegment] { [TranscriptSegment(start: 1, end: 6, text: "the harvest review is in march")] }

    // 1. A process without a transcriber (the CLI) must leave indexed audio alone.
    func testAProcessWithoutATranscriberNeverPurgesIndexedAudio() throws {
        let home = TestSupport.tempDir("home")
        let t = FakeTranscriber(); t.segments = segments()
        let app = try makeEngine(home: home, transcriber: t)
        let folder = try folderWithAudio()
        try app.addFolder(folder.path)
        _ = try app.scan(); try app.runIndexing()
        XCTAssertEqual(try app.status().counts.filesByKind["audio"], 1)

        let cli = try makeEngine(home: home, transcriber: nil)
        try cli.addFolder(folder.path)                                             // the CLI scans the same folder
        let result = try cli.scan()
        XCTAssertEqual(result.purgeQueued, 0)                                      // crawler guard
        try cli.runIndexing()
        XCTAssertEqual(try cli.status().counts.filesByKind["audio"], 1)
        // and a job the app left queued for audio is not eaten by it either (claim filter, then triage guard)
        let memo = RealPath.of(folder.appendingPathComponent("memo.wav").path)
        let changed = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: changed], ofItemAtPath: memo)
        XCTAssertEqual(try app.scan().enqueued, 1)
        try cli.runIndexing()
        XCTAssertEqual(try cli.queue.counts().queued, 1)
        XCTAssertEqual(try cli.status().counts.filesByKind["audio"], 1)
        try app.runIndexing()                                                      // no rescan: the job is still there
        XCTAssertEqual(try app.status().counts.filesByKind["audio"], 1)
        XCTAssertEqual(try app.store.fileRecord(path: memo)?.mtime, Int64(changed.timeIntervalSince1970))
    }

    // 2. A window that cannot be cut is a failed file, not a deferral that repeats every minute.
    func testAWindowThatCannotBeCutFailsTheFileInsteadOfDeferringForever() throws {
        let t = FakeTranscriber(); t.segments = segments()
        let e = try makeEngine(home: TestSupport.tempDir("home"), transcriber: t)
        let folder = try folderWithAudio()
        try e.addFolder(folder.path)
        let memo = folder.appendingPathComponent("memo.wav")
        t.onReturn = { try? FileManager.default.removeItem(at: memo) }             // gone between reading and cutting windows
        _ = try e.scan()
        let summary = try e.runIndexing()
        XCTAssertEqual(summary.deferred, 0)
        XCTAssertNil(summary.pausedReason)
        XCTAssertEqual(summary.failed, 1)
    }

    // 3. The cap goes to the transcriber, which must not decode the whole file first.
    func testTheTranscriberIsToldHowMuchToRead() throws {
        let t = FakeTranscriber(); t.segments = segments()
        let reader = AudioReader(transcriber: t, probe: fakeProbe(duration: 10 * 3600))
        _ = try reader.read(URL(fileURLWithPath: "/x/long.mp3"))
        XCTAssertEqual(t.lastMaxSeconds, Double(ReadLimits.maxTranscribeSeconds))
        let short = AudioReader(transcriber: t, probe: fakeProbe(duration: 90))
        _ = try short.read(URL(fileURLWithPath: "/x/short.mp3"))
        XCTAssertEqual(t.lastMaxSeconds, 90)
    }

    // 4. A model that is not there must not queue audio, pause the run or hold up images.
    func testAMissingModelNeitherQueuesAudioNorStopsOtherKinds() throws {
        let t = FakeTranscriber(); t.segments = segments(); t.isAvailable = false
        let e = try makeEngine(home: TestSupport.tempDir("home"), transcriber: t)
        let folder = try folderWithAudio()
        try e.addFolder(folder.path)
        XCTAssertEqual(try e.scan().enqueued, 1)                                   // only the png
        let summary = try e.runIndexing()
        XCTAssertNil(summary.pausedReason); XCTAssertEqual(summary.deferred, 0)
        XCTAssertEqual(try e.status().counts.filesByKind, ["image": 1])
        XCTAssertTrue(t.calls.isEmpty)
        t.isAvailable = true                                                       // the model shows up
        XCTAssertEqual(try e.scan().enqueued, 1)
        try e.runIndexing()
        XCTAssertEqual(try e.status().counts.filesByKind, ["image": 1, "audio": 1])
    }

    // 4b. A model that cannot be loaded defers audio without stopping the other kinds.
    func testAnUnloadableModelDefersAudioWithoutPausingTheRun() throws {
        let t = FakeTranscriber(); t.failure = TranscribeFailure.unavailable("corrupt model")
        let e = try makeEngine(home: TestSupport.tempDir("home"), transcriber: t)
        let folder = try folderWithAudio()
        try e.addFolder(folder.path)
        _ = try e.scan()
        let summary = try e.runIndexing()
        XCTAssertNil(summary.pausedReason)
        XCTAssertEqual(summary.deferred, 1)
        XCTAssertEqual(try e.status().counts.filesByKind["image"], 1)
    }

    // 7. Pausing between windows keeps the transcript for the retry.
    func testAPauseBetweenWindowsDoesNotTranscribeTheFileAgain() throws {
        Engine.deferDelaySeconds = 0
        defer { Engine.deferDelaySeconds = 60 }
        let t = FakeTranscriber(); t.segments = segments()
        let e = try makeEngine(home: TestSupport.tempDir("home"), transcriber: t)
        let folder = try folderWithAudio()
        try e.addFolder(folder.path)
        _ = try e.scan()
        var paused = false
        t.onReturn = { paused = true }
        let first = try e.runIndexing(shouldContinue: { !paused })
        XCTAssertTrue(first.stopped || first.deferred > 0)
        XCTAssertEqual(t.calls.count, 1)
        paused = false; t.onReturn = nil
        try e.runIndexing()
        XCTAssertEqual(t.calls.count, 1)                                          // the kept transcript was used
        XCTAssertEqual(try e.status().counts.filesByKind["audio"], 1)
    }

    // 8. A file whose loudness cannot be read is unreadable, not "silent".
    func testNoLoudnessDataIsUnreadableNotSilent() {
        let probe = AudioProbe(duration: { _ in 30 }, loudness: { _, _ in [] })
        let reader = AudioReader(transcriber: FakeTranscriber(), probe: probe)
        XCTAssertThrowsError(try reader.read(URL(fileURLWithPath: "/x/bad.mp3"))) {
            guard case ReadFailure.unreadable = $0 else { return XCTFail("\($0)") }
        }
    }

    // 9. An interruption is not shown as a pause reason.
    func testAnInterruptionLeavesNoPauseReason() throws {
        Engine.deferDelaySeconds = 0
        defer { Engine.deferDelaySeconds = 60 }
        let t = FakeTranscriber(); t.segments = segments()
        let e = try makeEngine(home: TestSupport.tempDir("home"), transcriber: t)
        let folder = try folderWithAudio()
        try e.addFolder(folder.path)
        _ = try e.scan()
        var paused = false
        t.onReturn = { paused = true }
        let summary = try e.runIndexing(shouldContinue: { !paused })
        XCTAssertNil(summary.pausedReason)
    }
}
