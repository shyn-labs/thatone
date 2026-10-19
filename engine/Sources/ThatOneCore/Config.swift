import Foundation

public struct Config: Codable, Equatable {
    public var folders: [String]
    public var exclude: [String]
    public var sidecar: [String]              // [executable, arguments...]; empty = the bundled MLX worker via uv
    public var sidecarEnv: [String: String]
    public var hotKey: String?                // a HotKeyPreset id in the app; nil = the default
    public var photos: Bool                   // index the Apple Photos library (the app asks macOS for permission)
    public var kinds: Set<String>             // which kinds of files are indexed (see Kinds)
    public var whisperFolder: String?         // where the speech model lives (the app looks in shyn's folder when nil)
    public var editor: String?                // how code opens: "vscode", "zed" or "default"; nil = VS Code when installed
    public static let editors = ["vscode", "zed", "default"]

    public init(folders: [String] = [], exclude: [String] = [], sidecar: [String] = [], sidecarEnv: [String: String] = [:],
                hotKey: String? = nil, photos: Bool = false, kinds: Set<String> = Kinds.defaultEnabled,
                whisperFolder: String? = nil, editor: String? = nil) {
        self.editor = editor
        self.kinds = kinds
        self.whisperFolder = whisperFolder
        self.folders = folders; self.exclude = exclude; self.sidecar = sidecar; self.sidecarEnv = sidecarEnv; self.hotKey = hotKey
        self.photos = photos
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folders = try c.decodeIfPresent([String].self, forKey: .folders) ?? []
        exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
        sidecar = try c.decodeIfPresent([String].self, forKey: .sidecar) ?? []
        sidecarEnv = try c.decodeIfPresent([String: String].self, forKey: .sidecarEnv) ?? [:]
        hotKey = try c.decodeIfPresent(String.self, forKey: .hotKey)
        photos = try c.decodeIfPresent(Bool.self, forKey: .photos) ?? false
        whisperFolder = try c.decodeIfPresent(String.self, forKey: .whisperFolder)
        editor = try c.decodeIfPresent(String.self, forKey: .editor).flatMap { Config.editors.contains($0) ? $0 : nil }
        let stored = try c.decodeIfPresent([String].self, forKey: .kinds)
        kinds = stored.map { Set($0).intersection(Kinds.all) } ?? Kinds.defaultEnabled     // unknown names are ignored
    }

    public static func load(from url: URL) throws -> Config {
        guard let data = FileManager.default.contents(atPath: url.path) else { return Config() }
        return try JSONDecoder().decode(Config.self, from: data)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public struct Paths {
    public let home: URL
    public init(home: URL) { self.home = home }
    public var db: URL { home.appendingPathComponent("index.db") }
    public var config: URL { home.appendingPathComponent("config.json") }
    public var work: URL { home.appendingPathComponent("work") }
    public var socket: URL { home.appendingPathComponent("thatone.sock") }

    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
        if let home = environment["THATONE_HOME"], !home.isEmpty { return Paths(home: URL(fileURLWithPath: home)) }
        return Paths(home: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/thatone"))
    }
}
