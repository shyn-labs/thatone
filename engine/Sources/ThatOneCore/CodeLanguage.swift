import Foundation

/// How the chunker finds where a declaration ends: brace depth back to zero, or indentation back to its level.
public enum CodeFamily: Equatable { case braces, indent }

/// What the chunker knows about one language: where declarations start and what its comments and strings look like.
public struct CodeLanguage {
    public let name: String
    public let family: CodeFamily
    public let declarations: [NSRegularExpression]        // capture group 1 is the symbol
    let lineComments: [String]
    let blockComment: (open: String, close: String)?
    let strings: [String]                                  // string delimiters, longest first
    let charLiterals: Bool                                 // `'x'` is a character and a lone `'` is not a quote (Rust lifetimes)
    let closers: [String]                                  // indent family: a line starting with one ends the block and belongs to it

    init(_ name: String, _ family: CodeFamily, _ patterns: [String], comments: [String],
         block: (open: String, close: String)? = nil, strings: [String], charLiterals: Bool = false, closers: [String] = []) {
        self.name = name
        self.family = family
        self.declarations = patterns.map { try! NSRegularExpression(pattern: $0) }   // constants; CodeChunkerTests compiles every one
        self.lineComments = comments
        self.blockComment = block
        self.strings = strings
        self.charLiterals = charLiterals
        self.closers = closers
    }

    /// The declared name when `line` starts a declaration.
    public func declarationName(_ line: String) -> String? {
        let head = String(line.prefix(400))
        let range = NSRange(head.startIndex..., in: head)
        for regex in declarations {
            guard let m = regex.firstMatch(in: head, range: range), m.numberOfRanges > 1,
                  let r = Range(m.range(at: 1), in: head), !head[r].isEmpty else { continue }
            return String(head[r])
        }
        return nil
    }

    /// Whether a code line (trimmed) is, or with `opening` begins, an attribute or a decorator that belongs to the
    /// declaration below it: `@available(macOS 13, *)`, `@app.route("/x")`, `@Override`, `#[derive(Debug)]`,
    /// C# `[Obsolete]`, C++ `[[nodiscard]]`. A whole line must be attributes, so `@Published var x = 1` is not one.
    /// Hand-written scans, linear in the line: the line comes from an untrusted file, so no backtracking pattern.
    func isAttribute(_ trimmed: String, opening: Bool = false) -> Bool {
        let c = Array(trimmed.unicodeScalars.prefix(400))
        switch name {
        case "swift", "javascript", "python", "kotlin", "scala": return Self.atAttributes(c, opening: opening)
        case "java":                                                                     // Java annotations, C# attributes
            if Self.atAttributes(c, opening: opening) { return true }
            guard c.count >= 2, c[0] == "[", Self.isIdentifierStart(c[1]) else { return false }
            return opening || c.last == "]"
        case "rust":                                                                     // never `#![`: that is the module's
            guard c.count >= 2, c[0] == "#", c[1] == "[" else { return false }
            return opening || (c.count >= 3 && c.last == "]")
        case "c":
            guard c.count >= 2, c[0] == "[", c[1] == "[" else { return false }
            return opening || (c.count >= 4 && c[c.count - 1] == "]" && c[c.count - 2] == "]")
        default: return false
        }
    }

    static func isIdentifierStart(_ u: Unicode.Scalar) -> Bool { u == "_" || (u.isASCII && u.properties.isAlphabetic) }

    /// `@name` or `@name(args)`, repeated with optional spaces, filling the line. With `opening`, the line instead
    /// begins `@name(` (the first line of a multi-line attribute). Parentheses are matched by depth; quoted strings
    /// inside them are skipped, so `message: "use (x)"` does not unbalance them. One pass, no backtracking.
    static func atAttributes(_ c: [Unicode.Scalar], opening: Bool) -> Bool {
        var i = 0, count = 0
        while true {
            while i < c.count, c[i] == " " || c[i] == "\t" { i += 1 }
            if i == c.count { return count > 0 && !opening }
            guard c[i] == "@", i + 1 < c.count, isIdentifierStart(c[i + 1]) else { return false }
            i += 2
            while i < c.count, c[i] == "_" || c[i] == "." || c[i].properties.isAlphabetic || c[i].properties.numericType != nil { i += 1 }
            if i < c.count, c[i] == "(" {
                if opening { return count == 0 }
                var depth = 0
                while i < c.count {
                    let u = c[i]
                    if u == "\"" || u == "'" {                                // a string literal: skip to its closing quote
                        i += 1
                        while i < c.count, c[i] != u { i += c[i] == "\\" ? 2 : 1 }
                    } else if u == "(" {
                        depth += 1
                    } else if u == ")" {
                        depth -= 1
                        if depth == 0 { i += 1; break }
                    }
                    i += 1
                }
                if depth != 0 { return false }                               // never closed on this line
            } else if opening {
                return false
            }
            count += 1
            if i < c.count, c[i] != " ", c[i] != "\t", c[i] != "@" { return false }   // `@a(b) c`, `@objc // why`
        }
    }

    func escapes(_ delimiter: String) -> Bool {
        !(name == "go" && delimiter == "`") && !(delimiter == "'" && (name == "shell" || name == "sql"))
    }

    func multiLine(_ delimiter: String) -> Bool {
        delimiter.count == 3 || delimiter == "`" || (name == "shell" && delimiter == "\"")
    }

    public static func forExtension(_ ext: String) -> CodeLanguage {
        switch ext.lowercased() {
        case "swift": return swift
        case "ts", "tsx", "js", "jsx", "mjs", "cjs", "mts": return javascript
        case "py": return python
        case "go": return go
        case "rs": return rust
        case "java", "cs": return java
        case "kt": return kotlin
        case "scala": return scala
        case "c", "h", "cc", "cpp", "hpp": return c
        case "m", "mm": return objc
        case "php": return php
        case "rb": return ruby
        case "lua": return lua
        case "sh", "bash", "zsh": return shell
        case "sql": return sql
        default: return plain
        }
    }

    static let cBlock = (open: "/*", close: "*/")
    static let swiftMods = #"(?:@[A-Za-z_]+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|open|package|static|class|final|override|mutating|nonmutating|convenience|required|lazy|nonisolated|dynamic|indirect|distributed)(?:\([^)]*\))?\s+)*"#
    static let swift = CodeLanguage("swift", .braces, [
        #"^\s*"# + swiftMods + #"(?:func|class|struct|enum|protocol|extension|actor)\s+(?!(?:var|let|func)\b)([A-Za-z_][A-Za-z0-9_.]*|`[^`]+`|[^\s(<{:]+)"#,
        #"^\s*"# + swiftMods + #"(init|deinit|subscript)\b"#,
    ], comments: ["//"], block: cBlock, strings: ["\"\"\"", "\""])
    static let javascript = CodeLanguage("javascript", .braces, [
        #"^\s*(?:export\s+)?(?:default\s+)?(?:declare\s+)?(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)"#,
        #"^\s*(?:export\s+)?(?:default\s+)?(?:declare\s+)?(?:abstract\s+)?class\s+([A-Za-z_$][\w$]*)"#,
        #"^\s*(?:export\s+)?(?:declare\s+)?(?:const\s+)?(?:interface|enum|namespace|module)\s+([A-Za-z_$][\w$.]*)"#,
        #"^\s*(?:export\s+)?(?:declare\s+)?type\s+([A-Za-z_$][\w$]*)\s*(?:<[^=]*>)?\s*="#,
        #"^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]+)?=\s*(?:async\s+)?(?:function\b|(?:<[^=]*>\s*)?\([^;]*=>|[A-Za-z_$][\w$]*\s*=>)"#,
        #"^\s*(?:(?:public|private|protected|static|readonly|async|override|abstract|get|set)\s+)*\*?(?!(?:if|for|while|switch|catch|return|function|else|do|try|with|new|typeof|await|yield|super|this)\b)([A-Za-z_$][\w$]*)\s*(?:<[^>]*>)?\s*\([^;]*\)\s*(?::\s*[^;{]+)?\s*\{\s*$"#,
    ], comments: ["//"], block: cBlock, strings: ["`", "\"", "'"])
    static let python = CodeLanguage("python", .indent, [
        #"^\s*(?:async\s+)?def\s+([A-Za-z_]\w*)"#,
        #"^\s*class\s+([A-Za-z_]\w*)"#,
    ], comments: ["#"], strings: ["\"\"\"", "'''", "\"", "'"])
    static let go = CodeLanguage("go", .braces, [
        #"^func\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)"#,
        #"^type\s+([A-Za-z_]\w*)"#,
    ], comments: ["//"], block: cBlock, strings: ["`", "\""], charLiterals: true)
    static let rust = CodeLanguage("rust", .braces, [
        #"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:(?:default|async|const|unsafe|extern(?:\s+"[^"]*")?)\s+)*fn\s+([A-Za-z_]\w*)"#,
        #"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:struct|enum|trait|union|mod)\s+([A-Za-z_]\w*)"#,
        #"^\s*(?:unsafe\s+)?impl\b(?:<[^>]*>)?\s*(?:[^{]*?\bfor\s+)?([A-Za-z_][\w:]*)"#,
        #"^\s*macro_rules!\s*([A-Za-z_]\w*)"#,
    ], comments: ["//"], block: cBlock, strings: ["\""], charLiterals: true)
    static let javaMods = #"(?:@[A-Za-z_][\w.]*(?:\([^)]*\))?\s+)*(?:\[[^\]]*\]\s*)*(?:(?:public|private|protected|internal|static|final|abstract|sealed|partial|readonly|synchronized|native|override|virtual|async|default|unsafe|extern|new|strictfp)\s+)*"#
    static let java = CodeLanguage("java", .braces, [
        #"^\s*"# + javaMods + #"(?:class|interface|enum|record|struct)\s+([A-Za-z_]\w*)"#,
        #"^\s*"# + javaMods + #"(?:<[^>]+>\s+)?(?!(?:return|new|else|throw|case|await|yield|if|for|foreach|while|switch|catch|using|lock|var)\b)[\w<>\[\],.?]+\s+([A-Za-z_]\w*)\s*\([^;]*$"#,
    ], comments: ["//"], block: cBlock, strings: ["\"\"\"", "\""], charLiterals: true)
    static let kotlinMods = #"(?:@[A-Za-z_][\w.]*(?:\([^)]*\))?\s+)*(?:(?:public|private|protected|internal|override|open|abstract|final|sealed|data|inner|enum|annotation|companion|suspend|inline|operator|infix|tailrec|external|value)\s+)*"#
    static let kotlin = CodeLanguage("kotlin", .braces, [
        #"^\s*"# + kotlinMods + #"(?:class|interface|object)\s+([A-Za-z_]\w*)"#,
        #"^\s*"# + kotlinMods + #"fun\s+(?:<[^>]*>\s*)?(?:[\w.]+\.)?([A-Za-z_]\w*)"#,
    ], comments: ["//"], block: cBlock, strings: ["\"\"\"", "\""], charLiterals: true)
    static let scala = CodeLanguage("scala", .braces, [
        #"^\s*(?:(?:private|protected|final|sealed|abstract|implicit|case|lazy|override)(?:\[[^\]]*\])?\s+)*(?:class|object|trait|enum)\s+([A-Za-z_]\w*)"#,
        #"^\s*(?:(?:private|protected|final|implicit|lazy|override|inline)(?:\[[^\]]*\])?\s+)*def\s+([A-Za-z_]\w*)"#,
    ], comments: ["//"], block: cBlock, strings: ["\"\"\"", "\""], charLiterals: true)
    static let cPatterns = [
        #"^(?!\s*(?:return|else|if|for|while|switch|case|do|goto|sizeof|typedef|using|namespace)\b)(?:[A-Za-z_][\w:<>,]*[\s\*&]+)+\**&*([A-Za-z_~][\w:~]*)\s*\([^;]*$"#,
        #"^\s*(?:typedef\s+)?(?:struct|class|union|enum(?:\s+class)?|namespace)\s+([A-Za-z_]\w*)[^;]*$"#,
    ]
    static let c = CodeLanguage("c", .braces, cPatterns, comments: ["//"], block: cBlock, strings: ["\""], charLiterals: true)
    static let objc = CodeLanguage("objc", .braces, cPatterns + [
        #"^[-+]\s*\([^)]*\)\s*([A-Za-z_]\w*)"#,
        #"^@(?:interface|implementation|protocol)\s+([A-Za-z_]\w*)"#,
    ], comments: ["//"], block: cBlock, strings: ["\""], charLiterals: true)
    static let php = CodeLanguage("php", .braces, [
        #"^\s*(?:(?:public|private|protected|static|abstract|final)\s+)*function\s+&?([A-Za-z_]\w*)"#,
        #"^\s*(?:(?:abstract|final|readonly)\s+)*(?:class|interface|trait|enum)\s+([A-Za-z_]\w*)"#,
    ], comments: ["//", "#"], block: cBlock, strings: ["\"", "'"])
    static let ruby = CodeLanguage("ruby", .indent, [
        #"^\s*def\s+((?:self\.)?[A-Za-z_]\w*[!?=]?)"#,
        #"^\s*(?:class|module)\s+([A-Z]\w*(?:::\w+)*)"#,
    ], comments: ["#"], strings: ["\"", "'"], closers: ["end"])
    static let lua = CodeLanguage("lua", .indent, [
        #"^\s*(?:local\s+)?function\s+([A-Za-z_][\w.:]*)"#,
    ], comments: ["--"], block: (open: "--[[", close: "]]"), strings: ["\"", "'"], closers: ["end"])
    static let shell = CodeLanguage("shell", .braces, [
        #"^\s*function\s+([A-Za-z_][\w-]*)"#,
        #"^\s*([A-Za-z_][\w-]*)\s*\(\s*\)"#,
    ], comments: ["#"], strings: ["\"", "'", "`"])
    static let sql = CodeLanguage("sql", .braces, [], comments: ["--"], block: cBlock, strings: ["'", "\""])
    static let plain = CodeLanguage("plain", .braces, [], comments: [], strings: [])
}

/// What one line holds outside comments and strings.
struct LineFacts: Equatable {
    var startsInCode = true      // not inside a block comment or a multi-line string at its first character
    var marks: [Character] = []  // each `{ } ( ) [ ]`, in order
    var brackets = 0             // net ( [ { minus ) ] }
    var lastCodeChar: Character?
    var hasCode = false          // any non-space character outside comments
    var startsInComment = false  // inside a block comment at its first character
    var hasComment = false       // any comment on the line (a line comment, a block comment or part of one)
    var hasStringText = false    // any non-space character inside a string that began on an earlier line
    /// Nothing but comment: a doc-comment line, a block comment's inside or its blank line.
    var isCommentOnly: Bool { !hasCode && !hasStringText && (hasComment || startsInComment) }
}

enum CodeScanner {
    private enum State { case code, block, string(String, [Unicode.Scalar], escapes: Bool) }

    /// `Character.isWhitespace` for one scalar, without a Unicode property lookup for ASCII.
    @inline(__always) static func isSpace(_ u: Unicode.Scalar) -> Bool {
        u.value < 0x80 ? (u.value == 0x20 || (0x09...0x0D).contains(u.value)) : u.properties.isWhitespace
    }

    /// One pass over each line's Unicode scalars (cheaper than grapheme clusters, and every token is ASCII). Tokens are
    /// split once per file and compared in place, and an ASCII scalar that cannot open a comment, a string or a quote
    /// takes a short path, so a file of long hostile lines stays fast.
    static func facts(_ lines: [String], _ lang: CodeLanguage) -> [LineFacts] {
        var state = State.code
        let open = lang.blockComment.map { Array($0.open.unicodeScalars) }, close = lang.blockComment.map { Array($0.close.unicodeScalars) }
        let lineComments = lang.lineComments.map { (token: $0, chars: Array($0.unicodeScalars)) }
        let strings = lang.strings.map { (token: $0, chars: Array($0.unicodeScalars), escapes: lang.escapes($0)) }
        var special = [Bool](repeating: false, count: 128)       // ASCII scalars that may start a comment, a string or a quote
        if lang.charLiterals { special[Int(("'" as Unicode.Scalar).value)] = true }
        for token in [open].compactMap({ $0 }) + lineComments.map(\.chars) + strings.map(\.chars) {
            if let first = token.first, first.value < 128 { special[Int(first.value)] = true }
        }
        var out: [LineFacts] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            var f = LineFacts()
            if case .code = state {} else { f.startsInCode = false }
            if case .block = state { f.startsInComment = true }
            let c = Array(line.unicodeScalars)
            func starts(_ t: [Unicode.Scalar], at k: Int) -> Bool {
                guard k + t.count <= c.count else { return false }
                for j in 0..<t.count where c[k + j] != t[j] { return false }
                return true
            }
            var i = 0
            scan: while i < c.count {
                switch state {
                case .block:
                    if !isSpace(c[i]) { f.hasComment = true }
                    if let close, starts(close, at: i) { state = .code; i += close.count } else { i += 1 }
                case .string(_, let d, let escapes):
                    if !f.hasCode && !isSpace(c[i]) { f.hasStringText = true }
                    if escapes && c[i] == "\\" { i += 2; continue }
                    if starts(d, at: i) { state = .code; i += d.count } else { i += 1 }
                case .code:
                    let u = c[i]
                    if u.value < 128 && !special[Int(u.value)] {
                        switch u {
                        case "{", "(", "[": f.marks.append(Character(u)); f.brackets += 1
                        case "}", ")", "]": f.marks.append(Character(u)); f.brackets -= 1
                        default: break
                        }
                        if !isSpace(u) { f.hasCode = true; f.lastCodeChar = Character(u) }
                        i += 1; continue
                    }
                    if let open, starts(open, at: i) { state = .block; f.hasComment = true; i += open.count; continue }
                    for token in lineComments where starts(token.chars, at: i)
                        && (token.token != "#" || lang.name != "shell" || i == 0 || c[i - 1] == " " || c[i - 1] == "\t") {
                        f.hasComment = true; break scan
                    }
                    var opened: (token: String, chars: [Unicode.Scalar], escapes: Bool)?
                    for d in strings where starts(d.chars, at: i) { opened = d; break }
                    if let d = opened {
                        f.hasCode = true; f.lastCodeChar = Character(c[i])
                        state = .string(d.token, d.chars, escapes: d.escapes); i += d.chars.count; continue
                    }
                    if c[i] == "'" && lang.charLiterals {
                        f.hasCode = true; f.lastCodeChar = "'"
                        if i + 1 < c.count, c[i + 1] == "\\" {                    // '\n', '\u{7b}'
                            var j = i + 2
                            while j < c.count && j < i + 12 && c[j] != "'" { j += 1 }
                            i = (j < c.count && c[j] == "'") ? j + 1 : i + 1
                            continue
                        }
                        if i + 2 < c.count, c[i + 2] == "'" { i += 3; continue }    // 'x'
                        i += 1; continue                                           // a lifetime or a label, not a quote
                    }
                    let ch = c[i]
                    switch ch {
                    case "{", "(", "[": f.marks.append(Character(ch)); f.brackets += 1
                    case "}", ")", "]": f.marks.append(Character(ch)); f.brackets -= 1
                    default: break
                    }
                    if !isSpace(ch) { f.hasCode = true; f.lastCodeChar = Character(ch) }
                    i += 1
                }
            }
            // A one-character quote cannot run past its line: an unclosed one (or a misread) ends here.
            if case .string(let d, _, _) = state, !lang.multiLine(d) { state = .code }
            out.append(f)
        }
        return out
    }
}
