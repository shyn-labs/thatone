import XCTest
@testable import ThatOneApp

final class PowerPolicyTests: XCTestCase {
    func testLowPowerModeAlwaysPauses() {
        XCTAssertEqual(PowerPolicy.pauseReason(lowPowerMode: true, onBattery: false, batteryLevel: 1), "Low Power Mode is on")
    }

    func testLowBatteryPausesOnlyWhenUnplugged() {
        XCTAssertEqual(PowerPolicy.pauseReason(lowPowerMode: false, onBattery: true, batteryLevel: 0.19), "battery is below 20%")
        XCTAssertNil(PowerPolicy.pauseReason(lowPowerMode: false, onBattery: true, batteryLevel: 0.20))
        XCTAssertNil(PowerPolicy.pauseReason(lowPowerMode: false, onBattery: false, batteryLevel: 0.05))   // charging
    }

    func testUnknownBatteryNeverPauses() {
        XCTAssertNil(PowerPolicy.pauseReason(lowPowerMode: false, onBattery: true, batteryLevel: nil))     // a desktop Mac
    }

    func testReadingTheRealPowerStateDoesNotCrash() {
        _ = PowerPolicy.currentReason()
    }
}
