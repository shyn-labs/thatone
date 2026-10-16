import AVFoundation
import XCTest
@testable import ThatOneCore

final class AudioIndexingTests: XCTestCase {
    static let secret = "my deploy key is sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789"

    final class Setup {
        let dir = TestSupport.tempDir("audioidx")
        let store: Store
        let embedder = FakeEmbedder()
        let transcriber = FakeTranscriber()
        var keepGoing = true
        let indexer: Indexer
        init() throws {
            store = try Store.open(path: dir.appendingPathComponent("index.db").path, key: TestSupport.key, dim: FakeEmbedder.dim)
            var go: (() -> Bool) = { true }
            indexer = Indexer(store: store, embedder: embedder, workDir: dir.appendingPathComponent("work"), exclusions: Exclusions(),
                              roots: { [] }, ocr: { _ in "" }, enabledKinds: { Kinds.defaultEnabled.union(["audio"]) },
                              transcriber: transcriber, shouldContinue: { go() })
            go = { [unowned self] in self.keepGoing }
        }
        func search(_ q: String) throws -> [SearchHit] { try Searcher(store: store).search(query: q, queryVector: nil) }
        var runFiles: [URL] { (try? FileManager.default.contentsOfDirectory(at: indexer.runDirectory, includingPropertiesForKeys: nil)) ?? [] }
    }

    func say(_ s: Setup, _ lines: [(Double, Double, String)]) {
        s.transcriber.segments = lines.map { TranscriptSegment(start: $0.0, end: $0.1, text: $0.2) }
    }

    func testAudioIsIndexedAndFoundByASpokenPhrase() throws {
        let s = try Setup()
        let url = AudioFixtures.wav(seconds: 35)
        say(s, [(2, 9, "the notice period is thirty days"), (31, 34, "payment is due within forty five days")])
        XCTAssertEqual(s.indexer.index(paths: [url.path]), [url.path: .indexed])
        XCTAssertEqual(try s.store.fileRecord(path: url.path)?.kind, "audio")
        let hit = try XCTUnwrap(s.search("forty five days").first)
        XCTAssertEqual(hit.paths, [url.path])
        XCTAssertEqual(hit.anchors[0].anchor, #"{"t0":31,"t1":34}"#)                 // the phrases are 22 s apart: the chip points at the matching phrase, not across the silence
        let counts = try s.store.counts().segmentsByModality
        XCTAssertEqual(counts["audio"], 2)                                                // 0-30 s and 30-35 s
        XCTAssertEqual(counts["text"], 2)                                                 // a long silence splits the transcript chunk
        XCTAssertEqual(s.embedder.callCount(.audio), 1)                                   // windows go in groups of four
        XCTAssertTrue(s.runFiles.isEmpty, "window files are removed after embedding")
    }

    func testWindowsAreCutAfterTheSecretGateAndTheSecretSkipsTheWholeFile() throws {
        let s = try Setup()
        let url = AudioFixtures.wav(seconds: 20)
        say(s, [(1, 8, "ordinary words here"), (9, 15, Self.secret)])
        XCTAssertEqual(s.indexer.index(paths: [url.path]), [url.path: .skipped("secret")])
        XCTAssertTrue(s.embedder.calls.isEmpty)
        XCTAssertTrue(s.runFiles.isEmpty)
        XCTAssertEqual(try s.search("ordinary words").count, 0)
        // control: a clean transcript does produce a 16 kHz mono WAV in the run folder while the embedder works
        let clean = try Setup()
        say(clean, [(1, 8, "ordinary words here")])
        var seen: (rate: Double, channels: UInt32)?
        clean.embedder.onEmbed = {
            if let wav = clean.runFiles.first(where: { $0.pathExtension == "wav" }), let f = try? AVAudioFile(forReading: wav) {
                seen = (f.processingFormat.sampleRate, f.processingFormat.channelCount)
            }
        }
        XCTAssertEqual(clean.indexer.index(paths: [url.path]), [url.path: .indexed])
        XCTAssertEqual(seen?.rate, 16000)
        XCTAssertEqual(seen?.channels, 1)
    }

    func testASilentRecordingIsRecordedAsSilentAndNotRetried() throws {
        let s = try Setup()
        let url = AudioFixtures.wav(seconds: 10, amplitude: 0)
        XCTAssertEqual(s.indexer.index(paths: [url.path]), [url.path: .skipped("silent")])
        XCTAssertTrue(s.transcriber.calls.isEmpty)
        XCTAssertEqual(try s.store.fileRecord(path: url.path)?.note, "silent")
        XCTAssertEqual(s.indexer.index(paths: [url.path]), [url.path: .unchanged])
    }

    func testAnUnavailableTranscriberDefersWithoutRecordingAnything() throws {
        let s = try Setup()
        let url = AudioFixtures.wav(seconds: 10)
        s.transcriber.failure = TranscribeFailure.unavailable("no model")
        XCTAssertEqual(s.indexer.index(paths: [url.path]), [url.path: .deferred("transcription unavailable: no model")])
        XCTAssertNil(try s.store.fileRecord(path: url.path))
        XCTAssertTrue(s.embedder.calls.isEmpty)
        s.transcriber.failure = nil
        say(s, [(1, 5, "now the model is back")])
        XCTAssertEqual(s.indexer.index(paths: [url.path]), [url.path: .indexed])
    }

    func testATranscriptionThatFailsFailsOnlyThatFile() throws {
        let s = try Setup()
        let url = AudioFixtures.wav(seconds: 10)
        s.transcriber.failure = TranscribeFailure.failed("decoder error")
        guard case .failed(let reason)? = s.indexer.index(paths: [url.path])[url.path] else { return XCTFail("expected a failure") }
        XCTAssertTrue(reason.hasPrefix("transcription failed"), reason)
    }

    func testStoppingMidFileDefersAndLeavesNothing() throws {
        let s = try Setup()
        let url = AudioFixtures.wav(seconds: 130)                                          // five windows: two groups of embeddings
        say(s, [(1, 5, "some words in a long recording")])
        s.embedder.onEmbed = { if s.embedder.callCount(.audio) >= 1 { s.keepGoing = false } }   // paused after the first group
        XCTAssertEqual(s.indexer.index(paths: [url.path]), [url.path: .deferred("paused")])
        XCTAssertNil(try s.store.fileRecord(path: url.path))
        XCTAssertTrue(s.runFiles.isEmpty)
        s.keepGoing = true
        s.embedder.onEmbed = nil
        XCTAssertEqual(s.indexer.index(paths: [url.path]), [url.path: .indexed])
        // interrupted inside the transcriber itself
        let other = AudioFixtures.wav(seconds: 10)
        s.keepGoing = false
        XCTAssertEqual(s.indexer.index(paths: [other.path]), [other.path: .deferred("paused")])
    }

    func testAChangedRecordingDropsItsOldSegments() throws {
        let s = try Setup()
        let url = AudioFixtures.wav(seconds: 12)
        say(s, [(1, 5, "original wording about harvest timing")])
        XCTAssertEqual(s.indexer.index(paths: [url.path]), [url.path: .indexed])
        try FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: AudioFixtures.wav(seconds: 14), to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: url.path)
        say(s, [(1, 5, "completely different wording about tractors")])
        XCTAssertEqual(s.indexer.index(paths: [url.path]), [url.path: .indexed])
        XCTAssertEqual(try s.search("harvest timing").count, 0)
        XCTAssertEqual(try s.search("different wording about tractors").count, 1)
    }

    func testARenamedRecordingLinksByHashWithoutTranscribingAgain() throws {
        let s = try Setup()
        let original = AudioFixtures.wav(seconds: 12)
        say(s, [(1, 5, "notice period words")])
        XCTAssertEqual(s.indexer.index(paths: [original.path]), [original.path: .indexed])
        let calls = (s.transcriber.calls.count, s.embedder.calls.count)
        let renamed = original.deletingLastPathComponent().appendingPathComponent("renamed.wav")
        try FileManager.default.moveItem(at: original, to: renamed)
        let outcomes = s.indexer.index(paths: [renamed.path, original.path])
        XCTAssertEqual(outcomes[renamed.path], .linked)
        XCTAssertEqual(outcomes[original.path], .removed)
        XCTAssertEqual(s.transcriber.calls.count, calls.0)
        XCTAssertEqual(s.embedder.calls.count, calls.1)
    }

    func testAnEmbeddingFailureLeavesNoWindowFilesBehind() throws {
        let s = try Setup()
        let url = AudioFixtures.wav(seconds: 40)
        say(s, [(1, 5, "words that will be embedded")])
        s.embedder.failWhen = { modality, _ in modality == .audio }
        guard case .failed? = s.indexer.index(paths: [url.path])[url.path] else { return XCTFail("expected a failure") }
        XCTAssertTrue(s.runFiles.isEmpty)
    }

    func testCorruptAudioFailsWithAReasonAndNothingElse() throws {
        let s = try Setup()
        let url = TestSupport.tempDir("audio").appendingPathComponent("broken.mp3")
        try Data((0..<4000).map { UInt8(($0 * 31 + 5) % 256) }).write(to: url)
        guard case .failed(let reason)? = s.indexer.index(paths: [url.path])[url.path] else { return XCTFail("expected a failure") }
        XCTAssertTrue(reason.hasPrefix("cannot read"), reason)
        XCTAssertTrue(s.transcriber.calls.isEmpty)
    }

    // MARK: windows

    func testWindowExtractionMakesSixteenKilohertzMonoFromAnyInput() throws {
        let source = AudioFixtures.wav(seconds: 12, sampleRate: 44100, channels: 2)
        let out = TestSupport.tempDir("win").appendingPathComponent("w.wav")
        try AudioWindows.extract(source: source, range: 3...9, to: out)
        let f = try AVAudioFile(forReading: out)
        XCTAssertEqual(f.processingFormat.sampleRate, 16000)
        XCTAssertEqual(f.processingFormat.channelCount, 1)
        XCTAssertEqual(Double(f.length) / 16000, 6, accuracy: 0.1)
        XCTAssertEqual(try AudioProbe.system.loudness(out, 6).filter { $0 > 0.1 }.count, 6)       // the sound survived the conversion
    }

    func testWindowExtractionClampsAtTheEndAndRefusesNonsense() throws {
        let source = AudioFixtures.wav(seconds: 5)
        let dir = TestSupport.tempDir("win")
        try AudioWindows.extract(source: source, range: 3...30, to: dir.appendingPathComponent("tail.wav"))
        XCTAssertEqual(Double(try AVAudioFile(forReading: dir.appendingPathComponent("tail.wav")).length) / 16000, 2, accuracy: 0.1)
        XCTAssertThrowsError(try AudioWindows.extract(source: source, range: 8...20, to: dir.appendingPathComponent("past.wav")))
        XCTAssertThrowsError(try AudioWindows.extract(source: source, range: 2...2, to: dir.appendingPathComponent("zero.wav")))
        let corrupt = dir.appendingPathComponent("c.wav")
        try Data(repeating: 7, count: 500).write(to: corrupt)
        XCTAssertThrowsError(try AudioWindows.extract(source: corrupt, range: 0...1, to: dir.appendingPathComponent("o.wav")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("past.wav").path))
    }
}
