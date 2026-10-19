import XCTest
@testable import ThatOneCore

/// The chunker reads untrusted repository content: no line may make a pattern or the attribute check backtrack
/// super-linearly. Each check runs on a worker thread so a runaway one fails the test instead of hanging the suite.
final class CodePatternBacktrackingTests: XCTestCase {
    static let extensions = ["swift", "ts", "py", "go", "rs", "java", "cs", "kt", "scala", "c", "cpp", "m", "php", "rb", "lua", "sh", "sql"]

    /// 400-character (the cap) attribute-like and declaration-like lines built to trip nested quantifiers.
    static let hostile: [(String, String)] = {
        func fill(_ unit: String, _ tail: String = "") -> String { String(String(repeating: unit, count: 400 / unit.count + 1).prefix(400 - tail.count)) + tail }
        return [
            ("@a( repeated", fill("@a(")),
            ("@a() repeated then junk", fill("@a()", "x")),
            ("@a()@ then junk", fill("@a() ", "!")),
            ("@a + spaces + (", "@a" + String(repeating: " ", count: 397) + "("),
            ("unbalanced )( after @a(", "@a(" + fill(")(").dropFirst(3)),
            ("100 @x tokens then junk", String(repeating: "@x ", count: 100) + "!"),
            ("@a(@a(... closed", fill("@a(", String(repeating: ")", count: 5))),
            ("@a(x)) repeated", fill("@a(x))")),
            ("[a] repeated", fill("[a]", "x")),
            ("#[a] repeated", fill("#[a]", "x")),
            ("[[a]] repeated", fill("[[a]]", "x")),
            ("modifiers then nothing", fill("public ")),
            ("get set repeated", fill("get set ", "x")),
            ("swift attrs no decl", fill("@objc ", "x")),
            ("swift attr args no decl", fill("@a(b) ", "x")),
            ("java annotations no decl", fill("@A.b(c) ", "x")),
            ("c pointer soup", fill("a * & ", "x")),
            ("c words then paren", fill("int ", "(;")),
            ("generic soup", fill("a<b, ", "(")),
            ("open parens", fill("(")),
            ("close parens", fill(")")),
            ("ts arrow soup", "const a = " + fill("(b) => ", "x").dropFirst(10)),
            ("ts method no brace", "a" + fill("(b): c ", "x").dropFirst(1)),
            ("ts method many parens", "a" + fill("(b)", " {x").dropFirst(1)),
            ("rust impl soup", "impl" + fill("<a> for ", "x").dropFirst(4)),
            ("kotlin mods soup", fill("data inline ", "x")),
            ("scala mods soup", fill("private[a] ", "x")),
            ("ruby defs", fill("def self.", "x")),
            ("lua funcs", fill("function a.", "(")),
            ("shell names", fill("a-b ", "(")),
            ("swift backtick", "func " + fill("`a", "x").dropFirst(5)),
            ("ts colon soup", "a(" + fill("):", "x").dropFirst(2)),
            ("ts type soup", "a(b)" + fill(": c", " {x").dropFirst(4)),
            ("java bracket mods", fill("[a] ", "x")),
            ("java type then names", fill("List<a> b ", "x")),
            ("c words no paren", fill("unsigned long ", "x")),
            ("swift mods unclosed", fill("@a(b @c(", "x")),
            ("swift keyword mods", fill("public(set) ", "x")),
        ]
    }()

    /// Runs `body` on a thread; fails (instead of hanging) if it is still going after `limit` seconds.
    func withinDeadline(_ limit: TimeInterval, _ label: String, _ body: @escaping () -> Void, file: StaticString = #filePath, line: UInt = #line) {
        let done = expectation(description: label)
        Thread { body(); done.fulfill() }.start()
        let result = XCTWaiter().wait(for: [done], timeout: limit)
        XCTAssertEqual(result, .completed, "\(label): still running after \(limit) s", file: file, line: line)
    }

    func millis(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    func testEveryPatternAndTheAttributeCheckStayFastOnHostileLines() {
        for (label, line) in Self.hostile {
            XCTAssertLessThanOrEqual(line.count, 401, label)
            for ext in Self.extensions {
                let lang = CodeLanguage.forExtension(ext)
                var worst = 0.0
                withinDeadline(5, "\(ext) \(label)") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    worst = max(self.millis { _ = lang.declarationName(line) },
                                self.millis { _ = lang.isAttribute(trimmed) },
                                self.millis { _ = lang.isAttribute(trimmed, opening: true) },
                                self.millis { _ = CodeChunker.chunks([line, "func f() {", "}"], language: lang) })
                }
                XCTAssertLessThan(worst, 100, "\(ext) \(label): \(worst) ms")
            }
        }
    }

    func testAFileOfHostileLinesChunksInUnderTwoSeconds() {
        let lines = (0..<5_000).map { Self.hostile[$0 % Self.hostile.count].1 }
        for ext in ["swift", "ts", "py", "rs", "java", "c"] {
            var seconds = 0.0
            withinDeadline(20, ext) { seconds = self.millis { _ = CodeChunker.chunks(lines, language: .forExtension(ext)) } / 1000 }
            XCTAssertLessThan(seconds, 2.0, "\(ext): \(seconds) s")
        }
    }

    func testTheAttributeScannerKeepsTheShapesItAcceptedBefore() {
        let swift = CodeLanguage.forExtension("swift"), py = CodeLanguage.forExtension("py"), ts = CodeLanguage.forExtension("ts")
        let rs = CodeLanguage.forExtension("rs"), cs = CodeLanguage.forExtension("cs"), c = CodeLanguage.forExtension("c")
        for yes in ["@available(macOS 13, *)", "@discardableResult", "@objc @MainActor", "@inlinable", "@a(b(c)) @d",
                    "@available(iOS, deprecated: 1, message: \"use (x) instead\")"] {
            XCTAssertTrue(swift.isAttribute(yes), yes)
        }
        for no in ["@Published var x = 1", "@objc // why", "@a(", "@a(b))", "@ a", "@1x", "x @a", "@a(b) c", ""] {
            XCTAssertFalse(swift.isAttribute(no), no)
        }
        XCTAssertTrue(py.isAttribute("@app.route(\"/text\", methods=[\"GET\"])"))
        XCTAssertTrue(py.isAttribute("@functools.cache"))
        XCTAssertFalse(ts.isAttribute("@Input() name: string;"))
        XCTAssertTrue(ts.isAttribute("@Component({", opening: true))
        XCTAssertFalse(ts.isAttribute("@Component", opening: true))
        XCTAssertTrue(rs.isAttribute("#[derive(Debug, Clone)]"))
        XCTAssertFalse(rs.isAttribute("#![allow(dead_code)]"))
        XCTAssertTrue(rs.isAttribute("#[derive(Debug,", opening: true))
        XCTAssertTrue(cs.isAttribute("[Obsolete(\"use RunAsync\")]"))
        XCTAssertFalse(cs.isAttribute("[1, 2]"))
        XCTAssertTrue(c.isAttribute("[[nodiscard]]"))
        XCTAssertFalse(c.isAttribute("[[nodiscard]"))
        XCTAssertFalse(CodeLanguage.forExtension("go").isAttribute("@a"))
    }
}
