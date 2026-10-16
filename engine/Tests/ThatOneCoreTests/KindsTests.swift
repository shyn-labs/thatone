import XCTest
@testable import ThatOneCore

final class KindsTests: XCTestCase {
    func testDetectIsCaseInsensitiveAndByExtensionOnly() {
        XCTAssertEqual(Kinds.detect("/a/B.PDF"), "pdf")
        XCTAssertEqual(Kinds.detect("/a/b.DocX"), "document")
        XCTAssertEqual(Kinds.detect("/a/b.rtf"), "document")
        XCTAssertEqual(Kinds.detect("/a/b.odt"), "document")
        XCTAssertEqual(Kinds.detect("/a/b.doc"), "document")
        XCTAssertEqual(Kinds.detect("/a/notes.MD"), "text")
        XCTAssertEqual(Kinds.detect("/a/page.htm"), "text")
        XCTAssertEqual(Kinds.detect("/a/photo.HEIC"), "image")
        XCTAssertNil(Kinds.detect("/a/photo.png.bak"))
        XCTAssertNil(Kinds.detect("/a/noextension"))
        XCTAssertNil(Kinds.detect("/a/archive.zip"))
    }

    func testAudioIsDetectedAndOffByDefault() {
        for ext in ["mp3", "WAV", "m4a", "aac", "flac", "ogg", "opus", "caf", "aiff", "aif"] { XCTAssertEqual(Kinds.detect("/a/clip.\(ext)"), "audio", ext) }
        XCTAssertFalse(Kinds.defaultEnabled.contains("audio"))
        XCTAssertNil(Kinds.detect("/a/clip.mp3.txt.bak"))
    }

    func testWhisperFolderRoundTrips() throws {
        let url = TestSupport.tempDir().appendingPathComponent("config.json")
        try Config(whisperFolder: "/models/whisper").save(to: url)
        XCTAssertEqual(try Config.load(from: url).whisperFolder, "/models/whisper")
        try Data("{}".utf8).write(to: url)
        XCTAssertNil(try Config.load(from: url).whisperFolder)
    }

    func testPlainTextLikeFilesAreOffByDefault() {
        XCTAssertEqual(Kinds.defaultEnabled, ["image", "pdf", "document"])
        XCTAssertEqual(Set(Kinds.all), ["image", "pdf", "document", "text", "audio", "video"])
        XCTAssertEqual(Config().kinds, Kinds.defaultEnabled)
    }

    func testConfigKindsRoundTripAndTolerateOldAndUnknownValues() throws {
        let url = TestSupport.tempDir().appendingPathComponent("config.json")
        try Config(kinds: ["pdf", "text"]).save(to: url)
        XCTAssertEqual(try Config.load(from: url).kinds, ["pdf", "text"])
        try Data("{}".utf8).write(to: url)
        XCTAssertEqual(try Config.load(from: url).kinds, Kinds.defaultEnabled)                      // an older config
        try Data(#"{"kinds":["pdf","spreadsheet"]}"#.utf8).write(to: url)
        XCTAssertEqual(try Config.load(from: url).kinds, ["pdf"])                                    // unknown names ignored
        try Data(#"{"kinds":[]}"#.utf8).write(to: url)
        XCTAssertEqual(try Config.load(from: url).kinds, [])                                         // switching everything off is allowed
    }
}
