import Photos
import ThatOneCore
import XCTest
@testable import ThatOneApp

final class PhotosAccessTests: XCTestCase {
    func testAuthorizationStatesMapToUserFacingStates() {
        XCTAssertEqual(PhotosState.state(enabled: false, authorization: .authorized), .off)
        XCTAssertEqual(PhotosState.state(enabled: true, authorization: .notDetermined), .needsPermission)
        XCTAssertEqual(PhotosState.state(enabled: true, authorization: .denied), .denied)
        XCTAssertEqual(PhotosState.state(enabled: true, authorization: .restricted), .restricted)
        XCTAssertEqual(PhotosState.state(enabled: true, authorization: .limited), .on(limited: true))
        XCTAssertEqual(PhotosState.state(enabled: true, authorization: .authorized), .on(limited: false))
    }

    func testPhotoKitStatusesMapToEngineAuthorization() {
        XCTAssertEqual(PhotosAccess.map(.authorized), .authorized)
        XCTAssertEqual(PhotosAccess.map(.limited), .limited)
        XCTAssertEqual(PhotosAccess.map(.denied), .denied)
        XCTAssertEqual(PhotosAccess.map(.restricted), .restricted)
        XCTAssertEqual(PhotosAccess.map(.notDetermined), .notDetermined)
    }

    func testScriptEscapesHostileIdentifiers() {
        let script = ShowInPhotos.script(forAssetID: #"AB"C\D/L0/001"# + "\" & (do shell script \"x\") & \"")
        XCTAssertTrue(script.contains(#"spotlight media item id "AB\"C\\D/L0/001\" & (do shell script \"x\") & \"""#), script)
        XCTAssertFalse(script.contains("\"x\") &\n"))
        XCTAssertEqual(ShowInPhotos.script(forAssetID: "A/L0/001").components(separatedBy: "\n").count, 4)
    }
}
