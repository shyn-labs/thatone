import ThatOneCore
import XCTest
@testable import ThatOneApp

final class FakeClipPlayer: ClipPlayer {
    var log: [String] = []
    var currentTime: Double { 0 }
    func play(path: String, from seconds: Double) { log.append("play \(path) \(seconds)") }
    func pause() { log.append("pause") }
    func stop() { log.append("stop") }
}

final class AudioResultsTests: XCTestCase {
    func testChipAndStartTimeComeFromTheAnchor() {
        XCTAssertEqual(AnchorChip.text(from: #"{"t0":133.4,"t1":160}"#), "02:13")
        XCTAssertEqual(AnchorChip.startTime(from: #"{"t0":133.4,"t1":160}"#), 133.4)
        XCTAssertNil(AnchorChip.startTime(from: #"{"page":2}"#))
        XCTAssertNil(AnchorChip.startTime(from: "not json"))
    }

    func testPlaybackStartsAtTheAnchorTogglesAndStops() {
        let fake = FakeClipPlayer()
        let playback = AudioPlayback(player: fake)
        playback.toggle(path: "/a.m4a", from: 133.4)
        XCTAssertTrue(playback.isPlaying("/a.m4a")); XCTAssertFalse(playback.isPlaying("/b.m4a"))
        playback.toggle(path: "/a.m4a", from: 133.4)
        XCTAssertFalse(playback.isPlaying("/a.m4a"))
        playback.toggle(path: "/a.m4a", from: 133.4)
        playback.stop()
        XCTAssertNil(playback.playingPath)
        XCTAssertEqual(fake.log, ["play /a.m4a 133.4", "pause", "play /a.m4a 133.4", "stop"])
    }

    func testMenuCountsRecordings() {
        var s = HostSnapshot(); s.state = .idle
        func title() -> String? { MenuModel.items(for: s, hotKey: .default).first { $0.id == "recordings" }?.title }
        XCTAssertNil(title())
        s.kinds = ["audio": 1]; XCTAssertEqual(title(), "1 recording")
        s.kinds = ["audio": 12]; XCTAssertEqual(title(), "12 recordings")
    }

    func testAudioSwitchHasACostNote() {
        XCTAssertNotNil(KindSwitch.all.first { $0.kind == "audio" }?.note)
    }
}
