import Darwin
import XCTest
@testable import ThatOneCore

final class SocketTests: XCTestCase {
    func shortPath() -> String { TestSupport.shortDir().appendingPathComponent("t.sock").path }

    func testRoundTripAndSocketIsPrivate() throws {
        let path = shortPath()
        let server = LineSocketServer(path: path) { Data("echo:".utf8) + $0 }
        try server.start()
        defer { server.stop() }
        XCTAssertEqual(try LineSocketClient.request(path: path, payload: Data("hello".utf8)), Data("echo:hello".utf8))
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    func testLargeResponseAndManyConcurrentClients() throws {
        let path = shortPath()
        let big = Data(repeating: 0x61, count: 3_000_000)
        let server = LineSocketServer(path: path) { request in request == Data("big".utf8) ? big : request }
        try server.start()
        defer { server.stop() }
        XCTAssertEqual(try LineSocketClient.request(path: path, payload: Data("big".utf8)).count, 3_000_000)
        let group = DispatchGroup()
        var failures = 0
        let lock = NSLock()
        for i in 0..<40 {
            group.enter()
            DispatchQueue.global().async {
                let reply = try? LineSocketClient.request(path: path, payload: Data("n\(i)".utf8))
                if reply != Data("n\(i)".utf8) { lock.lock(); failures += 1; lock.unlock() }
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(failures, 0)
    }

    /// What a crashed app leaves behind: a socket file that nothing listens on.
    func makeStaleSocketFile(at path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strncpy($0, path, 103) }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(fd)
        XCTAssertEqual(bound, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testSecondServerOnTheSamePathIsRefused() throws {
        let path = shortPath()
        let first = LineSocketServer(path: path) { $0 }
        try first.start()
        defer { first.stop() }
        XCTAssertThrowsError(try LineSocketServer(path: path) { $0 }.start()) { XCTAssertEqual($0 as? SocketError, .alreadyRunning) }
        XCTAssertEqual(try LineSocketClient.request(path: path, payload: Data("still me".utf8)), Data("still me".utf8))
    }

    func testStaleSocketFileFromACrashIsReplaced() throws {
        let path = shortPath()
        try makeStaleSocketFile(at: path)
        let server = LineSocketServer(path: path) { Data("new".utf8) + $0 }
        try server.start()
        defer { server.stop() }
        XCTAssertEqual(try LineSocketClient.request(path: path, payload: Data("x".utf8)), Data("newx".utf8))
    }

    func testRegularFileAtThePathIsNotDeleted() throws {
        let path = shortPath()
        try Data("precious".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try LineSocketServer(path: path) { $0 }.start()) { XCTAssertEqual($0 as? SocketError, .notASocket(path)) }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("precious".utf8))
    }

    func testOverlongPathsAreRefusedClearly() {
        let long = NSTemporaryDirectory() + String(repeating: "a", count: 120) + ".sock"
        XCTAssertThrowsError(try LineSocketServer(path: long) { $0 }.start()) {
            guard case .pathTooLong(let n)? = $0 as? SocketError else { return XCTFail("\($0)") }
            XCTAssertGreaterThan(n, 103)
        }
    }

    func testNoServerMeansConnectErrorAndSlowServerMeansTimeout() throws {
        XCTAssertThrowsError(try LineSocketClient.request(path: shortPath(), payload: Data("x".utf8)))
        let path = shortPath()
        let server = LineSocketServer(path: path) { _ in Thread.sleep(forTimeInterval: 3); return Data("late".utf8) }
        try server.start()
        defer { server.stop() }
        XCTAssertThrowsError(try LineSocketClient.request(path: path, payload: Data("x".utf8), timeout: 0.5)) {
            XCTAssertEqual($0 as? SocketError, .timeout)
        }
    }

    func testOversizedRequestIsDropped() throws {
        let path = shortPath()
        let server = LineSocketServer(path: path) { _ in Data("should not happen".utf8) }
        try server.start()
        defer { server.stop() }
        XCTAssertThrowsError(try LineSocketClient.request(path: path, payload: Data(repeating: 0x61, count: 2 << 20), timeout: 2))
    }
}
