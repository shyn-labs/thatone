import Foundation

/// Paths thatone never reads: credentials, caches, app bundles, other tools' data. Ported from the bake-off sampler.
public struct Exclusions {
    public static let directoryNames: Set<String> = [
        ".ssh", ".aws", ".gnupg", "node_modules", ".git", ".venv", "venv", "__pycache__",
        "Library", "Caches", ".Trash", ".cache",
    ]
    public static let directorySuffixes = [".app", ".photoslibrary", ".opvault", ".keychain-db"]
    public static let fileNamePatterns = [".env", ".env.*", "*.pem", "*.key", "id_*", "*.p12", "*.keychain*", "*.icloud"]

    public var extraPrefixes: [String]
    public init(extraPrefixes: [String] = []) { self.extraPrefixes = extraPrefixes }

    public func isExcludedDirectory(named name: String) -> Bool {
        Self.directoryNames.contains(name) || Self.directorySuffixes.contains { name.hasSuffix($0) }
    }

    /// When `root` is given, only the part of `path` below it is checked for excluded directory names, so a
    /// chosen folder that itself sits inside ~/Library (iCloud Drive) still works.
    public func isExcluded(path: String, root: String? = nil) -> Bool {
        for prefix in extraPrefixes {
            let dir = prefix.hasSuffix("/") ? prefix : prefix + "/"
            if path == prefix || path.hasPrefix(dir) { return true }
        }
        var relative = path
        if let root {
            let base = root.hasSuffix("/") ? root : root + "/"
            if path.hasPrefix(base) { relative = String(path.dropFirst(base.count)) }
        }
        let parts = relative.split(separator: "/").map(String.init)
        for directory in parts.dropLast() where isExcludedDirectory(named: directory) { return true }
        guard let name = parts.last else { return false }
        return Self.fileNamePatterns.contains { fnmatch($0, name, 0) == 0 }
    }
}
