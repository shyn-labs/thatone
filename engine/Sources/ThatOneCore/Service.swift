import Foundation

public enum ServiceError: Error, Equatable {
    case remote(String)
    case notRunning
    case unsupported(String)
    case badReply(String)
}

public struct ServiceQuery: Codable, Equatable {
    public var query: String
    public var kinds: [String]
    public var folder: String?
    public var since: Int64?
    public var limit: Int
    public init(query: String, kinds: [String] = [], folder: String? = nil, since: Int64? = nil, limit: Int = 10) {
        self.query = query; self.kinds = kinds; self.folder = folder; self.since = since; self.limit = limit
    }
}

public struct ServiceAnchor: Codable, Equatable {
    public var modality: String
    public var anchor: String
    public var text: String
    public var viaKeyword: Bool
    public var viaVector: Bool
    public init(modality: String, anchor: String, text: String, viaKeyword: Bool, viaVector: Bool) {
        self.modality = modality; self.anchor = anchor; self.text = text; self.viaKeyword = viaKeyword; self.viaVector = viaVector
    }
}

public struct ServiceHit: Codable, Equatable {
    public var paths: [String]
    public var kind: String
    public var score: Double
    public var modified: Int64
    public var anchors: [ServiceAnchor]
    public init(paths: [String], kind: String, score: Double, modified: Int64, anchors: [ServiceAnchor]) {
        self.paths = paths; self.kind = kind; self.score = score; self.modified = modified; self.anchors = anchors
    }
    public init(_ hit: SearchHit) {
        self.init(paths: hit.paths, kind: hit.kind, score: hit.score, modified: hit.modified,
                  anchors: hit.anchors.map { ServiceAnchor(modality: $0.modality, anchor: $0.anchor, text: $0.text,
                                                           viaKeyword: $0.viaKeyword, viaVector: $0.viaVector) })
    }
}

public struct ServiceSearchResult: Codable, Equatable {
    public var hits: [ServiceHit]
    public var notice: String?
    public init(hits: [ServiceHit], notice: String?) { self.hits = hits; self.notice = notice }
    init(_ response: SearchResponse) { self.init(hits: response.hits.map(ServiceHit.init), notice: response.notice) }
}

public struct ServiceQueue: Codable, Equatable {
    public var queued: Int
    public var running: Int
    public var failed: Int
    public init(queued: Int, running: Int, failed: Int) { self.queued = queued; self.running = running; self.failed = failed }
}

public struct ServiceFailedFile: Codable, Equatable {
    public var path: String
    public var note: String
    public init(path: String, note: String) { self.path = path; self.note = note }
}

public struct ServiceStatus: Codable, Equatable {
    public var state: String            // starting | idle | indexing | paused | stopped
    public var detail: String
    public var folders: [String]
    public var files: [String: Int]
    public var segments: [String: Int]
    public var queue: ServiceQueue
    public var failedFiles: [ServiceFailedFile]
    public var photos: String           // off | needs permission | denied | restricted | on | on (limited)
    public var kinds: [String: Int]     // indexed files per kind (image, pdf, document, text)
    public init(state: String, detail: String, folders: [String], files: [String: Int], segments: [String: Int],
                queue: ServiceQueue, failedFiles: [ServiceFailedFile], photos: String = "off", kinds: [String: Int] = [:]) {
        self.kinds = kinds
        self.state = state; self.detail = detail; self.folders = folders; self.files = files
        self.segments = segments; self.queue = queue; self.failedFiles = failedFiles; self.photos = photos
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(String.self, forKey: .state)
        detail = try c.decode(String.self, forKey: .detail)
        folders = try c.decode([String].self, forKey: .folders)
        files = try c.decode([String: Int].self, forKey: .files)
        segments = try c.decode([String: Int].self, forKey: .segments)
        queue = try c.decode(ServiceQueue.self, forKey: .queue)
        failedFiles = try c.decode([ServiceFailedFile].self, forKey: .failedFiles)
        photos = try c.decodeIfPresent(String.self, forKey: .photos) ?? "off"      // older apps do not send it
        kinds = try c.decodeIfPresent([String: Int].self, forKey: .kinds) ?? [:]
    }
}

/// What the app (or, without the app, a thin wrapper around the engine) offers to a client.
public protocol EngineService: AnyObject {
    /// An empty `query` means "browse the newest images".
    func search(_ q: ServiceQuery) throws -> ServiceSearchResult
    func similar(path: String, limit: Int) throws -> ServiceSearchResult
    func status() throws -> ServiceStatus
    /// Adds folders to the watch list, scans them, and returns how many files were queued.
    func index(folders: [String]) throws -> Int
    func forget(path: String) throws
    func exclude(path: String) throws
    /// "show_panel", "hide_panel", "show_window", "quit".
    func ui(action: String) throws
}

/// The service without an app: straight onto an `Engine` in this process.
public final class LocalEngineService: EngineService {
    private let engine: Engine
    public init(engine: Engine) { self.engine = engine }

    public func search(_ q: ServiceQuery) throws -> ServiceSearchResult {
        let filters = SearchFilters(kinds: Set(q.kinds), folder: q.folder, since: q.since)
        if q.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ServiceSearchResult(try engine.recent(filters: filters, limit: q.limit))
        }
        return ServiceSearchResult(try engine.search(q.query, filters: filters, limit: q.limit))
    }

    public func similar(path: String, limit: Int) throws -> ServiceSearchResult {
        ServiceSearchResult(try engine.similar(toPath: path, limit: limit))
    }

    public func status() throws -> ServiceStatus {
        let s = try engine.status()
        return ServiceStatus(state: "idle", detail: "", folders: s.folders, files: s.counts.filesByStatus,
                             segments: s.counts.segmentsByModality,
                             queue: ServiceQueue(queued: s.queue.queued, running: s.queue.running, failed: s.queue.failed),
                             failedFiles: s.failedFiles.map { ServiceFailedFile(path: $0.path, note: $0.note) },
                             kinds: s.counts.filesByKind)
    }

    public func index(folders: [String]) throws -> Int {
        for folder in folders { try engine.addFolder(folder) }
        return try engine.scan().enqueued
    }

    public func forget(path: String) throws { try engine.forget(path: path) }
    public func exclude(path: String) throws { try engine.exclude(path) }
    public func ui(action: String) throws { throw ServiceError.unsupported("this process has no user interface") }
}

struct WireRequest: Codable {
    var v: Int
    var op: String
    var query: ServiceQuery?
    var path: String?
    var folders: [String]?
    var limit: Int?
    var action: String?
}

struct WireResponse: Codable {
    var ok: Bool
    var error: String?
    var search: ServiceSearchResult?
    var status: ServiceStatus?
    var queued: Int?
}

public enum ServiceDispatcher {
    public static let protocolVersion = 1

    /// One request line in, one reply line out. Never throws: every failure becomes `{"ok":false,"error":...}`.
    public static func handle(_ line: Data, service: EngineService) -> Data {
        func encode(_ response: WireResponse) -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(response)) ?? Data(#"{"ok":false,"error":"internal error"}"#.utf8)
        }
        func failure(_ message: String) -> Data { encode(WireResponse(ok: false, error: message)) }
        func isAbsolute(_ path: String) -> Bool { path.hasPrefix("/") || PhotosPath.isPhotos(path) }
        func clamp(_ limit: Int) -> Int { max(1, min(limit, Searcher.maxLimit)) }

        guard let request = try? JSONDecoder().decode(WireRequest.self, from: line) else { return failure("invalid request") }
        guard request.v == protocolVersion else { return failure("unsupported protocol version \(request.v)") }
        do {
            var response = WireResponse(ok: true)
            switch request.op {
            case "ping":
                break
            case "search":
                guard var q = request.query else { return failure("search needs a query") }
                q.limit = clamp(q.limit)
                response.search = try service.search(q)
            case "similar":
                guard let path = request.path else { return failure("similar needs a path") }
                guard isAbsolute(path) else { return failure("paths must be absolute") }
                response.search = try service.similar(path: path, limit: clamp(request.limit ?? 30))
            case "status":
                response.status = try service.status()
            case "index":
                guard let folders = request.folders else { return failure("index needs folders") }
                guard folders.allSatisfy({ $0.hasPrefix("/") }) else { return failure("paths must be absolute") }
                response.queued = try service.index(folders: folders)
            case "forget":
                guard let path = request.path else { return failure("forget needs a path") }
                guard isAbsolute(path) else { return failure("paths must be absolute") }
                try service.forget(path: path)
            case "exclude":
                guard let path = request.path else { return failure("exclude needs a path") }
                guard isAbsolute(path) else { return failure("paths must be absolute") }
                try service.exclude(path: path)
            case "ui":
                guard let action = request.action else { return failure("ui needs an action") }
                try service.ui(action: action)
            default:
                return failure("unknown operation '\(request.op)'")
            }
            return encode(response)
        } catch ServiceError.remote(let message) {
            return failure(message)
        } catch ServiceError.unsupported(let message) {
            return failure(message)
        } catch {
            return failure(String(describing: error))
        }
    }
}

/// A service on the other end of the socket.
public final class RemoteEngineService: EngineService {
    public let socketPath: String
    private let timeout: Double
    public init(socketPath: String, timeout: Double = 30) { self.socketPath = socketPath; self.timeout = timeout }

    /// nil unless something answers a `status` on the socket within half a second.
    public static func ifRunning(socketPath: String) -> RemoteEngineService? {
        guard (try? RemoteEngineService(socketPath: socketPath, timeout: 0.5).status()) != nil else { return nil }
        return RemoteEngineService(socketPath: socketPath)
    }

    private func call(_ request: WireRequest) throws -> WireResponse {
        let payload = try JSONEncoder().encode(request)
        let reply: Data
        do { reply = try LineSocketClient.request(path: socketPath, payload: payload, timeout: timeout) }
        catch SocketError.timeout { throw ServiceError.remote("the app did not answer in time") }
        catch { throw ServiceError.notRunning }
        guard let response = try? JSONDecoder().decode(WireResponse.self, from: reply) else {
            throw ServiceError.badReply("could not read the app's reply")
        }
        guard response.ok else { throw ServiceError.remote(response.error ?? "unknown error") }
        return response
    }

    private func request(_ op: String, _ fill: (inout WireRequest) -> Void = { _ in }) throws -> WireResponse {
        var r = WireRequest(v: ServiceDispatcher.protocolVersion, op: op)
        fill(&r)
        return try call(r)
    }

    public func search(_ q: ServiceQuery) throws -> ServiceSearchResult {
        guard let result = try request("search", { $0.query = q }).search else { throw ServiceError.badReply("no search result") }
        return result
    }

    public func similar(path: String, limit: Int) throws -> ServiceSearchResult {
        guard let result = try request("similar", { $0.path = path; $0.limit = limit }).search else { throw ServiceError.badReply("no search result") }
        return result
    }

    public func status() throws -> ServiceStatus {
        guard let status = try request("status").status else { throw ServiceError.badReply("no status") }
        return status
    }

    public func index(folders: [String]) throws -> Int {
        guard let queued = try request("index", { $0.folders = folders }).queued else { throw ServiceError.badReply("no count") }
        return queued
    }

    public func forget(path: String) throws { _ = try request("forget", { $0.path = path }) }
    public func exclude(path: String) throws { _ = try request("exclude", { $0.path = path }) }
    public func ui(action: String) throws { _ = try request("ui", { $0.action = action }) }
}

public enum ServiceSocket {
    /// Starts serving `service` on `path`. Throws `SocketError.alreadyRunning` when another instance already does.
    public static func start(path: String, service: EngineService) throws -> LineSocketServer {
        let server = LineSocketServer(path: path) { ServiceDispatcher.handle($0, service: service) }
        try server.start()
        return server
    }
}
