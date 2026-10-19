import XCTest
@testable import ThatOneCore

final class EditorConfigTests: XCTestCase {
    func testEditorRoundTripsAndUnknownValuesAreIgnored() throws {
        let url = TestSupport.tempDir().appendingPathComponent("config.json")
        try Config(editor: "zed").save(to: url)
        XCTAssertEqual(try Config.load(from: url).editor, "zed")
        try Data(#"{"editor":"emacs"}"#.utf8).write(to: url)
        XCTAssertNil(try Config.load(from: url).editor)
        try Data("{}".utf8).write(to: url)
        XCTAssertNil(try Config.load(from: url).editor)
    }

    func testSetEditorPersistsAndRefusesUnknownEditors() throws {
        let e = try CodeIndexingTests.makeEngine()
        try e.setEditor("default")
        XCTAssertEqual(try Config.load(from: e.paths.config).editor, "default")
        XCTAssertThrowsError(try e.setEditor("emacs")) { XCTAssertEqual($0 as? EngineError, .unknownEditor("emacs")) }
        try e.setEditor(nil)
        XCTAssertNil(e.config.editor)
    }
}
