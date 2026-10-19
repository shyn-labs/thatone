import XCTest
@testable import ThatOneApp

final class KindSwitchTests: XCTestCase {
    func testTogglingAddsAndRemovesAndIgnoresUnknownKinds() {
        XCTAssertEqual(KindSwitch.toggled(["image"], "pdf", on: true), ["image", "pdf"])
        XCTAssertEqual(KindSwitch.toggled(["image", "pdf"], "image", on: false), ["pdf"])
        XCTAssertEqual(KindSwitch.toggled(["image"], "spreadsheet", on: true), ["image"])
        XCTAssertEqual(KindSwitch.toggled([], "image", on: false), [])
    }

    func testTextLikeFilesCarryAWarningAndTheSwitchesCoverEveryKind() {
        XCTAssertEqual(KindSwitch.all.map { $0.kind }, ["image", "pdf", "document", "audio", "video", "text", "code"])
        XCTAssertNotNil(KindSwitch.all.first { $0.kind == "text" }?.note)
        XCTAssertNil(KindSwitch.all.first { $0.kind == "pdf" }?.note)
    }
}
