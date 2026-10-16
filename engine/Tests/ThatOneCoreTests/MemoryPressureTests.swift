import XCTest
@testable import ThatOneCore

final class MemoryPressureTests: XCTestCase {
    func testFreeMemoryPercentageMapsToLevels() {
        XCTAssertEqual(SystemMemoryPressure.level(forFreePercentage: 60), .normal)
        XCTAssertEqual(SystemMemoryPressure.level(forFreePercentage: 15), .normal)
        XCTAssertEqual(SystemMemoryPressure.level(forFreePercentage: 14), .warning)
        XCTAssertEqual(SystemMemoryPressure.level(forFreePercentage: 8), .warning)
        XCTAssertEqual(SystemMemoryPressure.level(forFreePercentage: 7), .critical)
        XCTAssertEqual(SystemMemoryPressure.level(forFreePercentage: 0), .critical)
        XCTAssertEqual(SystemMemoryPressure.level(forFreePercentage: nil), .normal)          // unknown never blocks work
    }

    func testLevelsAreOrderedAndTheSystemSourceCanBeRead() {
        XCTAssertTrue(MemoryPressureLevel.normal < .warning && MemoryPressureLevel.warning < .critical)
        let source = SystemMemoryPressure()
        _ = source.level
        source.onChange { _ in }
        if let percentage = SystemMemoryPressure.freePercentage() { XCTAssertTrue((0...100).contains(percentage)) }
    }
}
