import XCTest
@testable import ThatOneCore

final class AudioReaderTests: XCTestCase {
    func anchor(_ s: ReadSegment) -> [String: Double] { (try? JSONSerialization.jsonObject(with: Data(s.anchor.utf8)) as? [String: Double]) ?? [:] }
    let url = URL(fileURLWithPath: "/tmp/not-needed.wav")                       // the fake probe never opens it

    func reader(_ t: FakeTranscriber, duration: Double, loudness: @escaping (Int) -> Float = { _ in 0.2 }) -> AudioReader {
        AudioReader(transcriber: t, probe: fakeProbe(duration: duration, loudness: loudness))
    }

    func testTranscriptBecomesTimedTextSegmentsAndWindowsBecomeAudioSegments() throws {
        let t = FakeTranscriber()
        t.segments = [TranscriptSegment(start: 2, end: 10, text: "the notice period is thirty days"),
                      TranscriptSegment(start: 40, end: 50, text: "payment is due in forty five days")]
        let result = try reader(t, duration: 75).read(url)
        let text = result.segments.filter { $0.modality == "text" }
        XCTAssertEqual(text.map { $0.text }, ["the notice period is thirty days", "payment is due in forty five days"])
        XCTAssertEqual(anchor(text[0]), ["t0": 2, "t1": 10])
        let audio = result.segments.filter { $0.modality == "audio" }
        XCTAssertEqual(audio.map { $0.audioRange }, [0...30, 30...60, 60...75])        // 30 s windows over the whole file
        XCTAssertTrue(audio.allSatisfy { $0.audioSource == url && $0.text.isEmpty && $0.image == nil })
        XCTAssertEqual(anchor(audio[2]), ["t0": 60, "t1": 75])
        XCTAssertEqual(result.note, "")
    }

    func testASilentFileIsEmptyAndNeverTranscribed() {
        let t = FakeTranscriber()
        XCTAssertThrowsError(try reader(t, duration: 20, loudness: { _ in 0 }).read(url)) { XCTAssertEqual($0 as? ReadFailure, .empty("silent")) }
        XCTAssertTrue(t.calls.isEmpty)
    }

    func testSilentWindowsAreLeftOutOfTheAudioEmbeddings() throws {
        let t = FakeTranscriber()
        t.segments = [TranscriptSegment(start: 1, end: 5, text: "only the first half is loud")]
        let result = try reader(t, duration: 90, loudness: { $0 < 30 ? 0.2 : 0 }).read(url)
        XCTAssertEqual(result.segments.filter { $0.modality == "audio" }.map { $0.audioRange }, [0...30])
    }

    func testZeroLengthAndUnreadableFilesAreRefusedWithReasons() {
        let t = FakeTranscriber()
        XCTAssertThrowsError(try reader(t, duration: 0).read(url)) { XCTAssertEqual($0 as? ReadFailure, .empty("no audio")) }
        let broken = AudioReader(transcriber: t, probe: AudioProbe(duration: { _ in throw ReadFailure.unreadable("x") }, loudness: { _, _ in [] }))
        XCTAssertThrowsError(try broken.read(url)) { guard case .unreadable? = $0 as? ReadFailure else { return XCTFail("\($0)") } }
        let brokenLoudness = AudioReader(transcriber: t, probe: AudioProbe(duration: { _ in 10 }, loudness: { _, _ in throw ReadFailure.unreadable("x") }))
        XCTAssertThrowsError(try brokenLoudness.read(url)) { guard case .unreadable? = $0 as? ReadFailure else { return XCTFail("\($0)") } }
        XCTAssertTrue(t.calls.isEmpty)
    }

    func testSpeechlessFilesWithSoundStillGetAudioWindowsAndNoTextIsFine() throws {
        let t = FakeTranscriber()                                                    // music: the transcript is empty
        let result = try reader(t, duration: 40).read(url)
        XCTAssertTrue(result.segments.allSatisfy { $0.modality == "audio" })
        XCTAssertEqual(result.segments.count, 2)
    }

    func testDurationCapsAreRecordedInTheNote() throws {
        let saved = (ReadLimits.maxTranscribeSeconds, ReadLimits.maxEmbedSeconds)
        ReadLimits.maxTranscribeSeconds = 3600; ReadLimits.maxEmbedSeconds = 120
        defer { (ReadLimits.maxTranscribeSeconds, ReadLimits.maxEmbedSeconds) = saved }
        let t = FakeTranscriber()
        t.segments = [TranscriptSegment(start: 10, end: 20, text: "early"), TranscriptSegment(start: 5000, end: 5010, text: "past the cap")]
        let result = try reader(t, duration: 7200).read(url)
        XCTAssertEqual(result.segments.filter { $0.modality == "text" }.map { $0.text }, ["early"])
        XCTAssertEqual(result.segments.filter { $0.modality == "audio" }.count, 4)           // 120 s of 30 s windows
        XCTAssertTrue(result.note.contains("first 1 hours"), result.note)
        XCTAssertTrue(result.note.contains("first 2 minutes"), result.note)
    }

    func testOversizedFilesAreRefusedBeforeBeingProbed() throws {
        let saved = ReadLimits.maxAudioBytes
        ReadLimits.maxAudioBytes = 10
        defer { ReadLimits.maxAudioBytes = saved }
        let file = AudioFixtures.wav(seconds: 1)
        XCTAssertThrowsError(try reader(FakeTranscriber(), duration: 1).read(file)) { guard case .tooLarge? = $0 as? ReadFailure else { return XCTFail("\($0)") } }
    }

    func testTranscriberFailuresSurfaceAsTheyAre() {
        let t = FakeTranscriber()
        t.failure = TranscribeFailure.unavailable("no model")
        XCTAssertThrowsError(try reader(t, duration: 30).read(url)) { XCTAssertEqual($0 as? TranscribeFailure, .unavailable("no model")) }
        t.failure = TranscribeFailure.failed("decode error")
        XCTAssertThrowsError(try reader(t, duration: 30).read(url)) { XCTAssertEqual($0 as? TranscribeFailure, .failed("decode error")) }
        let stopping = AudioReader(transcriber: t, probe: fakeProbe(duration: 30), shouldContinue: { false })
        t.failure = nil
        XCTAssertThrowsError(try stopping.read(url)) { XCTAssertEqual($0 as? TranscribeFailure, .interrupted) }
    }

    func testIndicTranscriptsPassThrough() throws {
        let t = FakeTranscriber()
        t.segments = [TranscriptSegment(start: 0, end: 6, text: "ಬೆಂಗಳೂರು ನಗರದ ಹವಾಮಾನ ಇಂದು ಚೆನ್ನಾಗಿದೆ")]
        XCTAssertEqual(try reader(t, duration: 6).read(url).segments.first?.text, "ಬೆಂಗಳೂರು ನಗರದ ಹವಾಮಾನ ಇಂದು ಚೆನ್ನಾಗಿದೆ")
    }

    // MARK: the real AVFoundation probe on generated files

    func testSystemProbeMeasuresDurationAndLoudness() throws {
        let tone = AudioFixtures.wav(seconds: 3, amplitude: 0.3)
        XCTAssertEqual(try AudioProbe.system.duration(tone), 3, accuracy: 0.05)
        let levels = try AudioProbe.system.loudness(tone, 10)
        XCTAssertEqual(levels.count, 3)
        XCTAssertTrue(levels.allSatisfy { $0 > 0.15 && $0 < 0.25 })                   // RMS of a 0.3 sine is about 0.21
        let silence = AudioFixtures.wav(seconds: 2, amplitude: 0)
        XCTAssertTrue(try AudioProbe.system.loudness(silence, 10).allSatisfy { $0 < ReadLimits.silenceRMS })
        let mixed = AudioFixtures.wavLoudThenSilent(loud: 2, total: 5)
        let m = try AudioProbe.system.loudness(mixed, 10)
        XCTAssertEqual(m.count, 5)
        XCTAssertTrue(m[0] > 0.1 && m[1] > 0.1 && m[3] < 0.001)
        XCTAssertEqual(try AudioProbe.system.loudness(tone, 2).count, 2)               // honours the cap
    }

    func testSystemProbeHandlesStereoAndOtherRates() throws {
        XCTAssertEqual(try AudioProbe.system.duration(AudioFixtures.wav(seconds: 2, sampleRate: 44100, channels: 2)), 2, accuracy: 0.05)
        XCTAssertEqual(try AudioProbe.system.duration(AudioFixtures.wav(seconds: 2, sampleRate: 8000)), 2, accuracy: 0.05)
        XCTAssertEqual(try AudioProbe.system.loudness(AudioFixtures.wav(seconds: 2, sampleRate: 44100, channels: 2), 5).count, 2)
    }

    func testSystemProbeRefusesCorruptAndEmptyFiles() throws {
        let folder = TestSupport.tempDir("audio")
        let corrupt = folder.appendingPathComponent("broken.mp3")
        try Data((0..<3000).map { UInt8(($0 * 53 + 7) % 256) }).write(to: corrupt)
        XCTAssertThrowsError(try AudioProbe.system.duration(corrupt))
        let empty = folder.appendingPathComponent("empty.wav")
        try Data().write(to: empty)
        XCTAssertThrowsError(try AudioProbe.system.duration(empty))
        // and through the reader, as a reportable failure
        XCTAssertThrowsError(try AudioReader(transcriber: FakeTranscriber()).read(corrupt)) { guard case .unreadable? = $0 as? ReadFailure else { return XCTFail("\($0)") } }
    }
}
