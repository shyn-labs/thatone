import Foundation

/// One line of a `.gitignore`, compiled to segment matchers over a path relative to that file's folder.
public struct GitIgnoreRule {
    public let pattern: String          // the glob once `!`, a leading `\`, the trailing `/` and a leading `/` are taken off
    public let negated: Bool
    public let directoryOnly: Bool
    public let anchored: Bool           // a slash at the start or in the middle: matched from its .gitignore's folder only
    let segments: [GitGlob.Segment]

    public func matches(_ relativePath: String) -> Bool {
        GitGlob.matches(segments, path: relativePath.components(separatedBy: "/").map { Array($0) }[...])
    }

    /// The same, for a path already split into segments (split once per path, not once per rule).
    func matches(_ path: ArraySlice<[Character]>) -> Bool { GitGlob.matches(segments, path: path) }
}

/// A non-backtracking glob matcher. Regular-expression engines backtrack exponentially on a hostile pattern such as
/// `a*a*a*a*b` or `**/**/**/x` (a cloned repo controls its `.gitignore`), so globs are matched directly: `**` at
/// segment level by dynamic programming over (pattern segment, path segment), `*`, `?` and classes inside one segment by
/// the two-pointer wildcard walk. Both are polynomial in the pattern and path lengths, never exponential.
enum GitGlob {
    enum Token { case literal(Character), any, star, set(ranges: [(Character, Character)], negated: Bool) }
    enum Segment { case doubleStar, tokens([Token]) }

    /// `nil` when the glob is malformed (an unclosed `[`, a reversed range): git matches nothing for it.
    static func compile(_ glob: String, anchored: Bool) -> [Segment]? {
        var rawSegments: [[Character]] = [[]]
        let c = Array(glob)
        var i = 0
        while i < c.count {
            if c[i] == "/" { rawSegments.append([]); i += 1; continue }
            if c[i] == "\\", i + 1 < c.count { rawSegments[rawSegments.count - 1] += [c[i], c[i + 1]]; i += 2; continue }
            rawSegments[rawSegments.count - 1].append(c[i]); i += 1
        }
        var out: [Segment] = anchored ? [] : [.doubleStar]      // an unanchored pattern may start in any folder
        for raw in rawSegments {
            if raw == ["*", "*"] { out.append(.doubleStar); continue }
            guard let tokens = tokenize(raw) else { return nil }
            out.append(.tokens(tokens))
        }
        return out
    }

    private static func tokenize(_ c: [Character]) -> [Token]? {
        var tokens: [Token] = []
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "*" {
                if case .star? = tokens.last {} else { tokens.append(.star) }     // a run of stars is one star
            } else if ch == "?" {
                tokens.append(.any)
            } else if ch == "[" {
                var j = i + 1
                var negated = false
                if j < c.count, c[j] == "!" || c[j] == "^" { negated = true; j += 1 }
                var members: [(Character, Bool)] = []                              // character, escaped
                var closed = false
                while j < c.count {
                    if c[j] == "]" && !members.isEmpty { closed = true; break }
                    if c[j] == "\\" && j + 1 < c.count { members.append((c[j + 1], true)); j += 2; continue }
                    members.append((c[j], false)); j += 1
                }
                guard closed else { return nil }                                   // no closing bracket: git matches nothing
                var ranges: [(Character, Character)] = []
                var k = 0
                while k < members.count {
                    if k + 2 < members.count, members[k + 1] == ("-", false) {
                        guard members[k].0 <= members[k + 2].0 else { return nil }
                        ranges.append((members[k].0, members[k + 2].0)); k += 3
                    } else { ranges.append((members[k].0, members[k].0)); k += 1 }
                }
                tokens.append(.set(ranges: ranges, negated: negated))
                i = j
            } else if ch == "\\" {
                tokens.append(.literal(i + 1 < c.count ? c[i + 1] : "\\"))
                i += i + 1 < c.count ? 2 : 1
                continue
            } else {
                tokens.append(.literal(ch))
            }
            i += 1
        }
        return tokens
    }

    private static func single(_ t: Token, _ ch: Character) -> Bool {
        switch t {
        case .literal(let l): return l == ch
        case .any: return true
        case .star: return false
        case .set(let ranges, let negated):
            let inSet = ranges.contains { $0.0 <= ch && ch <= $0.1 }
            return negated ? !inSet : inSet
        }
    }

    /// `*` / `?` / classes against one path segment: O(tokens x characters), no recursion.
    static func matchSegment(_ tokens: [Token], _ text: [Character]) -> Bool {
        var t = 0, s = 0, starT = -1, starS = 0
        while s < text.count {
            if t < tokens.count, case .star = tokens[t] { starT = t; starS = s; t += 1; continue }
            if t < tokens.count, single(tokens[t], text[s]) { t += 1; s += 1; continue }
            if starT >= 0 { starS += 1; s = starS; t = starT + 1; continue }
            return false
        }
        while t < tokens.count, case .star = tokens[t] { t += 1 }
        return t == tokens.count
    }

    /// Segment-level match; a trailing `**` needs at least one more segment, any other `**` takes zero or more.
    static func matches(_ pattern: [Segment], path slice: ArraySlice<[Character]>) -> Bool {
        let k = pattern.count, n = slice.count
        // Cheap rejections first (most rules of a long .gitignore fail here): a leading glob segment (an anchored rule) must
        // match the path's first segment, and a final one its last.
        if case .tokens(let first)? = pattern.first, n == 0 || !matchSegment(first, slice[slice.startIndex]) { return false }
        if case .tokens(let last)? = pattern.last, n == 0 || !matchSegment(last, slice[slice.endIndex - 1]) { return false }
        let path = Array(slice)
        var next = [Bool](repeating: false, count: n + 1)       // row p + 1; row k is true only at s == n
        next[n] = true
        var p = k - 1
        while p >= 0 {
            var row = [Bool](repeating: false, count: n + 1)
            switch pattern[p] {
            case .doubleStar:
                if p == k - 1 { for s in 0..<n { row[s] = true } }
                else { row[n] = next[n]; var s = n - 1; while s >= 0 { row[s] = next[s] || row[s + 1]; s -= 1 } }
            case .tokens(let tokens):
                for s in 0..<n where next[s + 1] && matchSegment(tokens, path[s]) { row[s] = true }
            }
            next = row
            p -= 1
        }
        return next[0]
    }
}

/// git's `.gitignore` syntax: comments, blank lines, `!`, leading `/`, trailing `/`, `*`, `?`, `**`, `[...]`, `\#`, `\!`,
/// escaped trailing spaces. Lines that cannot be compiled (an unclosed `[`) are ignored, as git does.
public enum GitIgnore {
    public static func parse(_ text: String) -> [GitIgnoreRule] { parse(text, maxRules: .max).rules }

    /// At most `maxRules` rules; `capped` when more lines would have made rules.
    static func parse(_ text: String, maxRules: Int) -> (rules: [GitIgnoreRule], capped: Bool) {
        var rules: [GitIgnoreRule] = []
        for raw in text.components(separatedBy: "\n") {
            var line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.isEmpty || line.hasPrefix("#") { continue }
            while line.hasSuffix(" ") && !line.hasSuffix("\\ ") { line.removeLast() }
            var negated = false
            if line.hasPrefix("!") { negated = true; line.removeFirst() }
            else if line.hasPrefix("\\!") || line.hasPrefix("\\#") { line.removeFirst() }
            var directoryOnly = false
            if line.hasSuffix("/") { directoryOnly = true; line.removeLast() }
            let anchored = line.contains("/")
            if line.hasPrefix("/") { line.removeFirst() }
            guard !line.isEmpty, let segments = GitGlob.compile(line, anchored: anchored) else { continue }
            if rules.count == maxRules { return (rules, true) }
            rules.append(GitIgnoreRule(pattern: line, negated: negated, directoryOnly: directoryOnly, anchored: anchored, segments: segments))
        }
        return (rules, false)
    }
}

/// Reads `.gitignore` files, remembering each folder's rules until the file's modification time or size changes.
/// A cloned repo controls its `.gitignore`: only the first `maxBytes` (whole lines) and the first `maxRules` rules are
/// read, the rest is ignored (so more code is indexed, never less) and logged once per file, without its contents.
public final class GitIgnoreLoader {
    private struct Entry { let stamp: String; let rules: [GitIgnoreRule] }
    private var cache: [String: Entry] = [:]
    private let lock = NSLock()
    static let capacity = 4096
    public static let maxBytes = 256 * 1024
    public static let maxRules = 10_000
    private let log: (String) -> Void
    private var logged = Set<String>()

    public init(log: @escaping (String) -> Void = { FileHandle.standardError.write(Data(("thatone: " + $0 + "\n").utf8)) }) {
        self.log = log
    }

    /// The rules of `<directory>/.gitignore`; none when it is missing, not a regular file or unreadable.
    public func rules(inDirectory directory: String) -> [GitIgnoreRule] {
        let file = directory + "/.gitignore"
        var info = stat()
        guard stat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            lock.lock(); cache[directory] = nil; lock.unlock()
            return []
        }
        let stamp = "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec).\(info.st_size)"
        lock.lock()
        if let hit = cache[directory], hit.stamp == stamp { lock.unlock(); return hit.rules }
        lock.unlock()
        let (rules, capped) = Self.read(file, size: Int64(info.st_size))
        lock.lock()
        let first = capped && logged.insert(file).inserted
        lock.unlock()
        if first {
            log("\(file) is larger than \(Self.maxBytes / 1024) KB or \(Self.maxRules) rules; the rest of it is ignored")
        }
        lock.lock()
        if cache.count >= Self.capacity { cache.removeAll() }
        cache[directory] = Entry(stamp: stamp, rules: rules)
        lock.unlock()
        return rules
    }

    private static func read(_ file: String, size: Int64) -> (rules: [GitIgnoreRule], capped: Bool) {
        guard let handle = FileHandle(forReadingAtPath: file) else { return ([], false) }
        defer { try? handle.close() }
        guard var data = try? handle.read(upToCount: maxBytes + 1) else { return ([], false) }
        let tooBig = data.count > maxBytes || size > Int64(maxBytes)
        if tooBig {                                     // keep whole lines only: a cut rule could ignore the wrong files
            data = data.prefix(maxBytes)
            data = data.lastIndex(of: UInt8(ascii: "\n")).map { data[data.startIndex...$0] } ?? Data()
        }
        let parsed = GitIgnore.parse(String(decoding: data, as: UTF8.self), maxRules: maxRules)
        return (parsed.rules, tooBig || parsed.capped)
    }
}

/// "Does git ignore this?" for paths under one root, consulting every `.gitignore` from the root down; the last matching
/// rule wins and deeper files are read after shallower ones. A path inside an ignored folder stays ignored whatever a
/// later `!` rule says (git cannot re-include it). One instance per scan or check, used from one thread: it remembers
/// each folder's rules and verdicts for its lifetime.
public final class GitIgnoreStack {
    public let root: String
    private let loader: GitIgnoreLoader
    private var rulesMemo: [String: [GitIgnoreRule]] = [:]
    private var folderMemo: [String: Bool] = [:]

    public init(root: String, loader: GitIgnoreLoader = GitIgnoreLoader()) {
        self.root = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        self.loader = loader
    }

    public func isIgnored(_ relativePath: String, isDirectory: Bool) -> Bool {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return false }
        let chars = parts.map { Array($0) }                  // split once here, never once per rule
        var folders = [""]                                   // folders[d]: the first d parts joined
        for part in parts.dropLast() { folders.append(folders.count == 1 ? part : folders[folders.count - 1] + "/" + part) }
        for depth in 1..<parts.count where folderIgnored(depth, folders, chars) { return true }
        return decide(parts.count, folders, chars, isDirectory: isDirectory)
    }

    private func folderIgnored(_ depth: Int, _ folders: [String], _ chars: [[Character]]) -> Bool {
        if let known = folderMemo[folders[depth]] { return known }
        let verdict = decide(depth, folders, chars, isDirectory: true)
        folderMemo[folders[depth]] = verdict
        return verdict
    }

    /// The verdict for the first `count` parts of the path.
    private func decide(_ count: Int, _ folders: [String], _ chars: [[Character]], isDirectory: Bool) -> Bool {
        var ignored = false
        for depth in 0..<count {
            let rules = rules(in: folders[depth])
            guard !rules.isEmpty else { continue }
            let sub = chars[depth..<count]
            for rule in rules where (!rule.directoryOnly || isDirectory) && rule.matches(sub) { ignored = !rule.negated }
        }
        return ignored
    }

    private func rules(in folder: String) -> [GitIgnoreRule] {
        if let known = rulesMemo[folder] { return known }
        let made = loader.rules(inDirectory: folder.isEmpty ? root : root + "/" + folder)
        rulesMemo[folder] = made
        return made
    }
}
