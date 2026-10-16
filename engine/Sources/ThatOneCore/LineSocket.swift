import Darwin
import Foundation

public enum SocketError: Error, Equatable {
    case pathTooLong(Int)
    case alreadyRunning
    case notASocket(String)
    case system(String)
    case timeout
    case closed
    case tooLarge
}

private let sunPathCapacity = 104   // sizeof(sockaddr_un.sun_path) on macOS

private func makeAddress(_ path: String) throws -> sockaddr_un {
    guard path.utf8.count < sunPathCapacity else { throw SocketError.pathTooLong(path.utf8.count) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: sunPathCapacity) { _ = strncpy($0, path, sunPathCapacity - 1) }
    }
    return address
}

private func systemError(_ what: String) -> SocketError { .system("\(what): \(String(cString: strerror(errno)))") }

private func setTimeouts(_ fd: Int32, seconds: Double) {
    var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
}

/// Reads bytes until a newline (not included in the result) or EOF. Throws on timeout or when `limit` is exceeded.
private func readLine(_ fd: Int32, limit: Int) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n < 0 {
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw SocketError.timeout }
            throw systemError("read")
        }
        if n == 0 { if data.isEmpty { throw SocketError.closed }; return data }
        if let newline = buffer[..<n].firstIndex(of: 0x0A) {
            data.append(contentsOf: buffer[..<newline])
            return data
        }
        data.append(contentsOf: buffer[..<n])
        if data.count > limit { throw SocketError.tooLarge }
    }
}

private func writeAll(_ fd: Int32, _ data: Data) throws {
    var offset = 0
    try data.withUnsafeBytes { raw in
        while offset < data.count {
            let n = write(fd, raw.baseAddress! + offset, data.count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw SocketError.timeout }
                throw systemError("write")
            }
            offset += n
        }
    }
}

/// One request line in, one response line out, per connection. The socket file is private to the user (0600) and
/// every peer's uid is checked.
public final class LineSocketServer {
    public static let maxRequestBytes = 1 << 20

    public let path: String
    private let handler: (Data) -> Data
    private var listenFD: Int32 = -1
    private let lock = NSLock()
    private var running = false
    private let acceptQueue = DispatchQueue(label: "thatone.socket.accept")
    private let workQueue = DispatchQueue(label: "thatone.socket.work", attributes: .concurrent)

    public init(path: String, handler: @escaping (Data) -> Data) {
        self.path = path
        self.handler = handler
    }

    /// Fails with `.alreadyRunning` when another process is answering on `path`; removes a stale file left by a crash.
    public func start() throws {
        var address = try makeAddress(path)
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else { throw SocketError.notASocket(path) }
            if (try? LineSocketClient.request(path: path, payload: Data(), timeout: 0.5)) != nil { throw SocketError.alreadyRunning }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw systemError("socket") }
        let previousMask = umask(0o177)                    // the socket file is created 0600
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previousMask)
        guard bound == 0 else { let e = systemError("bind"); close(fd); throw e }
        guard listen(fd, 16) == 0 else { let e = systemError("listen"); close(fd); unlink(path); throw e }
        lock.lock(); listenFD = fd; running = true; lock.unlock()
        acceptQueue.async { [weak self] in self?.acceptLoop(fd) }
    }

    public func stop() {
        lock.lock()
        let fd = listenFD
        let wasRunning = running
        running = false
        listenFD = -1
        lock.unlock()
        guard wasRunning else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(path)
    }

    deinit { stop() }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func acceptLoop(_ fd: Int32) {
        while isRunning {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            workQueue.async { [weak self] in
                self?.serve(client)
                close(client)
            }
        }
    }

    private func serve(_ client: Int32) {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }
        setTimeouts(client, seconds: 10)
        guard let request = try? readLine(client, limit: Self.maxRequestBytes) else { return }
        var response = handler(request)
        response.append(0x0A)
        try? writeAll(client, response)
    }
}

public enum LineSocketClient {
    /// Sends one line and returns the one-line reply. `timeout` bounds each read and write.
    public static func request(path: String, payload: Data, timeout: Double = 5) throws -> Data {
        var address = try makeAddress(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw systemError("socket") }
        defer { close(fd) }
        setTimeouts(fd, seconds: timeout)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw systemError("connect") }
        var line = payload
        line.append(0x0A)
        try writeAll(fd, line)
        return try readLine(fd, limit: 64 << 20)
    }
}
