import XCTest
@testable import ThatOneApp

final class AppVersionTests: XCTestCase {
    func testVersionAndBundleIdentifier() {
        XCTAssertTrue(AppVersion.string.hasPrefix("0.2.0"))
        XCTAssertEqual(AppVersion.bundleIdentifier, "com.shynlabs.thatone")
    }
}
