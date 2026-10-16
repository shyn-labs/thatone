import Foundation

public enum SidecarError: Error, Equatable {
    case workerExited(Int32)
    case remote(code: String, message: String)
    case malformed(String)
    case timeout
}

public enum EmbedModality: String { case text, image, audio }
public enum EmbedRole: String { case query, document }

/// Speaks `sidecar/protocol.md` (one JSON object per line over stdio) to a worker process.
/// Blocking: call it off the main thread.
public final class SidecarClient {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private var buffer = Data()
    private var nextId = 0
    private let lock = NSLock()
    private let timeout: TimeInterval

    /// `timeout` bounds the wait for each reply (the first one includes the worker's start-up and model load).
    public init(executable: URL, arguments: [String], environment: [String: String] = [:], timeout: TimeInterval = 180) throws {
        self.timeout = timeout
        process.executableURL = executable
        process.arguments = arguments
        // The worker never needs the database key; do not hand it to a process that runs third-party ML code.
        var inherited = ProcessInfo.processInfo.environment
        inherited.removeValue(forKey: "THATONE_KEY_HEX")
        process.environment = inherited.merging(environment) { _, new in new }
        // A write to a worker that already exited must fail with EPIPE, not kill this process with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    deinit { close() }

    public var processIdentifier: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    public func close() {
        if process.isRunning {
            try? stdin.fileHandleForWriting.close()   // EOF on stdin is the worker's shutdown signal
            process.waitUntilExit()
        }
    }

    /// Blocks until the worker has written something (or closed its end), or the deadline passes; a hung worker is
    /// killed so the caller gets `.timeout` instead of waiting forever.
    private func waitUntilReadable() throws {
        var descriptor = pollfd(fd: stdout.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32(min(timeout * 1000, Double(Int32.max)))
        while true {
            let ready = poll(&descriptor, 1, milliseconds)
            if ready > 0 { return }
            if ready < 0 && errno == EINTR { continue }
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            throw SidecarError.timeout
        }
    }

    private func readLine() throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                return Data(line)
            }
            try waitUntilReadable()
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty {
                process.waitUntilExit()
                throw SidecarError.workerExited(process.terminationStatus)
            }
            buffer.append(chunk)
        }
    }

    private func call(_ request: [String: Any]) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        nextId += 1
        var req = request
        req["id"] = nextId
        var line = try JSONSerialization.data(withJSONObject: req)
        line.append(0x0A)
        do { try stdin.fileHandleForWriting.write(contentsOf: line) }
        catch { process.waitUntilExit(); throw SidecarError.workerExited(process.terminationStatus) }
        let reply = try readLine()
        guard let resp = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] else {
            throw SidecarError.malformed("response is not a JSON object")
        }
        guard resp["id"] as? Int == nextId else { throw SidecarError.malformed("response id does not match request") }
        if resp["ok"] as? Bool != true {
            let error = resp["error"] as? [String: Any]
            throw SidecarError.remote(code: error?["code"] as? String ?? "internal",
                                      message: error?["message"] as? String ?? "")
        }
        return resp
    }

    public struct Info: Equatable {
        public let model: String
        public let dim: Int
        public let modalities: [String]
        public init(model: String, dim: Int, modalities: [String]) {
            self.model = model; self.dim = dim; self.modalities = modalities
        }
    }

    public func info() throws -> Info {
        let r = try call(["op": "info"])
        return Info(model: r["model"] as? String ?? "", dim: r["dim"] as? Int ?? 0,
                    modalities: r["modalities"] as? [String] ?? [])
    }

    /// One L2-normalised vector per input.
    public func embed(_ modality: EmbedModality, role: EmbedRole, inputs: [String]) throws -> [[Float]] {
        let r = try call(["op": "embed", "modality": modality.rawValue, "role": role.rawValue, "inputs": inputs])
        guard let count = r["count"] as? Int, let dim = r["dim"] as? Int,
              let b64 = r["vectors_b64"] as? String, let data = Data(base64Encoded: b64),
              data.count == count * dim * MemoryLayout<Float>.size
        else { throw SidecarError.malformed("vector payload has the wrong size") }
        let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }   // little-endian on arm64
        return (0..<count).map { Array(floats[$0 * dim ..< ($0 + 1) * dim]) }
    }
}
