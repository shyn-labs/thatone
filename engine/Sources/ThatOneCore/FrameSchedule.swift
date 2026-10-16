import Foundation

/// Which moments of a video get a frame: one per `step` seconds, taken mid-interval (the first frame is often black).
public enum FrameSchedule {
    public static func plan(duration: Double) -> (step: Double, times: [Double]) {
        let step = max(ReadLimits.minFrameStep, duration / Double(ReadLimits.maxFrames))
        guard duration.isFinite, duration > 0.05 else { return (step.isFinite ? step : ReadLimits.minFrameStep, []) }
        var times: [Double] = []
        var k = 0.0
        while step / 2 + k * step < duration && times.count < ReadLimits.maxFrames {
            times.append(step / 2 + k * step)
            k += 1
        }
        if times.isEmpty { times = [duration / 2] }
        return (step, times)
    }

    /// "" at the default step, otherwise what the sampling cost, e.g. "one frame every 15 s".
    public static func note(step: Double) -> String {
        step <= ReadLimits.minFrameStep ? "" : "one frame every \(Int(step.rounded(.up))) s"
    }
}
