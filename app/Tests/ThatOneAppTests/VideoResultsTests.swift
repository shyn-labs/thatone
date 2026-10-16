import ThatOneCore
import XCTest
@testable import ThatOneApp

final class VideoResultsTests: XCTestCase {
    func hit(_ path: String, anchor: String, text: String = "") -> ServiceHit {
        ServiceHit(paths: [path], kind: "video", score: 1, modified: 0,
                   anchors: [ServiceAnchor(modality: "frame", anchor: anchor, text: text, viaKeyword: false, viaVector: true)])
    }

    func testFrameAnchorGivesTimeChipAndStartTime() {
        let row = ResultRow(hit: hit("/v/a.mp4", anchor: #"{"t0":75,"t1":75}"#))
        XCTAssertEqual(row.chips, ["01:15"]); XCTAssertEqual(row.startTime, 75); XCTAssertEqual(row.excerpt, "")
        XCTAssertEqual(ResultRow(hit: hit("/v/a.mp4", anchor: #"{"t0":3,"t1":9}"#, text: "hello")).excerpt, "hello")
    }

    func testFilmIconAndSwitchAndFilter() {
        XCTAssertEqual(KindIcon.name(for: "video"), "film")
        let sw = KindSwitch.all.first { $0.kind == "video" }
        XCTAssertEqual(sw?.title, "Video (frames and soundtrack)")
        XCTAssertEqual(sw?.note, "Needs the Whisper model; frames are sampled every few seconds and the sound is transcribed; can take hours for a large library.")
        XCTAssertEqual(KindFilter.audio.next(), .video)
    }

    func testMenuCountsVideos() {
        var s = HostSnapshot(); s.state = .idle
        func title() -> String? { MenuModel.items(for: s, hotKey: .default).first { $0.id == "videos" }?.title }
        XCTAssertNil(title())
        s.kinds = ["video": 1]; XCTAssertEqual(title(), "1 video")
        s.kinds = ["video": 4]; XCTAssertEqual(title(), "4 videos")
    }

    func testPlaybackTogglesAndStops() {
        let fake = FakeClipPlayer()
        let video = VideoPlayback(player: fake, audio: AudioPlayback(player: FakeClipPlayer()))
        video.toggle(path: "/v/a.mp4", from: 75)
        XCTAssertTrue(video.isPlaying("/v/a.mp4")); XCTAssertEqual(video.shownPath, "/v/a.mp4")
        video.toggle(path: "/v/a.mp4", from: 75)
        XCTAssertFalse(video.isPlaying("/v/a.mp4")); XCTAssertEqual(video.shownPath, "/v/a.mp4")
        video.stop()
        XCTAssertNil(video.shownPath); XCTAssertNil(video.playingPath)
        XCTAssertEqual(fake.log, ["play /v/a.mp4 75.0", "pause", "stop"])
    }

    func testVideoStopsAudioAndAudioStopsVideo() {
        let audioFake = FakeClipPlayer(), videoFake = FakeClipPlayer()
        let audio = AudioPlayback(player: audioFake)
        let video = VideoPlayback(player: videoFake, audio: audio)
        audio.toggle(path: "/a.m4a", from: 0)
        video.toggle(path: "/v.mp4", from: 5)
        XCTAssertNil(audio.playingPath); XCTAssertTrue(video.isPlaying("/v.mp4"))
        XCTAssertEqual(audioFake.log, ["play /a.m4a 0.0", "stop"])
        audio.toggle(path: "/a.m4a", from: 0)
        XCTAssertNil(video.playingPath); XCTAssertNil(video.shownPath)
        XCTAssertEqual(videoFake.log, ["play /v.mp4 5.0", "stop"])
        XCTAssertTrue(audio.isPlaying("/a.m4a"))
    }

    func testPhotosPathNeverReachesThePlayer() {
        let fake = FakeClipPlayer()
        let video = VideoPlayback(player: fake, audio: AudioPlayback(player: FakeClipPlayer()))
        let photos = PhotosPath.make(id: "ABC", filename: "clip.mov")
        XCTAssertFalse(VideoPlayback.canPlay(path: photos))
        XCTAssertTrue(VideoPlayback.canPlay(path: "/v/a.mp4"))
        video.toggle(path: photos, from: 0)
        XCTAssertNil(video.playingPath); XCTAssertNil(video.shownPath); XCTAssertEqual(fake.log, [])
    }

    func testHideStopsBoth() {
        let a = FakeClipPlayer(), v = FakeClipPlayer()
        let audio = AudioPlayback(player: a); let video = VideoPlayback(player: v, audio: audio)
        video.toggle(path: "/v.mp4", from: 0)
        PlaybackStopper.stopAll(audio: audio, video: video)
        XCTAssertNil(video.playingPath); XCTAssertEqual(a.log, ["stop", "stop"]); XCTAssertEqual(v.log, ["play /v.mp4 0.0", "stop"])
    }
}
