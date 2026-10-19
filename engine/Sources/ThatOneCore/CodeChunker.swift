import Foundation

/// A piece of a source file: lines `line0...line1` (1-based, inclusive) and the declaration it holds, when known.
public struct CodeChunk: Equatable {
    public let line0: Int
    public let line1: Int
    public let symbol: String?
    public init(line0: Int, line1: Int, symbol: String?) { self.line0 = line0; self.line1 = line1; self.symbol = symbol }
}

/// Line-based boundary finder (spec M5 "Chunking"). Pure; never fails: anything it cannot read is windowed.
public enum CodeChunker {
    public static let mergeBelow = 8
    public static let mergeUpTo = 60
    public static let splitAbove = 120
    public static let window = 60
    public static let step = 40
    /// Declarations are looked for this many levels deep (`A.B.C.d`); a long declaration deeper than that is windowed
    /// whole. Bounds the stack (one frame per level, and GCD workers get 512 KB) and the cost (each level rescans its body).
    public static let maxNesting = 4

    private struct Span {
        var start: Int, end: Int              // 0-based, inclusive
        var symbol: String?
        var isDeclaration: Bool
        var length: Int { end - start + 1 }
    }

    public static func chunks(_ lines: [String], language: CodeLanguage) -> [CodeChunk] {
        guard !lines.isEmpty else { return [] }
        let facts = CodeScanner.facts(lines, language)
        var out: [CodeChunk] = []
        for span in merge(segment(lines, facts, language, from: 0, to: lines.count - 1, parent: nil, depth: 0)) {
            let limit = span.isDeclaration ? splitAbove : window
            for piece in span.length > limit ? windows(span) : [span]
                where lines[piece.start...piece.end].contains(where: { !isBlank($0) }) {
                out.append(CodeChunk(line0: piece.start + 1, line1: piece.end + 1, symbol: piece.symbol.map { String($0.prefix(120)) }))
            }
        }
        return out
    }

    /// The anchor stored with a code segment: `{"line0":3,"line1":14,"symbol":"retry"}`.
    public static func anchorJSON(line0: Int, line1: Int, symbol: String?) -> String {
        var object: [String: Any] = ["line0": line0, "line1": line1]
        if let symbol, !symbol.isEmpty { object["symbol"] = String(symbol.prefix(120)) }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Columns of leading whitespace; a tab moves to the next multiple of 8, as Python counts it.
    public static func indentWidth(_ line: String) -> Int {
        var width = 0
        for ch in line {
            if ch == " " { width += 1 } else if ch == "\t" { width = (width / 8 + 1) * 8 } else { break }
        }
        return width
    }

    static func isBlank(_ line: String) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" } }

    private static func segment(_ lines: [String], _ facts: [LineFacts], _ lang: CodeLanguage,
                                from: Int, to: Int, parent: String?, depth: Int) -> [Span] {
        var out: [Span] = []
        var gapStart = from
        var i = from
        while i <= to {
            guard facts[i].startsInCode, let name = lang.declarationName(lines[i]) else { i += 1; continue }
            let end = blockEnd(lines, facts, lang, from: i, limit: to)
            if gapStart < i { out.append(Span(start: gapStart, end: i - 1, symbol: parent, isDeclaration: false)) }
            let symbol = parent.map { "\($0).\(name)" } ?? name
            var body: [Span] = []
            if end - i + 1 > splitAbove, end - 1 >= i + 1, depth + 1 < maxNesting {
                body = segment(lines, facts, lang, from: i + 1, to: end - 1, parent: symbol, depth: depth + 1)
            }
            if body.contains(where: { $0.isDeclaration }) {
                body[0].start = i
                body[body.count - 1].end = end
                out += body
            } else {
                out.append(Span(start: i, end: end, symbol: symbol, isDeclaration: true))
            }
            i = end + 1
            gapStart = i
        }
        if gapStart <= to { out.append(Span(start: gapStart, end: to, symbol: parent, isDeclaration: false)) }
        return out
    }

    private static func blockEnd(_ lines: [String], _ facts: [LineFacts], _ lang: CodeLanguage, from i: Int, limit: Int) -> Int {
        switch lang.family {
        case .braces: return braceEnd(lines, facts, lang, from: i, limit: limit)
        case .indent: return indentEnd(lines, facts, lang, from: i, limit: limit)
        }
    }

    /// The body opens at the first `{` outside parentheses and brackets, so a brace in a multi-line signature
    /// (a Swift default closure `= { [] }`, a TypeScript object default `options: {...} = {}`) does not end the declaration.
    /// It ends at the end of the line where the body's depth is back to zero.
    private static func braceEnd(_ lines: [String], _ facts: [LineFacts], _ lang: CodeLanguage, from i: Int, limit: Int) -> Int {
        var depth = 0                                          // braces of the body, once it opens
        var parens = 0                                         // ( and [ before the body opens
        var opened = false
        var j = i
        while j <= limit {
            if j > i && !opened && parens == 0
                && (isBlank(lines[j]) || (facts[j].startsInCode && lang.declarationName(lines[j]) != nil)) {
                var last = j - 1                               // no body: a requirement, a forward declaration, an alias
                while last > i && isBlank(lines[last]) { last -= 1 }
                return last
            }
            for mark in facts[j].marks {
                if opened {
                    if mark == "{" { depth += 1 } else if mark == "}" { depth -= 1 }
                } else {
                    switch mark {
                    case "(", "[": parens += 1
                    case ")", "]": parens = max(0, parens - 1)
                    case "{" where parens == 0: opened = true; depth = 1
                    default: break                             // a brace inside the signature's parentheses
                    }
                }
            }
            // Judged at the line's end: braces that close and reopen on one line (a TypeScript object return
            // type `): T & { ready: P } {`) belong to the signature, not the whole body.
            if opened && depth <= 0 { return j }
            if !opened && parens == 0 && facts[j].lastCodeChar == ";" { return j }
            j += 1
        }
        return limit
    }

    private static func indentEnd(_ lines: [String], _ facts: [LineFacts], _ lang: CodeLanguage, from i: Int, limit: Int) -> Int {
        let base = indentWidth(lines[i])
        var bracket = facts[i].brackets
        var last = i
        var j = i + 1
        while j <= limit {
            let line = lines[j]
            if bracket > 0 || !facts[j].startsInCode {                // inside an open bracket or a multi-line string
                bracket += facts[j].brackets; last = j; j += 1; continue
            }
            if isBlank(line) || !facts[j].hasCode { j += 1; continue } // blank and comment-only lines never end a block
            if indentWidth(line) > base { bracket += facts[j].brackets; last = j; j += 1; continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if lang.closers.contains(where: { trimmed == $0 || trimmed.hasPrefix($0 + " ") || trimmed.hasPrefix($0 + ")") || trimmed.hasPrefix($0 + ".") }) {
                return j
            }
            break
        }
        return last
    }

    private static func merge(_ spans: [Span]) -> [Span] {
        var out: [Span] = []
        var lastWasSmall = false
        for span in spans {
            let small = span.length < mergeBelow
            if small, lastWasSmall, var previous = out.last, previous.length + span.length <= mergeUpTo {
                previous.end = span.end
                previous.symbol = joined(previous.symbol, span.symbol)
                previous.isDeclaration = previous.isDeclaration || span.isDeclaration
                out[out.count - 1] = previous
            } else {
                out.append(span)
            }
            lastWasSmall = small
        }
        return out
    }

    private static func joined(_ a: String?, _ b: String?) -> String? {
        guard let a else { return b }
        guard let b else { return a }
        return a.components(separatedBy: ", ").contains(b) ? a : a + ", " + b
    }

    private static func windows(_ span: Span) -> [Span] {
        var out: [Span] = []
        var start = span.start
        while true {
            let end = min(start + window - 1, span.end)
            out.append(Span(start: start, end: end, symbol: span.symbol, isDeclaration: span.isDeclaration))
            if end == span.end { break }
            start += step
        }
        return out
    }
}
