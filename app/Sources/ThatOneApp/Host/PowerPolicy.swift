import Foundation
import IOKit.ps

public enum PowerPolicy {
    public static let minimumBatteryLevel = 0.20

    /// Why background indexing should wait, or nil when it may run.
    public static func pauseReason(lowPowerMode: Bool, onBattery: Bool, batteryLevel: Double?) -> String? {
        if lowPowerMode { return "Low Power Mode is on" }
        if onBattery, let level = batteryLevel, level < minimumBatteryLevel { return "battery is below 20%" }
        return nil
    }

    public static func currentReason() -> String? {
        let battery = batteryState()
        return pauseReason(lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                           onBattery: battery.onBattery, batteryLevel: battery.level)
    }

    /// `level` is 0...1, nil on a Mac without a battery.
    static func batteryState() -> (onBattery: Bool, level: Double?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (false, nil) }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue
            let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue
            let level = current.flatMap { c in maximum.flatMap { $0 > 0 ? c / $0 : nil } }
            return (onBattery, level)
        }
        return (false, nil)
    }
}
