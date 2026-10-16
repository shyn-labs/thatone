import AppKit
import Carbon.HIToolbox
import XCTest
@testable import ThatOneApp

final class PlatformTests: XCTestCase {
    func testPresetsAreUniqueAndTheDefaultIsControlOptionSpace() {
        XCTAssertEqual(HotKeyPreset.all.count, 4)
        XCTAssertEqual(Set(HotKeyPreset.all.map { $0.id }).count, 4)
        XCTAssertEqual(HotKeyPreset.default.id, "ctrl-opt-space")
        XCTAssertEqual(HotKeyPreset.default.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(HotKeyPreset.default.modifiers, UInt32(controlKey | optionKey))
        XCTAssertEqual(HotKeyPreset.preset(id: "opt-space").label, "⌥Space")
        XCTAssertEqual(HotKeyPreset.preset(id: "nonsense"), .default)
        XCTAssertEqual(HotKeyPreset.preset(id: nil), .default)
    }

    func testHotKeyRegistersAndUnregisters() {
        let hotKey = HotKey(keyCode: 40, modifiers: UInt32(controlKey | optionKey | cmdKey | shiftKey)) {}   // an unlikely combination
        XCTAssertEqual(hotKey.status, noErr)
        XCTAssertNil(hotKey.registrationError)
        hotKey.unregister()
    }

    func testHotKeyReportsRegistrationFailure() {
        let combo = UInt32(controlKey | optionKey | cmdKey | shiftKey)
        let first = HotKey(keyCode: 38, modifiers: combo) {}
        let second = HotKey(keyCode: 38, modifiers: combo) {}                 // the same key again: refused by the system
        defer { first.unregister(); second.unregister() }
        XCTAssertEqual(first.status, noErr)
        XCTAssertEqual(second.status, OSStatus(eventHotKeyExistsErr))
        XCTAssertEqual(second.registrationError, "already in use by another app")
    }

    // MARK: thumbnails

    final class Counter { private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n } }

    func tinyImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    func testThumbnailsAreCachedPerPathModifiedTimeAndSide() async {
        let counter = Counter()
        let image = tinyImage()
        let cache = ThumbnailCache(capacity: 10) { _, _ in counter.bump(); return image }
        _ = await cache.thumbnail(path: "/a.png", modified: 1, side: 64)
        _ = await cache.thumbnail(path: "/a.png", modified: 1, side: 64)
        XCTAssertEqual(counter.value, 1)
        _ = await cache.thumbnail(path: "/a.png", modified: 2, side: 64)       // the file changed
        _ = await cache.thumbnail(path: "/a.png", modified: 2, side: 128)      // a different size
        XCTAssertEqual(counter.value, 3)
    }

    func testConcurrentRequestsShareOneGeneration() async {
        let counter = Counter()
        let image = tinyImage()
        let cache = ThumbnailCache { _, _ in counter.bump(); try? await Task.sleep(nanoseconds: 150_000_000); return image }
        async let a = cache.thumbnail(path: "/a.png", modified: 1, side: 64)
        async let b = cache.thumbnail(path: "/a.png", modified: 1, side: 64)
        async let c = cache.thumbnail(path: "/a.png", modified: 1, side: 64)
        _ = await (a, b, c)
        XCTAssertEqual(counter.value, 1)
    }

    func testMissingFilesAreNotCachedAndOldEntriesAreEvicted() async {
        let counter = Counter()
        let image = tinyImage()
        let present = Counter()
        let cache = ThumbnailCache(capacity: 2) { path, _ in
            counter.bump()
            return (path as NSString).lastPathComponent == "missing.png" && present.value == 0 ? nil : image
        }
        let first = await cache.thumbnail(path: "/missing.png", modified: 1, side: 64)
        XCTAssertNil(first)
        present.bump()                                                         // the file appears
        let second = await cache.thumbnail(path: "/missing.png", modified: 1, side: 64)
        XCTAssertNotNil(second)
        XCTAssertEqual(counter.value, 2)                                       // nil was not remembered
        for name in ["b.png", "c.png"] { _ = await cache.thumbnail(path: "/\(name)", modified: 1, side: 64) }
        _ = await cache.thumbnail(path: "/missing.png", modified: 1, side: 64) // evicted by b and c: generated again
        XCTAssertEqual(counter.value, 5)
    }

    func testQuickLookMakesARealThumbnail() async throws {
        let url = Fixtures.tempDir("thumb").appendingPathComponent("a.png")
        try Fixtures.writePNG(width: 400, height: 300, to: url)
        let thumb = await ThumbnailCache().thumbnail(path: url.path, modified: 1, side: 128)
        XCTAssertNotNil(thumb)
        XCTAssertLessThanOrEqual(max(thumb?.width ?? 0, thumb?.height ?? 0), 256)      // 128 pt at 2x
    }

    // MARK: actions and login item

    func testCopyPathPutsThePathOnThePasteboard() {
        let board = NSPasteboard(name: NSPasteboard.Name("com.shynlabs.thatone.test.\(UUID().uuidString)"))
        FileActions(pasteboard: board).copyPath("/Users/me/it's \"x\".png")
        XCTAssertEqual(board.string(forType: .string), "/Users/me/it's \"x\".png")
        board.releaseGlobally()
    }

    func testLoginItemStateCanBeRead() {
        switch LoginItem.state() {
        case .enabled, .disabled, .requiresApproval, .unavailable: break
        }
    }

    func testThumbnailsRouteByPathKind() async throws {
        let assets = AppFakeAssets()
        assets.add("A/L0/001", filename: "IMG.JPG", width: 300)
        let generator = ThumbnailCache.routed(photos: assets)
        let photo = await generator("photos:A/L0/001/IMG.JPG", 64)
        XCTAssertNotNil(photo)                                                   // came from the provider, not Quick Look
        let missing = await generator("photos:missing/L0/001/X.JPG", 64)
        XCTAssertNil(missing)
        let noProvider = await ThumbnailCache.routed(photos: nil)("photos:A/L0/001/IMG.JPG", 64)
        XCTAssertNil(noProvider)
        let url = Fixtures.tempDir("thumb").appendingPathComponent("b.png")
        try Fixtures.writePNG(width: 200, height: 100, to: url)
        let file = await generator(url.path, 64)
        XCTAssertNotNil(file)                                                    // ordinary files still use Quick Look
    }

    func testPhotosPathsGoToShowInPhotosAndCopyAReadableName() {
        var shown: [String] = []
        let board = NSPasteboard(name: NSPasteboard.Name("com.shynlabs.thatone.test.\(UUID().uuidString)"))
        let actions = FileActions(pasteboard: board, showInPhotos: { shown.append($0) })
        actions.open("photos:A/L0/001/cake 1.HEIC")
        actions.reveal("photos:B/L0/001/cake 2.HEIC")
        XCTAssertEqual(shown, ["A/L0/001", "B/L0/001"])
        actions.copyPath("photos:A/L0/001/cake 1.HEIC")
        XCTAssertEqual(board.string(forType: .string), "cake 1.HEIC (Apple Photos)")
        board.releaseGlobally()
    }
}
