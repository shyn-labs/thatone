import AVFoundation
import CoreGraphics
import Foundation

/// Cuts one frame of a video to a JPEG for the embedder. Called by the indexer only after the secret gate, a group at a time.
public protocol FrameCutting {
    /// true: a JPEG (long side at most `maxSide`) was written to `destination`. false: this frame is blank or cannot be
    /// decoded, so it is skipped (not a file failure). A thrown `ReadFailure` fails the whole file; any other error is
    /// the environment (disk full, media services reset, decoder temporarily unavailable) and the file waits.
    func cut(source: URL, time: Double, maxSide: Int, to destination: URL) throws -> Bool
    /// Forgets which files stalled (the user asked to retry failed files).
    func resetBreaker()
}

extension FrameCutting {
    public func resetBreaker() {}
}

/// Cuts nothing: every frame is skipped, so a video is indexed by its soundtrack alone.
public struct NoFrameCutter: FrameCutting {
    public init() {}
    public func cut(source: URL, time: Double, maxSide: Int, to destination: URL) throws -> Bool { false }
}

/// Near-duplicate frames, dropped by embedding similarity.
public enum FrameDedupe {
    /// Cosine similarity, without assuming the vectors are normalized. A vector with no direction (all zeros) is
    /// similar to nothing (0); so are two vectors of different lengths (never truncated into a match).
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var dot: Float = 0, aa: Float = 0, bb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; aa += a[i] * a[i]; bb += b[i] * b[i] }
        let norms = aa.squareRoot() * bb.squareRoot()
        return norms > 0 && norms.isFinite ? dot / norms : 0
    }

    /// A vector with a direction and only finite components. Anything else is not a picture's embedding.
    static func usable(_ v: [Float]) -> Bool {
        !v.isEmpty && v.allSatisfy(\.isFinite) && v.contains { $0 != 0 }
    }

    /// Indices of `vectors` (frames in time order) to keep: the first usable frame, then each usable frame whose cosine
    /// to the last kept one is below `threshold`. `last` is the last frame kept by an earlier group, if any. An unusable
    /// vector (all zeros, NaN or infinite) is never kept and never becomes the comparison base.
    public static func kept(_ vectors: [[Float]], after last: [Float]? = nil,
                            threshold: Float = ReadLimits.frameDuplicateCosine) -> [Int] {
        var previous = last                                  // an unusable base compares as 0: no base
        var keep: [Int] = []
        for (i, vector) in vectors.enumerated() {
            guard usable(vector) else { continue }
            if let previous, cosine(vector, previous) >= threshold { continue }
            keep.append(i)
            previous = vector
        }
        return keep
    }
}

/// An environment problem while cutting a frame (not the file's fault): the file waits and is tried again.
public enum FrameCutError: Error, Equatable {
    case cannotWrite(String)
    case mediaServices(String)
}

/// Frames with AVFoundation: upright (the track's preferred transform applied), long side at most `maxSide`, the nearest
/// keyframe within a second (fast), blank frames dropped, each frame bounded in time.
public final class AVFrameCutter: FrameCutting {
    private let timeout: Double
    private let lock = NSLock()
    /// Timeouts per file (path, plus the size and date it had), oldest first; at most `breakerLimit` files remembered.
    private var timeouts: [(key: String, count: Int)] = []
    private var started = 0
    static let breakerLimit = 64

    /// `timeout`: seconds one frame may take before it is skipped. A second timeout in the same file fails the file
    /// (`ReadFailure.timedOut`), and later cuts of it fail at once, so a stalled decoder costs at most two timeouts.
    public init(timeout: Double = 20) { self.timeout = timeout }

    /// Generations started so far (each one an AVAssetImageGenerator request).
    public var generationsStarted: Int { lock.lock(); defer { lock.unlock() }; return started }
    /// Files the breaker currently remembers.
    public var breakerCount: Int { lock.lock(); defer { lock.unlock() }; return timeouts.count }
    public func resetBreaker() { lock.lock(); timeouts = []; lock.unlock() }

    private static func key(_ path: String) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(path)|\(size)|\(date)"                  // a changed file starts afresh
    }

    private func timeoutCount(_ key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return timeouts.first { $0.key == key }?.count ?? 0
    }

    /// Records a timeout for `key` and returns how many that file has had.
    @discardableResult
    func noteTimeout(path key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        if let i = timeouts.firstIndex(where: { $0.key == key }) { timeouts[i].count += 1; return timeouts[i].count }
        timeouts.append((key, 1))
        if timeouts.count > Self.breakerLimit { timeouts.removeFirst(timeouts.count - Self.breakerLimit) }
        return 1
    }

    public func cut(source: URL, time: Double, maxSide: Int, to destination: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: source.path) else { throw ReadFailure.unreadable("cannot read this video") }
        let key = Self.key(source.path)
        guard timeoutCount(key) < 2 else { throw ReadFailure.timedOut }            // tripped: no new generation
        final class Box: @unchecked Sendable {
            var value: Result<CGImage?, Error>?
            var generator: AVAssetImageGenerator?
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let side = CGFloat(max(maxSide, 1))
        let asset = AVURLAsset(url: source)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: side, height: side)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1.0, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1.0, preferredTimescale: 600)
        box.generator = generator
        lock.lock(); started += 1; lock.unlock()
        let task = Task.detached {
            do {
                guard let generator = box.generator else { throw CancellationError() }
                let duration = try await generator.asset.load(.duration).seconds
                guard duration.isFinite, time >= 0, time <= duration else { box.value = .success(nil); done.signal(); return }
                let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
                box.value = .success(image)
            } catch { box.value = .failure(error) }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success, let result = box.value else {
            // Timed out: stop the work and let go of it, then skip this frame, or fail the file on its second timeout.
            generator.cancelAllCGImageGeneration()
            task.cancel()
            box.generator = nil
            if noteTimeout(path: key) >= 2 { throw ReadFailure.timedOut }
            return false
        }
        box.generator = nil
        let image: CGImage
        switch result {
        case .success(let made?): image = made
        case .success(nil): return false                        // past the end
        case .failure(let error):
            if Self.isEnvironmentError(error) { throw FrameCutError.mediaServices(String(describing: error).prefix(120).description) }
            return false                                         // this frame cannot be decoded: skip it, not the file
        }
        guard !Self.isBlank(image) else { return false }
        do { try ImagePrep.writeJPEG(image, to: destination) }
        catch { throw FrameCutError.cannotWrite(String(describing: error).prefix(120).description) }
        return true
    }

    /// AVFoundation errors that say the machine, not the file, is the problem right now: the file waits instead of being
    /// stored without its frames. Codes, since not all of them are exposed to Swift on macOS:
    /// -11819 AVErrorMediaServicesWereReset, -11839 AVErrorDecoderTemporarilyUnavailable (VideoToolbox under memory
    /// pressure), -11847 AVErrorOperationInterrupted.
    static let environmentErrorCodes: Set<Int> = [-11819, -11839, -11847]

    static func isEnvironmentError(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == AVFoundationErrorDomain && environmentErrorCodes.contains(ns.code)
    }

    /// One flat colour (a fade, a black screen): the brightest and darkest of a 16x16 grey downscale are within
    /// `ReadLimits.blankFrameSpread` of each other.
    public static func isBlank(_ image: CGImage) -> Bool {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn, let low = pixels.min(), let high = pixels.max() else { return false }
        return Int(high) - Int(low) <= ReadLimits.blankFrameSpread
    }
}
