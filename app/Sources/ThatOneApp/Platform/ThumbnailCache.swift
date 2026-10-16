import CoreGraphics
import Foundation
import QuickLookThumbnailing
import ThatOneCore

/// Quick Look thumbnails, cached by path, modified time and size, with concurrent requests shared.
public actor ThumbnailCache {
    public typealias Generator = @Sendable (String, CGFloat) async -> CGImage?

    private let generator: Generator
    private let capacity: Int
    private var images: [String: CGImage] = [:]
    private var order: [String] = []                           // oldest first
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    public init(capacity: Int = 400, generator: @escaping Generator = ThumbnailCache.quickLook) {
        self.capacity = capacity
        self.generator = generator
    }

    public func thumbnail(path: String, modified: Int64, side: CGFloat) async -> CGImage? {
        let key = "\(path)|\(modified)|\(Int(side))"
        if let hit = images[key] { return hit }
        if let running = inFlight[key] { return await running.value }
        let generator = generator
        let task = Task { await generator(path, side) }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {                                         // a missing file is not remembered: it may appear later
            images[key] = image
            order.append(key)
            while order.count > capacity { images[order.removeFirst()] = nil }
        }
        return image
    }

    /// Quick Look for files; PhotoKit for `photos:` paths (which are not files and must never be turned into URLs).
    public static func routed(photos: AssetProvider?) -> Generator {
        { path, side in
            guard let parsed = PhotosPath.parse(path) else { return await quickLook(path, side) }
            guard let photos else { return nil }
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    if case .image(let image) = photos.loadImage(id: parsed.id, maxSide: Int(side * 2)) { continuation.resume(returning: image) }
                    else { continuation.resume(returning: nil) }
                }
            }
        }
    }

    public static let quickLook: Generator = { path, side in
        let url = URL(fileURLWithPath: path)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: 2,
                                                   representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }
}
