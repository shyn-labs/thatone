import Foundation
import XCTest
@testable import ThatOneCore

enum TestSupport {
    static let key = Data(repeating: 7, count: 32)
    static let otherKey = Data(repeating: 9, count: 32)

    static func tempDir(_ label: String = "t") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("thatone-\(label)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// <repo>/engine/Tests/ThatOneCoreTests/TestSupport.swift → <repo>
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// Unix socket paths are limited to 103 bytes, so anything that binds one lives in a short directory.
    static func shortDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("th-" + String(UInt32.random(in: 0...0xFFFFFF), radix: 16))
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
