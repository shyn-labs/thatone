import AppKit
import Photos
import ThatOneCore

/// Apple Photos through PhotoKit. Every call blocks, so none may run on the main thread. Nothing here touches the
/// network: an original that lives only in iCloud is reported as such, never downloaded.
public final class PhotoKitProvider: AssetProvider {
    private let manager = PHImageManager.default()

    public init() {}

    public func authorization() -> AssetAuthorization { PhotosAccess.current() }

    public func enumerate() throws -> [AssetInfo] {
        guard [.authorized, .limited].contains(authorization()) else { throw ServiceError.remote("Photos access was not granted") }
        // An unmounted or migrating library must read as "cannot read", never as "empty".
        if PHPhotoLibrary.shared().unavailabilityReason != nil { throw ServiceError.remote("the Photos library is not available right now") }
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                        PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        let result = PHAsset.fetchAssets(with: options)
        var assets: [AssetInfo] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(Self.info(for: asset)) }
        return assets
    }

    public func info(id: String) -> AssetInfo? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject.map(Self.info(for:))
    }

    public func loadImage(id: String, maxSide: Int) -> AssetImage {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return .failed("asset not found") }
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.version = .current
        var image: NSImage?
        var inCloud = false
        var problem: String?
        manager.requestImage(for: asset, targetSize: CGSize(width: maxSide, height: maxSide), contentMode: .aspectFit,
                             options: options) { result, info in
            image = result
            inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) == true
            if let error = info?[PHImageErrorKey] as? NSError { problem = error.localizedDescription }
        }
        if let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) { return .image(cg) }
        return inCloud ? .inCloud : .failed(problem ?? "no image returned")
    }

    private static func info(for asset: PHAsset) -> AssetInfo {
        let name = (asset.value(forKey: "filename") as? String)
            ?? PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "photo"
        let date = asset.modificationDate ?? asset.creationDate ?? Date(timeIntervalSince1970: 0)
        return AssetInfo(id: asset.localIdentifier, filename: name.isEmpty ? "photo" : name, mtime: Int64(date.timeIntervalSince1970),
                         pixels: Int64(asset.pixelWidth) * Int64(asset.pixelHeight), isVideo: asset.mediaType != .image)
    }
}

/// Tells the host when the Photos library changed (a photo added, edited or deleted).
public final class PhotosChangeWatcher: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: () -> Void
    private var registered = false

    public init(onChange: @escaping () -> Void) { self.onChange = onChange }

    /// Only after access was granted.
    public func start() {
        guard !registered else { return }
        PHPhotoLibrary.shared().register(self)
        registered = true
    }

    public func stop() {
        guard registered else { return }
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        registered = false
    }

    public func photoLibraryDidChange(_ changeInstance: PHChange) { onChange() }
}

extension PhotosChangeWatcher: PhotosWatching {
    /// Lets the host hold the PhotoKit watcher as a `PhotosWatching`.
    func asWatching() -> PhotosWatching { self }
}
