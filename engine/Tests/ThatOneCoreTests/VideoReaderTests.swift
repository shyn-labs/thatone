import Foundation
import XCTest
@testable import ThatOneCore

func fakeVideoProbe(duration: Double, hasVideo: Bool = true) -> VideoProbe {
    VideoProbe(info: { _ in VideoInfo(duration: duration, hasVideoTrack: hasVideo) })
}

final class VideoReaderTests: XCTestCase {
    private func file(sizeBytes: Int64 = 10, name: String = "v.mp4") -> URL {
        let url = TestSupport.tempDir("videoreader").appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data(count: 10))
        if sizeBytes != 10 { let h = try! FileHandle(forWritingTo: url); try! h.truncate(atOffset: UInt64(sizeBytes)); try! h.close() }
        return url
    }
    private func reader(duration: Double, hasVideo: Bool = true, transcriber: FakeTranscriber = FakeTranscriber(),
                        audio: AudioProbe? = nil) -> VideoReader {
        let ap = audio ?? fakeProbe(duration: duration)
        return VideoReader(audio: AudioReader(transcriber: transcriber, probe: ap, maxBytes: ReadLimits.maxVideoBytes),
                           probe: fakeVideoProbe(duration: duration, hasVideo: hasVideo))
    }

    func testFramesAnchorsAndSource() throws {
        let url = file()
        let r = try reader(duration: 61).read(url)
        let frames = r.segments.filter { $0.modality == "frame" }
        XCTAssertEqual(frames.count, 12)
        XCTAssertEqual(frames[0].anchor, #"{"t0":0,"t1":5}"#)
        XCTAssertEqual(frames[0].frameTime, 2.5)
        XCTAssertEqual(frames[11].anchor, #"{"t0":55,"t1":60}"#)
        XCTAssertEqual(frames[11].frameTime, 57.5)
        XCTAssertTrue(frames.allSatisfy { $0.frameSource == url && $0.text.isEmpty && $0.image == nil })
        XCTAssertEqual(r.note, "")
    }

    func testLastFrameAnchorClampedToDuration() throws {
        let frames = try reader(duration: 12.6).read(file()).segments.filter { $0.modality == "frame" }
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames.last?.anchor, #"{"t0":10,"t1":12.6}"#)
    }

    func testSoundtrackSegmentsFollowFrames() throws {
        let t = FakeTranscriber()
        t.segments = [TranscriptSegment(start: 0, end: 4, text: "hello there")]
        let segs = try reader(duration: 61, transcriber: t).read(file()).segments
        let mods = segs.map(\.modality)
        let firstNonFrame = mods.firstIndex { $0 != "frame" }!
        XCTAssertEqual(firstNonFrame, 12)
        XCTAssertTrue(mods[firstNonFrame...].allSatisfy { $0 != "frame" })
        XCTAssertTrue(mods.contains("text")); XCTAssertTrue(mods.contains("audio"))
    }

    func testNoSoundtrackKeepsFrames() throws {
        let ap = AudioProbe(duration: { _ in throw ReadFailure.unreadable("x") }, loudness: { _, _ in [] })
        let r = try reader(duration: 61, audio: ap).read(file())
        XCTAssertEqual(r.segments.filter { $0.modality == "frame" }.count, 12)
        XCTAssertEqual(r.note, "no soundtrack")
    }

    func testSilentSoundtrackKeepsFrames() throws {
        let r = try reader(duration: 61, audio: fakeProbe(duration: 61, loudness: { _ in 0 })).read(file())
        XCTAssertEqual(r.segments.filter { $0.modality == "frame" }.count, 12)
        XCTAssertEqual(r.note, "silent soundtrack")
    }

    func testTranscribeFailuresAreRethrown() {
        for failure in [TranscribeFailure.unavailable("no model"), .interrupted, .failed("bad")] {
            let t = FakeTranscriber(); t.failure = failure
            XCTAssertThrowsError(try reader(duration: 61, transcriber: t).read(file())) { XCTAssertEqual($0 as? TranscribeFailure, failure) }
        }
    }

    func testNoVideoTrackIsEmpty() {
        XCTAssertThrowsError(try reader(duration: 61, hasVideo: false).read(file())) { XCTAssertEqual($0 as? ReadFailure, .empty("no video")) }
        XCTAssertThrowsError(try reader(duration: 0.01).read(file())) { XCTAssertEqual($0 as? ReadFailure, .empty("no video")) }
    }

    func testProbeErrorIsUnreadable() {
        let r = VideoReader(audio: AudioReader(transcriber: FakeTranscriber(), probe: fakeProbe(duration: 5)),
                            probe: VideoProbe(info: { _ in throw ReadFailure.unreadable("x") }))
        XCTAssertThrowsError(try r.read(file())) { XCTAssertEqual($0 as? ReadFailure, .unreadable("cannot read this video")) }
    }

    func testOverEightGigabytesIsTooLarge() {
        let url = file(sizeBytes: 9 * 1024 * 1024 * 1024)
        XCTAssertThrowsError(try reader(duration: 61).read(url)) {
            guard case ReadFailure.tooLarge = $0 else { return XCTFail("\($0)") }
        }
    }

    func testTenHoursIsCappedWithNote() throws {
        let r = try reader(duration: 36000, audio: fakeProbe(duration: 36000)).read(file())
        XCTAssertEqual(r.segments.filter { $0.modality == "frame" }.count, 720)
        XCTAssertTrue(r.note.contains(FrameSchedule.note(step: 50)))
        XCTAssertTrue(r.note.hasPrefix("one frame every 50 s"))
    }

    func testSystemProbeReadsGeneratedMovie() throws {
        let url = VideoFixtures.mp4(scenes: [(2, (255, 0, 0)), (2, (0, 0, 255))], sine: true)
        let info = try VideoProbe.system.info(url)
        XCTAssertEqual(info.duration, 4, accuracy: 0.3)
        XCTAssertTrue(info.hasVideoTrack)
    }

    func testSystemProbeRejectsNonVideo() {
        let url = file(name: "junk.mp4")
        XCTAssertThrowsError(try VideoProbe.system.info(url))
    }
}

final class AudioReaderMaxBytesTests: XCTestCase {
    func testSizeLimitIsConfigurable() throws {
        let url = TestSupport.tempDir("audiobig").appendingPathComponent("big.wav")
        FileManager.default.createFile(atPath: url.path, contents: Data(count: 10))
        let h = try FileHandle(forWritingTo: url); try h.truncate(atOffset: UInt64(ReadLimits.maxAudioBytes) + 1024); try h.close()
        let t = FakeTranscriber()
        XCTAssertThrowsError(try AudioReader(transcriber: t, probe: fakeProbe(duration: 5)).read(url)) {
            guard case ReadFailure.tooLarge = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertNoThrow(try AudioReader(transcriber: t, probe: fakeProbe(duration: 5), maxBytes: ReadLimits.maxVideoBytes).read(url))
    }
}
