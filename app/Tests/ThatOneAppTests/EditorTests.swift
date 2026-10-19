import AppKit
import ThatOneCore
import XCTest
@testable import ThatOneApp

/// Stands in for NSWorkspace: records what would be opened, launches nothing.
final class FakeWorkspace: Workspacing {
    var handlers: [String: URL] = [:]          // URL scheme -> the app that answers it
    var installed: Set<String> = []
    var openResult: (URL) -> Bool = { _ in true }
    private(set) var opened: [URL] = []
    private(set) var revealed: [[URL]] = []
    func open(_ url: URL) -> Bool { opened.append(url); return openResult(url) }
    func urlForApplication(toOpen url: URL) -> URL? { url.scheme.flatMap { handlers[$0] } }
    func urlForApplication(withBundleIdentifier id: String) -> URL? { installed.contains(id) ? URL(fileURLWithPath: "/Applications/\(id).app") : nil }
    func activateFileViewerSelecting(_ fileURLs: [URL]) { revealed.append(fileURLs) }
}

final class EditorTests: XCTestCase {
    let board = NSPasteboard(name: NSPasteboard.Name("com.shynlabs.thatone.test.\(UUID().uuidString)"))
    override func tearDown() { board.releaseGlobally() }
    func actions(_ ws: FakeWorkspace, editor: String?) -> FileActions {
        FileActions(workspace: ws, pasteboard: board, showInPhotos: { _ in }, editor: { editor })
    }

    func testResolve() {
        XCTAssertEqual(Editor.resolve(nil, isInstalled: { _ in false }), "default")
        XCTAssertEqual(Editor.resolve(nil, isInstalled: { $0 == Editor.vscodeBundleID }), "vscode")
        XCTAssertEqual(Editor.resolve("zed", isInstalled: { _ in false }), "zed")
        XCTAssertEqual(Editor.resolve("emacs", isInstalled: { _ in false }), "default")
    }

    func testLinksEncodeThePath() {
        XCTAssertEqual(Editor.link(editor: "vscode", path: "/tmp/My Repo/a#b.ts", line: 42)?.absoluteString, "vscode://file/tmp/My%20Repo/a%23b.ts:42")
        XCTAssertEqual(Editor.link(editor: "zed", path: "/tmp/r/a.ts", line: 0)?.absoluteString, "zed://file/tmp/r/a.ts:1")
        XCTAssertNil(Editor.link(editor: "default", path: "/tmp/r/a.ts", line: 3))
    }

    func testCodeOpensAtTheLineInVSCodeWhenItAnswers() {
        let ws = FakeWorkspace()
        ws.handlers["vscode"] = URL(fileURLWithPath: "/Applications/VSCode.app"); ws.installed = [Editor.vscodeBundleID]
        XCTAssertTrue(actions(ws, editor: nil).open("/tmp/r/a.ts", kind: "code", line: 42))
        XCTAssertEqual(ws.opened.map { $0.absoluteString }, ["vscode://file/tmp/r/a.ts:42"])
    }

    func testZedWhenChosen() {
        let ws = FakeWorkspace(); ws.handlers["zed"] = URL(fileURLWithPath: "/Applications/Zed.app")
        XCTAssertTrue(actions(ws, editor: "zed").open("/tmp/r/a.ts", kind: "code", line: 7))
        XCTAssertEqual(ws.opened.map { $0.absoluteString }, ["zed://file/tmp/r/a.ts:7"])
    }

    func testNoHandlerOrAFailedEditorFallsBackToTheDefaultApp() {
        let none = FakeWorkspace()
        XCTAssertTrue(actions(none, editor: "zed").open("/tmp/r/a.ts", kind: "code", line: 7))
        XCTAssertEqual(none.opened, [URL(fileURLWithPath: "/tmp/r/a.ts")])
        let failing = FakeWorkspace(); failing.handlers["vscode"] = URL(fileURLWithPath: "/Applications/VSCode.app")
        failing.openResult = { $0.scheme != "vscode" }
        XCTAssertTrue(actions(failing, editor: "vscode").open("/tmp/r/a.ts", kind: "code", line: 7))
        XCTAssertEqual(failing.opened.map { $0.scheme }, ["vscode", "file"])
    }

    func testDefaultChoiceAndOtherKindsOpenTheFile() {
        let ws = FakeWorkspace(); ws.handlers["vscode"] = URL(fileURLWithPath: "/Applications/VSCode.app"); ws.installed = [Editor.vscodeBundleID]
        XCTAssertTrue(actions(ws, editor: "default").open("/tmp/r/a.ts", kind: "code", line: 7))
        XCTAssertTrue(actions(ws, editor: nil).open("/tmp/r/a.pdf", kind: "pdf", line: nil))
        XCTAssertEqual(ws.opened, [URL(fileURLWithPath: "/tmp/r/a.ts"), URL(fileURLWithPath: "/tmp/r/a.pdf")])
    }

    func testAFailureEverywhereIsReported() {
        let ws = FakeWorkspace(); ws.openResult = { _ in false }
        XCTAssertFalse(actions(ws, editor: nil).open("/tmp/r/a.ts", kind: "code", line: 1))
    }
}
