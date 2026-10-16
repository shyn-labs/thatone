import AVFoundation
import XCTest
@testable import ThatOneCore

final class VideoBasicsTests: XCTestCase {
    func testDetectVideoExtensions() {
        XCTAssertEqual(Kinds.detect("/x/a.MP4"), "video")
        XCTAssertEqual(Kinds.detect("/x/b.mov"), "video")
        XCTAssertEqual(Kinds.detect("/x/c.m4v"), "video")
    }

    func testDefaultsExcludeVideoAndOrder() {
        XCTAssertFalse(Kinds.defaultEnabled.contains("video"))
        XCTAssertEqual(Kinds.all, ["image", "pdf", "document", "text", "audio", "video"])
    }

    func testLimits() {
        XCTAssertEqual(ReadLimits.maxVideoBytes, 8_000_000_000)
        XCTAssertEqual(ReadLimits.maxFrames, 720)
        XCTAssertEqual(ReadLimits.minFrameStep, 5.0)
        XCTAssertEqual(ReadLimits.frameDuplicateCosine, 0.97)
        XCTAssertEqual(ReadLimits.blankFrameSpread, 3)
        let s = ReadSegment(modality: "image", anchor: "{}", text: "")
        XCTAssertNil(s.frameSource); XCTAssertNil(s.frameTime)
    }

    func testSchedule() {
        let short = FrameSchedule.plan(duration: 3)
        XCTAssertEqual(short.times, [2.5])
        let mid = FrameSchedule.plan(duration: 61)
        XCTAssertEqual(mid.step, 5); XCTAssertEqual(mid.times.count, 12); XCTAssertEqual(mid.times[0], 2.5)
        let long = FrameSchedule.plan(duration: 36000)
        XCTAssertEqual(long.step, 50); XCTAssertEqual(long.times.count, 720); XCTAssertLessThan(long.times.last!, 36000)
        XCTAssertTrue(FrameSchedule.plan(duration: 0.01).times.isEmpty)
        XCTAssertEqual(FrameSchedule.plan(duration: 2).times, [1.0])
    }

    func testNote() {
        XCTAssertEqual(FrameSchedule.note(step: 5), "")
        XCTAssertEqual(FrameSchedule.note(step: 15), "one frame every 15 s")
        XCTAssertEqual(FrameSchedule.note(step: 14.2), "one frame every 15 s")
    }

    func testContainerProof() throws {
        let url = VideoFixtures.mp4(scenes: [(2, (255, 0, 0)), (2, (0, 0, 255))], sine: true)
        _ = try AVAudioFile(forReading: url)
        let d = try AudioProbe.system.duration(url)
        XCTAssertEqual(d, 4, accuracy: 0.3)
        let out = TestSupport.tempDir("video").appendingPathComponent("out.wav")
        try AudioWindows.extract(source: url, range: 0...2, to: out)
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: out.path)[.size] as! NSNumber).intValue, 1000)
    }

    func testOldConfigKeepsDefaults() throws {
        let data = #"{"kinds":["image","pdf"]}"#.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(cfg.kinds, ["image", "pdf"])
        let none = try JSONDecoder().decode(Config.self, from: "{}".data(using: .utf8)!)
        XCTAssertEqual(none.kinds, Kinds.defaultEnabled)
    }
}
