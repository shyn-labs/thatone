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
}

enum CodeScanner {
    private enum State { case code, block, string(String, escapes: Bool) }

    static func facts(_ lines: [String], _ lang: CodeLanguage) -> [LineFacts] {
        var state = State.code
        var out: [LineFacts] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            var f = LineFacts()
            if case .code = state {} else { f.startsInCode = false }
            let c = Array(line)
            func starts(_ token: String, at k: Int) -> Bool {
                let t = Array(token)
                guard k + t.count <= c.count else { return false }
                return Array(c[k..<(k + t.count)]) == t
            }
            var i = 0
            scan: while i < c.count {
                switch state {
                case .block:
                    if let close = lang.blockComment?.close, starts(close, at: i) { state = .code; i += close.count } else { i += 1 }
                case .string(let d, let escapes):
                    if escapes && c[i] == "\\" { i += 2; continue }
                    if starts(d, at: i) { state = .code; i += d.count } else { i += 1 }
                case .code:
                    if let open = lang.blockComment?.open, starts(open, at: i) { state = .block; i += open.count; continue }
                    let comment = lang.lineComments.contains { token in
                        starts(token, at: i) && (token != "#" || lang.name != "shell" || i == 0 || c[i - 1] == " " || c[i - 1] == "\t")
                    }
                    if comment { break scan }
                    if let d = lang.strings.first(where: { starts($0, at: i) }) {
                        f.hasCode = true; f.lastCodeChar = c[i]
                        state = .string(d, escapes: lang.escapes(d)); i += d.count; continue
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
                    case "{", "(", "[": f.marks.append(ch); f.brackets += 1
                    case "}", ")", "]": f.marks.append(ch); f.brackets -= 1
                    default: break
                    }
                    if !ch.isWhitespace { f.hasCode = true; f.lastCodeChar = ch }
                    i += 1
                }
            }
            // A one-character quote cannot run past its line: an unclosed one (or a misread) ends here.
            if case .string(let d, _) = state, !lang.multiLine(d) { state = .code }
            out.append(f)
        }
        return out
    }
}
