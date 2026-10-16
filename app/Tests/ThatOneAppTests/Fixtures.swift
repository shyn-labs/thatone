import CoreGraphics
import CoreText
import Foundation
import ImageIO
import ThatOneCore
import UniformTypeIdentifiers
import XCTest
@testable import ThatOneApp

enum Fixtures {
    static let key = Data(repeating: 7, count: 32)

    static func tempDir(_ label: String = "t") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("thatone-app-\(label)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Unix socket paths are limited to 103 bytes.
    static func shortDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("th-" + String(UInt32.random(in: 0...0xFFFFFF), radix: 16))
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func writePNG(width: Int, height: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    static func makeEngine(home: URL? = nil, embedder: Embedder = AppFakeEmbedder(),
                           ocr: @escaping (CGImage) throws -> String = { _ in "words" }) throws -> Engine {
        try Engine(paths: Paths(home: home ?? tempDir("home")), config: Config(), keyProvider: StaticKeyProvider(key),
                   embedder: embedder, ocr: ocr)
    }
}

/// Deterministic in-process embedder: text becomes a hashed bag of words, an image is seeded by its bytes.
final class AppFakeEmbedder: Embedder {
    static let dim = 16
    private let lock = NSLock()
    private var _calls = 0
    var failure: Error?
    var delay: TimeInterval = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }

    func info() throws -> SidecarClient.Info { SidecarClient.Info(model: "fake", dim: Self.dim, modalities: ["text", "image"]) }

    func embed(_ modality: EmbedModality, role: EmbedRole, inputs: [String]) throws -> [[Float]] {
        lock.lock(); _calls += 1; let failure = self.failure; lock.unlock()
        if let failure { throw failure }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return inputs.map { input in
            if modality == .image {
                let bytes = FileManager.default.contents(atPath: input) ?? Data(input.utf8)
                return Self.vector(for: "img\(bytes.hashValue)")
            }
            return Self.vector(for: input)
        }
    }

    static func vector(for text: String) -> [Float] {
        var v = [Float](repeating: 0.01, count: dim)
        for word in Tokens.words(text) {
            var h: UInt64 = 1469598103934665603
            for b in word.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
            v[Int(h % UInt64(dim))] += 1
        }
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return v.map { $0 / norm }
    }
}

/// Polls `condition` until it is true or the timeout passes.
func eventually(timeout: Double = 20, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
    return condition()
}

/// A pretend Photos library for the host tests.
final class AppFakeAssets: AssetProvider {
    var auth: AssetAuthorization = .authorized
    var assets: [String: AssetInfo] = [:]
    var widths: [String: Int] = [:]
    var failEnumerate = false

    @discardableResult
    func add(_ id: String, filename: String = "IMG.JPG", width: Int, mtime: Int64 = 1000) -> String {
        let info = AssetInfo(id: id, filename: filename, mtime: mtime, pixels: Int64(width * 100))
        assets[id] = info
        widths[id] = width
        return info.path
    }

    func authorization() -> AssetAuthorization { auth }
    func enumerate() throws -> [AssetInfo] {
        if failEnumerate { throw ServiceError.remote("busy") }
        return assets.values.sorted { $0.id < $1.id }
    }
    func info(id: String) -> AssetInfo? { assets[id] }
    func loadImage(id: String, maxSide: Int) -> AssetImage {
        guard let width = widths[id] else { return .failed("missing") }
        let url = Fixtures.tempDir("asset").appendingPathComponent("a.png")
        try! Fixtures.writePNG(width: width, height: 100, to: url)
        return .image(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!)
    }
}

final class FakeWatcher: PhotosWatching {
    private(set) var started = 0, stopped = 0
    func start() { started += 1 }
    func stop() { stopped += 1 }
}

/// One-page text PDFs for the host tests.
enum PDFFixturesApp {
    static func make(_ text: String, at url: URL) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 12, nil)]))
        context.textPosition = CGPoint(x: 36, y: 740)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
    }
}

/// A memory-pressure source the test controls (and a host test never depends on the machine's real memory).
final class FakeMemory: MemoryPressureSource {
    private let lock = NSLock()
    private var current = MemoryPressureLevel.normal
    private var handlers: [(MemoryPressureLevel) -> Void] = []
    var level: MemoryPressureLevel { lock.lock(); defer { lock.unlock() }; return current }
    func onChange(_ handler: @escaping (MemoryPressureLevel) -> Void) { lock.lock(); handlers.append(handler); lock.unlock() }
    func set(_ level: MemoryPressureLevel) {
        lock.lock(); current = level; let all = handlers; lock.unlock()
        for handler in all { handler(level) }
    }
}
