import XCTest
@testable import ThatOneApp

final class KeyCommandTests: XCTestCase {
    func press(_ key: String, cmd: Bool = false, shift: Bool = false, opt: Bool = false, ctrl: Bool = false) -> KeyPress {
        KeyPress(key: key, command: cmd, shift: shift, option: opt, control: ctrl)
    }

    func testArrowsAndReturn() {
        XCTAssertEqual(command(for: press("up"), queryIsEmpty: false), .up)
        XCTAssertEqual(command(for: press("down"), queryIsEmpty: false), .down)
        XCTAssertEqual(command(for: press("return"), queryIsEmpty: false), .open)
        XCTAssertEqual(command(for: press("return", cmd: true), queryIsEmpty: false), .reveal)
        XCTAssertNil(command(for: press("return", opt: true), queryIsEmpty: false))
    }

    func testCopyPathNeedsCommandShiftC() {
        XCTAssertEqual(command(for: press("c", cmd: true, shift: true), queryIsEmpty: false), .copyPath)
        XCTAssertNil(command(for: press("c", cmd: true), queryIsEmpty: false))       // plain copy stays a text-field copy
    }

    func testSpacePreviewsOnlyWhenTheQueryIsEmpty() {
        XCTAssertEqual(command(for: press("space"), queryIsEmpty: true), .preview)
        XCTAssertNil(command(for: press("space"), queryIsEmpty: false))
        XCTAssertEqual(command(for: press("y", cmd: true), queryIsEmpty: false), .preview)
    }

    func testMoreLikeTabAndEscape() {
        XCTAssertEqual(command(for: press("g", cmd: true), queryIsEmpty: false), .moreLike)
        XCTAssertEqual(command(for: press("tab"), queryIsEmpty: false), .cycleKind)
        XCTAssertEqual(command(for: press("escape"), queryIsEmpty: false), .close)
    }

    func testOtherKeysAreLeftToTheTextField() {
        XCTAssertNil(command(for: press("a"), queryIsEmpty: true))
        XCTAssertNil(command(for: press("down", ctrl: true), queryIsEmpty: false))
    }
}
