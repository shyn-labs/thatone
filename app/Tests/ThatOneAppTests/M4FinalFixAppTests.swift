import Foundation
import ThatOneCore
import XCTest
@testable import ThatOneApp

/// What the M4 final review found on the app side: each test failed before its fix.
final class M4FinalFixAppTests: XCTestCase {
    func testTimeChipsShowHoursAboveOneHour() {
        XCTAssertEqual(AnchorChip.text(from: #"{"t0":3725,"t1":3730}"#), "1:02:05")
        XCTAssertEqual(AnchorChip.text(from: #"{"t0":15000,"t1":15005}"#), "4:10:00")
        XCTAssertEqual(AnchorChip.text(from: #"{"t0":3600,"t1":3605}"#), "1:00:00")
        XCTAssertEqual(AnchorChip.text(from: #"{"t0":3599.9,"t1":3605}"#), "59:59")
        XCTAssertEqual(AnchorChip.text(from: #"{"t0":75,"t1":80}"#), "01:15")
    }

    func testRetryFailedResetsTheFrameCuttersBreaker() throws {
        final class Counting: FrameCutting {
            private let lock = NSLock()
            private var _resets = 0
            var resets: Int { lock.lock(); defer { lock.unlock() }; return _resets }
            func cut(source: URL, time: Double, maxSide: Int, to destination: URL) throws -> Bool { false }
            func resetBreaker() { lock.lock(); _resets += 1; lock.unlock() }
        }
        let cutter = Counting()
        let engine = try Engine(paths: Paths(home: Fixtures.tempDir("home")), config: Config(), keyProvider: StaticKeyProvider(Fixtures.key),
                                embedder: AppFakeEmbedder(), ocr: { _ in "words" }, frameCutter: cutter)
        let host = EngineHost(engine: engine, power: { nil }, memory: FakeMemory(), onChange: { _ in })
        defer { host.stop() }
        try host.retryFailed()
        XCTAssertEqual(cutter.resets, 1)
    }
}
