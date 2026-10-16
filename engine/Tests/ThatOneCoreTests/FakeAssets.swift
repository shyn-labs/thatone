import CoreGraphics
import Foundation
import ImageIO
@testable import ThatOneCore

/// A pretend Photos library: a dictionary of assets, each with a generated picture of a chosen width.
final class FakeAssetProvider: AssetProvider {
    var auth: AssetAuthorization = .authorized
    var enumerateFailure: Error?
    var assets: [String: AssetInfo] = [:]
    var widths: [String: Int] = [:]
    var cloud = Set<String>()
    var loadFailures: [String: String] = [:]
    private(set) var loads: [String] = []
    var onLoad: ((String) -> Void)?
    var onInfo: ((String) -> Void)?

    @discardableResult
    func add(_ id: String, filename: String = "IMG.JPG", width: Int, mtime: Int64 = 1000, video: Bool = false) -> String {
        let info = AssetInfo(id: id, filename: filename, mtime: mtime, pixels: Int64(width * 100), isVideo: video)
        assets[id] = info
        widths[id] = width
        return info.path
    }

    func authorization() -> AssetAuthorization { auth }
    func enumerate() throws -> [AssetInfo] {
        if let enumerateFailure { throw enumerateFailure }
        return assets.values.sorted { $0.id < $1.id }
    }
    func info(id: String) -> AssetInfo? {
        defer { onInfo?(id) }
        return assets[id]
    }

    func loadImage(id: String, maxSide: Int) -> AssetImage {
        loads.append(id)
        onLoad?(id)
        if cloud.contains(id) { return .inCloud }
        if let why = loadFailures[id] { return .failed(why) }
        guard let width = widths[id] else { return .failed("no such asset") }
        return .image(FakeAssetProvider.picture(width: width))
    }

    static func picture(width: Int) -> CGImage {
        let url = TestSupport.tempDir("asset").appendingPathComponent("a.png")
        try! makeImage(width: width, height: 100, text: nil, at: url)
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCreateImageAtIndex(source, 0, nil)!
    }
}
