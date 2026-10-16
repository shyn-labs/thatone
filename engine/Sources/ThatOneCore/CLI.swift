import Foundation

public enum CLI {
    /// How often `index <folder>` asks the running app for progress.
    static var statusPollInterval: Double = 1.0

    static let usage = """
    usage:
      thatone index <folder>...            add folders, then index them (via the app if it is running)
      thatone index --files-from <file>    index exactly the files listed (one path per line)
      thatone search <words...> [--json] [--limit N] [--kind image] [--folder PATH]
      thatone status [--json]
      thatone forget <path>                drop a file or folder from the index now
      thatone exclude <path>               never index this path again, and drop it now
      thatone retry                        queue files that failed three times again
      thatone ui show_panel|hide_panel|show_window|quit   drive the running app
      thatone eval --golden <file.json> [--tags a,b] [--limit N]

    environment: THATONE_HOME (data folder), THATONE_KEY_HEX (64 hex chars; disposable databases only)
    """

    struct UsageError: Error { let message: String }

    struct Parsed {
        var positional: [String] = []
        var values: [String: String] = [:]
        var switches: Set<String> = []
    }

    static func parse(_ args: [String], values: Set<String> = [], switches: Set<String> = []) throws -> Parsed {
        var parsed = Parsed()
        var i = 0
        while i < args.count {
            let a = args[i]
            if values.contains(a) {
                guard i + 1 < args.count else { throw UsageError(message: "\(a) needs a value") }
                parsed.values[a] = args[i + 1]
                i += 2
            } else if switches.contains(a) {
                parsed.switches.insert(a)
                i += 1
            } else if a.hasPrefix("--") {
                throw UsageError(message: "unknown option \(a)")
            } else {
                parsed.positional.append(a)
                i += 1
            }
        }
        return parsed
    }

    public static func run(_ arguments: [String],
                           environment: [String: String] = ProcessInfo.processInfo.environment,
                           embedder: Embedder? = nil,
                           out rawOut: (String) -> Void = { print($0) },
                           err rawErr: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) -> Int32 {
        // Everything printed may contain file names or OCR text from untrusted files, so nothing reaches the terminal raw.
        func out(_ text: String) { rawOut(printable(text, keeping: [0x0A])) }
        func err(_ text: String) { rawErr(printable(text, keeping: [0x0A, 0x0D])) }   // \r: progress lines
        guard let command = arguments.first else { err(usage); return 2 }
        if ["help", "--help", "-h"].contains(command) { out(usage); return 0 }
        let rest = Array(arguments.dropFirst())
        let paths = Paths.current(environment: environment)
        let engine = { () throws -> Engine in
            let config = try Config.load(from: paths.config)
            return try Engine(paths: paths, config: config, keyProvider: Keys.provider(environment: environment), embedder: embedder)
        }
        let remote = { RemoteEngineService.ifRunning(socketPath: paths.socket.path) }
        let service = { () throws -> EngineService in try remote() ?? LocalEngineService(engine: try engine()) }
        do {
            switch command {
            case "index": try index(rest, engine, remote, out, err)
            case "search": try search(rest, service, out)
            case "status": try status(rest, service, remote, out)
            case "forget": try forget(rest, service, out)
            case "exclude": try exclude(rest, service, out)
            case "retry": try retry(rest, engine, out)
            case "eval": try evaluate(rest, engine, out)
            case "ui": try ui(rest, remote, out)
            default: throw UsageError(message: "unknown command '\(command)'")
            }
            return 0
        } catch let e as UsageError {
            err("thatone: \(e.message)\n\n\(usage)")
            return 2
        } catch let e as ServiceError {
            switch e {
            case .notRunning: err("thatone: the app is not running")
            case .remote(let message), .unsupported(let message), .badReply(let message): err("thatone: \(message)")
            }
            return 1
        } catch let e as EngineError {
            switch e {
            case .notAFolder(let path): err("thatone: not a folder: \(path)")
            case .alreadyIndexing: err("thatone: another thatone index is already running")
            default: err("thatone: \(e)")
            }
            return 1
        } catch {
            err("thatone: \(error)")
            return 1
        }
    }

    /// The app has its own working directory, so paths are made absolute here, where they were typed.
    static func absolute(_ path: String) -> String {
        if PhotosPath.isPhotos(path) { return path }         // a virtual Apple Photos path, not a file
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).path
    }

    /// Escapes control characters (including ESC, 8-bit C1 controls and bidirectional overrides) so text that came from
    /// a file name or OCR cannot drive the terminal or visually spoof a path. `keeping` lists control characters
    /// that are allowed through (newline for multi-line output, carriage return for progress lines).
    static func printable(_ text: String, keeping: Set<UInt32> = []) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let control = v < 0x20 || v == 0x7F || (0x80...0x9F).contains(v)
            let bidi = isBidi(v)
            if (control || bidi) && !keeping.contains(v) {
                scalars.append(contentsOf: "\\u{\(String(v, radix: 16, uppercase: true))}".unicodeScalars)
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    // MARK: commands

    static func index(_ args: [String], _ engine: () throws -> Engine, _ remote: () -> RemoteEngineService?,
                      _ out: (String) -> Void, _ err: (String) -> Void) throws {
        let p = try parse(args, values: ["--files-from"])
        let listFile = p.values["--files-from"]
        guard listFile != nil || !p.positional.isEmpty else { throw UsageError(message: "index needs a folder or --files-from <file>") }
        if let app = remote() {
            guard listFile == nil else {
                throw ServiceError.remote("the app is running: quit it first (explicit file lists are indexed directly)")
            }
            let queued = try app.index(folders: p.positional.map(absolute))
            out("queued \(queued) image(s); the app is indexing in the background")
            try follow(app, out, err)
            return
        }
        let e = try engine()
        var queued = 0
        if let listFile {
            guard let text = try? String(contentsOfFile: listFile, encoding: .utf8) else {
                throw UsageError(message: "cannot read \(listFile)")
            }
            queued = try e.enqueue(files: text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty })
        } else {
            for folder in p.positional { try e.addFolder(folder) }
            let scan = try e.scan()
            queued = scan.enqueued
            if scan.purgeQueued > 0 { out("checking \(scan.purgeQueued) file(s) that disappeared or are now excluded") }
        }
        out("queued \(queued) image(s)")
        // runIndexing's progress closure is escaping by type; it never outlives this call, so lend it `err`.
        let summary = try withoutActuallyEscaping(err) { escapableErr in
            try e.runIndexing { done, waiting in escapableErr("\r\(done) done, \(waiting) waiting") }
        }
        err("")
        out("indexed \(summary.indexed), linked \(summary.linked), unchanged \(summary.unchanged), "
            + "skipped \(summary.skipped), failed \(summary.failed)" + (summary.deferred > 0 ? ", waiting \(summary.deferred)" : ""))
        if let reason = summary.pausedReason {
            out("paused: \(reason); run `thatone index` again when the embedding model is available")
        }
        if summary.failed > 0 { out("run `thatone status` to see which files failed and why") }
    }

    /// Prints the app's progress until it stops indexing.
    static func follow(_ app: EngineService, _ out: (String) -> Void, _ err: (String) -> Void) throws {
        var status = try app.status()
        while status.state == "indexing" || status.state == "starting" {
            err("\r\(status.detail)")
            Thread.sleep(forTimeInterval: statusPollInterval)
            status = try app.status()
        }
        err("")
        out("\(status.state == "paused" ? "paused: \(status.detail)" : "done"); "
            + "indexed \(status.files["indexed", default: 0]), failed \(status.files["failed", default: 0])")
    }

    static func search(_ args: [String], _ service: () throws -> EngineService, _ out: (String) -> Void) throws {
        let p = try parse(args, values: ["--limit", "--kind", "--folder"], switches: ["--json"])
        guard !p.positional.isEmpty else { throw UsageError(message: "search needs some words") }
        var limit = 10
        if let text = p.values["--limit"] {
            guard let n = Int(text), n > 0 else { throw UsageError(message: "--limit must be a positive number") }
            limit = n
        }
        let query = ServiceQuery(query: p.positional.joined(separator: " "),
                                 kinds: p.values["--kind"].map { [$0] } ?? [],
                                 folder: p.values["--folder"].map { RealPath.of(($0 as NSString).expandingTildeInPath) },
                                 since: nil, limit: limit)
        let response = try service().search(query)
        if p.switches.contains("--json") {
            let hits: [[String: Any]] = response.hits.map { hit in
                ["paths": hit.paths, "kind": hit.kind, "score": hit.score, "modified": hit.modified,
                 "anchors": hit.anchors.map { ["modality": $0.modality, "anchor": $0.anchor, "text": $0.text,
                                               "via_keyword": $0.viaKeyword, "via_vector": $0.viaVector] as [String: Any] }]
            }
            let notice: Any = response.notice.map { $0 as Any } ?? NSNull()
            out(json(["hits": hits, "notice": notice]))
            return
        }
        if let notice = response.notice { out("note: \(notice)") }
        if response.hits.isEmpty { out("no matches"); return }
        for (i, hit) in response.hits.enumerated() {
            out("\(i + 1). \(hit.paths[0])  [\(hit.kind)]  score \(String(format: "%.4f", hit.score))")
            for extra in hit.paths.dropFirst() { out("   also: \(extra)") }
            if let text = hit.anchors.first(where: { !$0.text.isEmpty })?.text { out("   text: \(text)") }
        }
    }

    static func status(_ args: [String], _ service: () throws -> EngineService, _ remote: () -> RemoteEngineService?,
                       _ out: (String) -> Void) throws {
        let p = try parse(args, switches: ["--json"])
        guard p.positional.isEmpty else { throw UsageError(message: "status takes no arguments") }
        let s = try service().status()
        let viaApp = s.state != "idle" || remote() != nil
        if p.switches.contains("--json") {
            out(json(["state": s.state, "detail": s.detail, "folders": s.folders, "files": s.files, "segments": s.segments,
                      "queue": ["queued": s.queue.queued, "running": s.queue.running, "failed": s.queue.failed],
                      "photos": s.photos, "kinds": s.kinds, "failedFiles": s.failedFiles.map { ["path": $0.path, "note": $0.note] }]))
            return
        }
        if viaApp { out("app: \(s.state)" + (s.detail.isEmpty ? "" : " (\(s.detail))")) }
        out("folders: \(s.folders.isEmpty ? "none" : s.folders.joined(separator: ", "))")
        out("files: " + (s.files.isEmpty ? "none" : s.files.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")))
        out("segments: " + (s.segments.isEmpty ? "none" : s.segments.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")))
        out("queue: queued \(s.queue.queued), running \(s.queue.running), failed \(s.queue.failed)")
        if !s.kinds.isEmpty { out("indexed by kind: " + s.kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) }
        if s.photos != "off" { out("photos: \(s.photos)") }
        for f in s.failedFiles { out("  could not read: \(f.path): \(f.note)") }
    }

    static func forget(_ args: [String], _ service: () throws -> EngineService, _ out: (String) -> Void) throws {
        let p = try parse(args)
        guard p.positional.count == 1 else { throw UsageError(message: "forget needs exactly one path") }
        try service().forget(path: absolute(p.positional[0]))
        out("forgot \(p.positional[0])")
    }

    static func exclude(_ args: [String], _ service: () throws -> EngineService, _ out: (String) -> Void) throws {
        let p = try parse(args)
        guard p.positional.count == 1 else { throw UsageError(message: "exclude needs exactly one path") }
        try service().exclude(path: absolute(p.positional[0]))
        out("excluded \(p.positional[0])")
    }

    static func ui(_ args: [String], _ remote: () -> RemoteEngineService?, _ out: (String) -> Void) throws {
        let p = try parse(args)
        guard p.positional.count == 1, ["show_panel", "hide_panel", "show_window", "quit"].contains(p.positional[0]) else {
            throw UsageError(message: "ui needs one of: show_panel, hide_panel, show_window, quit")
        }
        guard let app = remote() else { throw ServiceError.notRunning }
        try app.ui(action: p.positional[0])
        out("ok")
    }

    static func retry(_ args: [String], _ engine: () throws -> Engine, _ out: (String) -> Void) throws {
        guard args.isEmpty else { throw UsageError(message: "retry takes no arguments") }
        try engine().queue.retryFailed()
        out("failed files queued again; run `thatone index <folder>` to process them")
    }

    static func evaluate(_ args: [String], _ engine: () throws -> Engine, _ out: (String) -> Void) throws {
        let p = try parse(args, values: ["--golden", "--tags", "--limit"])
        guard let golden = p.values["--golden"] else { throw UsageError(message: "eval needs --golden <file.json>") }
        var limit = 10
        if let text = p.values["--limit"] {
            guard let n = Int(text), n > 0 else { throw UsageError(message: "--limit must be a positive number") }
            limit = n
        }
        let tags = p.values["--tags"].map { Set($0.split(separator: ",").map(String.init)) }
        let queries = try Golden.load(URL(fileURLWithPath: golden))
        out(Golden.format(try Golden.evaluate(engine: engine(), queries: queries, tags: tags, k: limit)))
    }

    static func isBidi(_ v: UInt32) -> Bool {
        (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) || v == 0x200E || v == 0x200F
    }

    static func json(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        // JSONSerialization escapes C0 controls but not DEL, C1 controls or bidi overrides. Escape those as \uXXXX so
        // the output stays valid JSON and none of them reaches a terminal raw (printable() would break the JSON).
        var out = String.UnicodeScalarView()
        for scalar in String(decoding: data, as: UTF8.self).unicodeScalars {
            let v = scalar.value
            if v == 0x7F || (0x80...0x9F).contains(v) || isBidi(v) {
                out.append(contentsOf: String(format: "\\u%04X", v).unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }
}
