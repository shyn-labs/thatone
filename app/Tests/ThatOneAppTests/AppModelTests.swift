import ThatOneCore
import XCTest
@testable import ThatOneApp

@MainActor
final class AppModelTests: XCTestCase {
    func makeModel() throws -> AppModel {
        AppModel(engine: try Fixtures.makeEngine(), home: Fixtures.tempDir("h").path, power: { nil }, registersHotKey: false)
    }

    func testUiActionsAreRoutedAndUnknownOnesRejected() throws {
        let model = try makeModel()
        var shown: [String] = []
        model.windowHooks = { shown.append($0) }
        try model.host.ui(action: "show_panel")
        try model.host.ui(action: "show_window")
        XCTAssertEqual(shown, ["show_panel", "show_window"])
        XCTAssertThrowsError(try model.host.ui(action: "explode")) {
            guard case .unsupported? = $0 as? ServiceError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(shown.count, 2)
    }

    func testChangingTheHotKeySavesItToTheConfig() throws {
        let model = try makeModel()
        XCTAssertEqual(model.currentPreset, .default)
        model.setHotKey(.preset(id: "opt-space"))
        XCTAssertEqual(try model.savedHotKeyID(), "opt-space")
        XCTAssertEqual(model.currentPreset.id, "opt-space")
    }

    func testWelcomeIsNeededOnlyWithoutFolders() throws {
        let model = try makeModel()
        XCTAssertTrue(model.needsWelcome)
        let folder = Fixtures.tempDir("pics")
        _ = try model.host.index(folders: [folder.path])
        XCTAssertFalse(model.needsWelcome)
        model.shutdown()
    }

    func testExclusionsCanBeRemoved() throws {
        let model = try makeModel()
        let folder = Fixtures.tempDir("keep")
        try model.engine.exclude(folder.path)
        XCTAssertEqual(model.exclusions.count, 1)
        model.removeExclusion(folder.path)
        XCTAssertEqual(model.exclusions, [])
    }
}
