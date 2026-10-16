import CoreGraphics
import Foundation

/// How a photo from Apple Photos is named inside the index: `photos:<localIdentifier>/<original filename>`.
/// The identifier itself contains slashes, so the filename is everything after the LAST one. Nothing else may
/// treat these as file paths (no `stat`, no `RealPath`).
public enum PhotosPath {
    public static let scheme = "photos:"

    public static func make(id: String, filename: String) -> String { scheme + id + "/" + filename }
    public static func isPhotos(_ path: String) -> Bool { path.hasPrefix(scheme) }

    public static func parse(_ path: String) -> (id: String, filename: String)? {
        guard isPhotos(path) else { return nil }
        let rest = path.dropFirst(scheme.count)
        guard let slash = rest.lastIndex(of: "/") else { return nil }
        let id = String(rest[rest.startIndex..<slash])
        let filename = String(rest[rest.index(after: slash)...])
        return id.isEmpty || filename.isEmpty ? nil : (id, filename)
    }
}

public struct AssetInfo: Equatable {
    public let id: String
    public let filename: String
    public let mtime: Int64          // modification date, unix seconds
    public let pixels: Int64         // width * height: with mtime, the change signature
    public let isVideo: Bool
    public init(id: String, filename: String, mtime: Int64, pixels: Int64, isVideo: Bool = false) {
        self.id = id; self.filename = filename; self.mtime = mtime; self.pixels = pixels; self.isVideo = isVideo
    }
    public var path: String { PhotosPath.make(id: id, filename: filename) }
}

public enum AssetImage {
    case image(CGImage)
    case inCloud                     // the original is not on this Mac and no local copy exists
    case failed(String)
}

public enum AssetAuthorization: Equatable { case notDetermined, denied, restricted, limited, authorized }

/// A source of photos that are not files (Apple Photos). The app supplies the PhotoKit implementation; the engine
/// is tested against a fake.
public protocol AssetProvider: AnyObject {
    func authorization() -> AssetAuthorization
    /// Every non-hidden asset. Throws when the library cannot be read, so that a failure is never mistaken for an
    /// empty library.
    func enumerate() throws -> [AssetInfo]
    /// nil: the asset no longer exists.
    func info(id: String) -> AssetInfo?
    /// Never touches the network. Blocking: call it off the main thread.
    func loadImage(id: String, maxSide: Int) -> AssetImage
}

public enum AssetNotes {
    public static let video = "video (M4)"
    public static let inCloud = "iCloud original not on this Mac"
}
