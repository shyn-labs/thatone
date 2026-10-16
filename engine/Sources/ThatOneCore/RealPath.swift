import Foundation

public enum RealPath {
    /// Canonical absolute path via realpath(3). Foundation's resolvingSymlinksInPath() and standardizingPath map
    /// /private/var back to /var, but the kernel and FSEvents report /private/var, so always use this for file identity.
    /// For a path that does not exist (a deleted file, an unplugged drive) the longest existing ancestor is resolved and
    /// the rest is kept, with "." and ".." applied lexically, so it still matches what the index stored earlier.
    public static func of(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let absolute = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
        var stack: [String] = []
        for component in absolute.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { if !stack.isEmpty { stack.removeLast() }; continue }
            stack.append(String(component))
        }
        var tail: [String] = []
        while true {
            if let resolved = realpath("/" + stack.joined(separator: "/"), nil) {
                defer { free(resolved) }
                let base = String(cString: resolved)
                return tail.isEmpty ? base : (base == "/" ? "" : base) + "/" + tail.reversed().joined(separator: "/")
            }
            guard let last = stack.popLast() else { return "/" + tail.reversed().joined(separator: "/") }
            tail.append(last)
        }
    }
}
