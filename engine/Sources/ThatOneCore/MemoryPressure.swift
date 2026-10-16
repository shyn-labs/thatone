import Darwin
import Foundation

public enum MemoryPressureLevel: Int, Comparable {
    case normal = 0, warning, critical
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// How short of memory the Mac is right now. Indexing loads multi-gigabyte models, so it steps aside when memory is tight
/// instead of pushing the machine into swap.
public protocol MemoryPressureSource: AnyObject {
    var level: MemoryPressureLevel { get }
    /// Called (on an arbitrary queue) whenever the level may have changed.
    func onChange(_ handler: @escaping (MemoryPressureLevel) -> Void)
}

public final class SystemMemoryPressure: MemoryPressureSource {
    private let source: DispatchSourceMemoryPressure
    private let lock = NSLock()
    private var eventLevel = MemoryPressureLevel.normal
    private var handlers: [(MemoryPressureLevel) -> Void] = []

    public init() {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let data = self.source.data
            self.lock.lock()
            self.eventLevel = data.contains(.critical) ? .critical : data.contains(.warning) ? .warning : .normal
            let current = self.handlers
            self.lock.unlock()
            let now = self.level
            for handler in current { handler(now) }
        }
        source.resume()
    }

    deinit { source.cancel() }

    /// The worse of the system's pressure events and its free-memory percentage (`kern.memorystatus_level`, the number
    /// `memory_pressure` prints as "free percentage"): below 15 percent is a warning, below 8 critical.
    public var level: MemoryPressureLevel {
        lock.lock(); let event = eventLevel; lock.unlock()
        return max(event, Self.level(forFreePercentage: Self.freePercentage()))
    }

    public func onChange(_ handler: @escaping (MemoryPressureLevel) -> Void) {
        lock.lock(); handlers.append(handler); lock.unlock()
    }

    public static func level(forFreePercentage percentage: Int?) -> MemoryPressureLevel {
        guard let percentage else { return .normal }
        return percentage < 8 ? .critical : percentage < 15 ? .warning : .normal
    }

    static func freePercentage() -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &value, &size, nil, 0) == 0, value >= 0, value <= 100 else { return nil }
        return Int(value)
    }
}
