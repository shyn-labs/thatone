import XCTest
@testable import ThatOneCore

final class CodeChunkerTests: XCTestCase {
    func chunks(_ lines: [String], _ ext: String) -> [CodeChunk] { CodeChunker.chunks(lines, language: .forExtension(ext)) }
    func swiftFunc(_ name: String, body: Int) -> [String] { ["func \(name)() {"] + (0..<body).map { "    total += \($0)" } + ["}"] }

    func testEveryExtensionHasALanguageAndEveryPatternCompiles() {
        for ext in Kinds.codeExtensions { XCTAssertNotEqual(CodeLanguage.forExtension(ext).name, "plain", ext) }
        XCTAssertTrue(CodeLanguage.forExtension("sql").declarations.isEmpty)
        XCTAssertEqual(CodeLanguage.forExtension("txt").name, "plain")
    }

    func testDeclarationNamesPerLanguage() {
        let cases: [(String, String, String?)] = [
            ("swift", "    public static func make(_ x: Int) -> Self {", "make"),
            ("swift", "final class EngineHost {", "EngineHost"),
            ("swift", "    init(store: Store) {", "init"),
            ("swift", "extension Engine: Searching {", "Engine"),
            ("swift", "    static func == (a: A, b: A) -> Bool {", "=="),
            ("swift", "    class var shared: X {", nil),
            ("ts", "export async function retryWithBackoff(fn) {", "retryWithBackoff"),
            ("ts", "export default class Daemon extends Base {", "Daemon"),
            ("ts", "export const fmtFileHit = (h: FileHit) => {", "fmtFileHit"),
            ("ts", "  async search(q: FileSearchQuery): Promise<Result> {", "search"),
            ("ts", "export interface FileHit {", "FileHit"),
            ("ts", "export type Opts = {", "Opts"),
            ("ts", "  if (x) {", nil),
            ("ts", "  describe(\"x\", () => {", nil),
            ("ts", "  return foo(a, b);", nil),
            ("ts", "export const FILE_KINDS = [\"image\"] as const;", nil),
            ("ts", "const area = (w: number, h: number): number => w * h;", "area"),
            ("ts", "  let total = (a + b) * c;", nil),
            ("ts", "  const opts = (", nil),
            ("py", "async def fetch(url):", "fetch"),
            ("py", "class Worker(Base):", "Worker"),
            ("go", "func (c *Client) Retry(ctx context.Context) error {", "Retry"),
            ("go", "type Server struct {", "Server"),
            ("rs", "pub(crate) async fn embed(&self) -> Result<()> {", "embed"),
            ("rs", "impl Display for Hit {", "Hit"),
            ("rs", "impl<T> Store<T> {", "Store"),
            ("java", "    public static List<String> parse(String s) throws IOException {", "parse"),
            ("java", "public final class Indexer {", "Indexer"),
            ("java", "        else if (x) {", nil),
            ("cs", "    public async Task<int> RunAsync(CancellationToken ct)", "RunAsync"),
            ("kt", "    suspend fun load(id: Int): Item {", "load"),
            ("kt", "data class Item(val id: Int)", "Item"),
            ("scala", "  def run(args: Array[String]): Unit = {", "run"),
            ("c", "static int parse_header(const char *buf, size_t n)", "parse_header"),
            ("c", "struct node {", "node"),
            ("c", "    return parse(x);", nil),
            ("cpp", "void Engine::run() {", "Engine::run"),
            ("m", "- (void)viewDidLoad {", "viewDidLoad"),
            ("m", "@implementation AppDelegate", "AppDelegate"),
            ("php", "    public function handle(Request $r) {", "handle"),
            ("rb", "  def self.call(env)", "self.call"),
            ("lua", "function M.setup(opts)", "M.setup"),
            ("sh", "retry_with_backoff() {", "retry_with_backoff"),
            ("sh", "function cleanup {", "cleanup"),
        ]
        for (ext, line, expected) in cases {
            XCTAssertEqual(CodeLanguage.forExtension(ext).declarationName(line), expected, "\(ext): \(line)")
        }
    }

    func testSwiftFunctionsBecomeOneChunkEachWithTheirNames() {
        let lines = ["import Foundation", ""] + swiftFunc("retryWithBackoff", body: 10) + [""] + swiftFunc("parseHeader", body: 10)
        XCTAssertEqual(chunks(lines, "swift"), [
            CodeChunk(line0: 1, line1: 2, symbol: nil),
            CodeChunk(line0: 3, line1: 14, symbol: "retryWithBackoff"),
            CodeChunk(line0: 16, line1: 27, symbol: "parseHeader"),                // line 15 is blank alone: dropped
        ])
    }

    func testBracesInStringsCommentsAndCharactersDoNotMoveTheEnd() {
        let swift = ["func a() {", "    let s = \"}}} {\"", "    // } closing in a comment", "    /* { */",
                     "    let t = \"\"\"", "    }", "    \"\"\""] + (0..<4).map { "    n += \($0)" } + ["}", "", "func b() {"]
            + (0..<8).map { "    m += \($0)" } + ["}"]
        let got = chunks(swift, "swift")
        XCTAssertEqual(got.first, CodeChunk(line0: 1, line1: 12, symbol: "a"))
        XCTAssertEqual(got.last, CodeChunk(line0: 14, line1: 23, symbol: "b"))

        let rust = ["fn parse(c: char) -> bool {", "    if c == '{' { return true }", "    let r = '\\u{7b}';",
                    "    match c { '}' => false, _ => true }", "}", "", "fn take<'a>(s: &'a str) -> &'a str {"]
            + (0..<6).map { "    let _x\($0) = s;" } + ["    s", "}"]
        XCTAssertEqual(chunks(rust, "rs"), [CodeChunk(line0: 1, line1: 6, symbol: "parse"), CodeChunk(line0: 7, line1: 15, symbol: "take")])
    }

    func testPythonBlocksEndWhereIndentationReturnsAndTabsCount() {
        let py = ["import os", "", "class Store:", "\tdef get(self, key,", "\t        default=None):", "\t\t\"\"\"Docstring",
                  "end of docstring at column 0", "\t\t\"\"\"", "# a comment at column 0", "\t\treturn self.d.get(key, default)",
                  "", "def load(path):", "    with open(path) as f:", "        return f.read()", "", "x = load('a')"]
        XCTAssertEqual(chunks(py, "py"), [
            CodeChunk(line0: 1, line1: 2, symbol: nil),
            CodeChunk(line0: 3, line1: 10, symbol: "Store"),
            CodeChunk(line0: 11, line1: 16, symbol: "load"),
        ])
        XCTAssertEqual(CodeChunker.indentWidth("\tx"), 8)
        XCTAssertEqual(CodeChunker.indentWidth("  \tx"), 8)
        XCTAssertEqual(CodeChunker.indentWidth("    x"), 4)
    }

    func testRubyAndLuaBlocksIncludeTheirEnd() {
        let rb = ["module Billing", "  def self.total(items)"] + (0..<8).map { "    sum += \($0)" } + ["  end", "end", "", "puts 1"]
        XCTAssertEqual(chunks(rb, "rb"), [CodeChunk(line0: 1, line1: 12, symbol: "Billing"), CodeChunk(line0: 13, line1: 14, symbol: nil)])
        let lua = ["local function retry(n)"] + (0..<8).map { "  n = n + \($0)" } + ["end", "return retry"]
        XCTAssertEqual(chunks(lua, "lua").first, CodeChunk(line0: 1, line1: 10, symbol: "retry"))
    }

    func testALongDeclarationIsSplitAtItsNestedDeclarations() {
        let alpha = ["    func alpha() {"] + (0..<60).map { "        a += \($0)" } + ["    }"]
        let beta = ["    func beta() {"] + (0..<60).map { "        b += \($0)" } + ["    }"]
        let src = ["struct Ledger {", "    var a = 0"] + alpha + beta + ["}"]
        XCTAssertEqual(chunks(src, "swift"), [
            CodeChunk(line0: 1, line1: 2, symbol: "Ledger"),
            CodeChunk(line0: 3, line1: 64, symbol: "Ledger.alpha"),
            CodeChunk(line0: 65, line1: 127, symbol: "Ledger.beta"),
        ])
    }

    func testWindowing() {
        let script = (1...130).map { "echo \($0)" }
        XCTAssertEqual(chunks(script, "sh").map { [$0.line0, $0.line1] }, [[1, 60], [41, 100], [81, 130]])
        XCTAssertEqual(chunks((1...61).map { "echo \($0)" }, "sh").map { [$0.line0, $0.line1] }, [[1, 60], [41, 61]])
        let huge = ["func huge() {"] + (0..<198).map { "    h += \($0)" } + ["}"]
        XCTAssertEqual(chunks(huge, "swift"), [[1, 60], [41, 100], [81, 140], [121, 180], [161, 200]].map {
            CodeChunk(line0: $0[0], line1: $0[1], symbol: "huge") })
        let mid = ["func mid() {"] + (0..<98).map { "    m += \($0)" } + ["}"]
        XCTAssertEqual(chunks(mid, "swift"), [CodeChunk(line0: 1, line1: 100, symbol: "mid")])
        XCTAssertEqual(chunks((1...70).map { "select \($0);" }, "sql").map { [$0.line0, $0.line1] }, [[1, 60], [41, 70]])
    }

    func testSmallNeighboursMergeUpToSixtyLines() {
        let go = ["package main", "", "func a() int {", "\treturn 1", "}", "", "func b() int {", "\treturn 2", "}", "",
                  "func (s *S) c() int {", "\treturn 3", "}"]
        XCTAssertEqual(chunks(go, "go"), [CodeChunk(line0: 1, line1: 13, symbol: "a, b, c")])
        let many = (0..<20).flatMap { ["func f\($0)() int {", "\treturn \($0)", "}", ""] }
        let got = chunks(many, "go")
        XCTAssertEqual(got.count, 2)
        XCTAssertEqual(got.first?.line0, 1); XCTAssertEqual(got.last?.line1, 80)
        XCTAssertTrue(got.allSatisfy { $0.line1 - $0.line0 + 1 <= 60 })
        for (a, b) in zip(got, got.dropFirst()) { XCTAssertEqual(b.line0, a.line1 + 1) }
    }

    func testABraceInsideAMultiLineSignatureDoesNotEndTheDeclaration() {
        let swift = ["init(", "    store: Store,", "    filter: @escaping (String) -> Bool = { _ in true },",
                     "    extras: () -> [String] = { [] }", ") {"] + (0..<8).map { "    n += \($0)" } + ["}"]
        XCTAssertEqual(chunks(swift, "swift"), [CodeChunk(line0: 1, line1: 14, symbol: "init")])
        let ts = ["export function buildServer(", "  client: Client,", "  options: {", "    name?: string;",
                  "    verbose?: boolean;", "  } = {},", ") {"] + (0..<8).map { "  n += \($0);" } + ["}"]
        XCTAssertEqual(chunks(ts, "ts"), [CodeChunk(line0: 1, line1: 16, symbol: "buildServer")])
        let returnType = ["export function serve(", "  path: string,", "): Server & { ready: Promise<void> } {"]
            + (0..<8).map { "  n += \($0);" } + ["}"]                       // an object type closes and the body opens on one line
        XCTAssertEqual(chunks(returnType, "ts"), [CodeChunk(line0: 1, line1: 12, symbol: "serve")])
    }

    func testTypeScriptChunkBoundaries() {
        let ts = ["import { a } from \"./a\";", "", "export function retry(fn: () => Promise<void>) {",
                  "  const open = \"}\" + `{${n}`;", "  // } a closing brace in a comment", "  const re = '{';"]
            + (0..<5).map { "  n += \($0);" } + ["}", "", "export const fmt = (h: Hit): string => {"]
            + (0..<8).map { "  s += \($0);" } + ["};"]
        XCTAssertEqual(chunks(ts, "ts"), [
            CodeChunk(line0: 1, line1: 2, symbol: nil),
            CodeChunk(line0: 3, line1: 12, symbol: "retry"),
            CodeChunk(line0: 14, line1: 23, symbol: "fmt"),
        ])
    }

    func testCFamilyChunkBoundaries() {
        let c = ["#include <stdio.h>", "", "static int parse_header(const char *buf, size_t n)", "{",
                 "    char close = '}';", "    const char *open = \"{\";"] + (0..<6).map { "    n += \($0);" } + ["}", "",
                 "struct node {"] + (0..<8).map { "    int v\($0);" } + ["};"]
        XCTAssertEqual(chunks(c, "c"), [
            CodeChunk(line0: 1, line1: 2, symbol: nil),
            CodeChunk(line0: 3, line1: 13, symbol: "parse_header"),
            CodeChunk(line0: 15, line1: 24, symbol: "node"),
        ])
    }

    func testMergeAppliesBelowEightLines() {
        XCTAssertEqual(CodeChunker.mergeBelow, 8)
        XCTAssertEqual(chunks(swiftFunc("a", body: 5) + swiftFunc("b", body: 5), "swift"),          // 7 lines each
                       [CodeChunk(line0: 1, line1: 14, symbol: "a, b")])
        XCTAssertEqual(chunks(swiftFunc("a", body: 6) + swiftFunc("b", body: 6), "swift"),          // 8 lines each
                       [CodeChunk(line0: 1, line1: 8, symbol: "a"), CodeChunk(line0: 9, line1: 16, symbol: "b")])
    }

    func testADeclarationIsWindowedAboveOneHundredTwentyLines() {
        XCTAssertEqual(CodeChunker.splitAbove, 120)
        XCTAssertEqual(chunks(swiftFunc("big", body: 118), "swift"), [CodeChunk(line0: 1, line1: 120, symbol: "big")])
        XCTAssertEqual(chunks(swiftFunc("big", body: 119), "swift"), [[1, 60], [41, 100], [81, 121]].map {
            CodeChunk(line0: $0[0], line1: $0[1], symbol: "big") })
    }

    func testTheChunkerNeverFails() {
        XCTAssertEqual(chunks(["func a() {", "  x"], "swift"), [CodeChunk(line0: 1, line1: 2, symbol: "a")])
        XCTAssertEqual(chunks([], "swift"), [])
        XCTAssertEqual(chunks(["", "   ", "\t"], "py"), [])
        XCTAssertEqual(chunks(["func f() {"] + Array(repeating: "\"unclosed", count: 5) + ["}"], "swift").count, 1)
        XCTAssertFalse(chunks([String(repeating: "x(", count: 3000)], "c").isEmpty)        // a long line is cut to 400 characters
    }

    /// Runs `body` on a thread with a GCD worker's 512 KB stack; a recursion per nesting level overflows it.
    func onSmallStack(stackSize: Int = 512 * 1024, _ body: @escaping () -> Void) {
        let done = expectation(description: "done")
        let thread = Thread { body(); done.fulfill() }
        thread.stackSize = stackSize
        thread.start()
        wait(for: [done], timeout: 120)
    }

    /// 2,000 declarations nested inside each other, each with `body` lines of its own before the next one opens.
    func nested(depth: Int, body: Int) -> [String] {
        var lines: [String] = []
        for level in 0..<depth {
            lines.append(String(repeating: " ", count: level % 40) + "func a\(level)() {")
            lines += (0..<body).map { "    total += \($0) // level \(level)" }
        }
        for _ in 0..<depth { lines.append("}") }
        return lines
    }

    func assertCoversEveryNonBlankLine(_ result: [CodeChunk], _ lines: [String], file: StaticString = #filePath, line: UInt = #line) {
        var covered = [Bool](repeating: false, count: lines.count)
        for c in result {
            XCTAssertLessThanOrEqual(c.line0, c.line1, file: file, line: line)
            for n in c.line0...c.line1 { covered[n - 1] = true }
        }
        let missing = lines.indices.filter { !covered[$0] && !CodeChunker.isBlank(lines[$0]) }
        XCTAssertEqual(missing.count, 0, "uncovered lines, first \(missing.prefix(3))", file: file, line: line)
    }

    func testTwoThousandNestingLevelsDoNotOverflowASmallStack() {
        let lines = nested(depth: 2_000, body: 0)
        var result: [CodeChunk] = []
        let started = Date()
        onSmallStack { result = CodeChunker.chunks(lines, language: .forExtension("swift")) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
        assertCoversEveryNonBlankLine(result, lines)
        XCTAssertEqual(result.first?.symbol, "a0.a1.a2.a3")              // named four levels deep, the rest windowed
        XCTAssertTrue(result.allSatisfy { ($0.symbol?.split(separator: ".").count ?? 0) <= CodeChunker.maxNesting })
    }

    func testDeepNestingWithLongBodiesStaysFast() {
        let lines = nested(depth: 2_000, body: 5)             // 14,000 lines; one scan per nesting level would be ~14M line visits
        var result: [CodeChunk] = []
        let started = Date()
        onSmallStack(stackSize: 64 * 1024 * 1024) { result = CodeChunker.chunks(lines, language: .forExtension("swift")) }
        let seconds = Date().timeIntervalSince(started)
        XCTAssertLessThan(seconds, 2.0, "took \(seconds) s")
        assertCoversEveryNonBlankLine(result, lines)
        let py = (0..<200).flatMap { level -> [String] in        // indentation-nested; a tab is 8 columns, so lines stay short
            let pad = String(repeating: "\t", count: level)
            return [pad + "def f\(level)():"] + (0..<5).map { _ in pad + "\tx = 1" }
        }
        let pyStarted = Date()
        var pyResult: [CodeChunk] = []
        onSmallStack(stackSize: 64 * 1024 * 1024) { pyResult = CodeChunker.chunks(py, language: .forExtension("py")) }
        XCTAssertLessThan(Date().timeIntervalSince(pyStarted), 2.0)
        assertCoversEveryNonBlankLine(pyResult, py)
    }

    func testNestedNamesStillJoinWithDots() {
        let inner = ["        func inner() {"] + (0..<70).map { "            i += \($0)" } + ["        }"]
        let other = ["        func other() {"] + (0..<70).map { "            o += \($0)" } + ["        }"]
        let src = ["struct Outer {", "    struct Middle {"] + inner + other + ["    }", "}"]
        XCTAssertEqual(chunks(src, "swift"), [CodeChunk(line0: 1, line1: 74, symbol: "Outer.Middle.inner"),
                                              CodeChunk(line0: 75, line1: 148, symbol: "Outer.Middle.other")])
    }

    func testAnchorJSON() {
        XCTAssertEqual(CodeChunker.anchorJSON(line0: 3, line1: 14, symbol: "retry"), #"{"line0":3,"line1":14,"symbol":"retry"}"#)
        XCTAssertEqual(CodeChunker.anchorJSON(line0: 1, line1: 2, symbol: nil), #"{"line0":1,"line1":2}"#)
        XCTAssertEqual(CodeChunker.anchorJSON(line0: 1, line1: 2, symbol: String(repeating: "s", count: 300)).count,
                       #"{"line0":1,"line1":2,"symbol":""}"#.count + 120)
    }

    func testTheChunkerNeverFailsAndCoversEveryNonBlankLineWithinTheDocumentedOverlap() {
        let inputs: [(String, [String], String)] = [
            ("only closing braces", Array(repeating: "}", count: 50), "swift"),
            ("unterminated block comment", ["func a() {", "    /* never closed", "    x()", "}", "func b() {", "}"], "swift"),
            ("unterminated triple quote (swift)", ["let s = \"\"\"", "text", "func c() {", "}"], "swift"),
            ("unterminated triple quote (python)", ["s = \"\"\"", "text", "def c():", "    pass"], "py"),
            ("10,000-line function", swiftFunc("huge", body: 9_998), "swift"),
            ("empty file", [], "swift"),
            ("single 5,000-character line", [String(repeating: "x", count: 5_000)], "swift"),
        ]
        for (label, lines, ext) in inputs {
            let result = chunks(lines, ext)
            var covered = [Int](repeating: 0, count: lines.count)
            for c in result {
                XCTAssertLessThanOrEqual(c.line0, c.line1, label)
                XCTAssertGreaterThanOrEqual(c.line0, 1, label)
                XCTAssertLessThanOrEqual(c.line1, lines.count, label)
                for n in c.line0...c.line1 { covered[n - 1] += 1 }
            }
            for (i, line) in lines.enumerated() where !CodeChunker.isBlank(line) {
                XCTAssertGreaterThanOrEqual(covered[i], 1, "\(label): line \(i + 1) uncovered")
                // only the 60/40 window overlap (20 lines) may cover a line twice
                XCTAssertLessThanOrEqual(covered[i], 2, "\(label): line \(i + 1) covered \(covered[i])x")
            }
            if lines.isEmpty { XCTAssertTrue(result.isEmpty, label) }
        }
    }
}
