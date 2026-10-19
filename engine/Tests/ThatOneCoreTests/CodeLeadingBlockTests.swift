import XCTest
@testable import ThatOneCore

/// Limits of the leading comment block, body-less declarations, and the split rule over attached comments.
final class CodeLeadingBlockTests: XCTestCase {
    func chunks(_ lines: [String], _ ext: String) -> [CodeChunk] { CodeChunker.chunks(lines, language: .forExtension(ext)) }

    func assertCovered(_ result: [CodeChunk], _ lines: [String], file: StaticString = #filePath, line: UInt = #line) {
        var covered = [Int](repeating: 0, count: lines.count)
        for c in result {
            XCTAssertLessThanOrEqual(c.line0, c.line1, file: file, line: line)
            for n in c.line0...c.line1 { covered[n - 1] += 1 }
        }
        for (i, text) in lines.enumerated() where !CodeChunker.isBlank(text) {
            XCTAssertGreaterThanOrEqual(covered[i], 1, "line \(i + 1) uncovered", file: file, line: line)
            XCTAssertLessThanOrEqual(covered[i], 2, "line \(i + 1) covered \(covered[i])x", file: file, line: line)
        }
    }

    /// Every member's doc comment is inside a chunk that also holds the member's own line.
    func assertDocsTravelWithMembers(_ result: [CodeChunk], docs: [(doc: Int, member: Int)], file: StaticString = #filePath, line: UInt = #line) {
        for pair in docs {
            XCTAssertTrue(result.contains { $0.line0 <= pair.doc && pair.member <= $0.line1 },
                          "doc on line \(pair.doc) is not with its member on line \(pair.member): \(result.map { [$0.line0, $0.line1] })",
                          file: file, line: line)
        }
    }

    // MARK: - the leading block is capped

    func testOnlyTheNearestThirtyCommentLinesAttach() {
        XCTAssertEqual(CodeChunker.maxLeading, 30)
        let src = (1...200).map { "// old_call(\($0))" } + ["func f() {"] + (0..<4).map { "    n += \($0)" } + ["}"]
        let got = chunks(src, "swift")
        XCTAssertEqual(got.filter { $0.symbol == "f" }, [CodeChunk(line0: 171, line1: 206, symbol: "f")])
        XCTAssertEqual(got.filter { $0.symbol == nil }.map { [$0.line0, $0.line1] }, [[1, 60], [41, 100], [81, 140], [121, 170]])
        assertCovered(got, src)
    }

    func testAnAdjacentLicenceShorterThanTheCapStillAttaches() {
        let src = ["/*", " * Copyright 2026 shyn labs.", " */", "func run() {"] + (0..<8).map { "    n += \($0)" } + ["}"]
        XCTAssertEqual(chunks(src, "swift"), [CodeChunk(line0: 1, line1: 13, symbol: "run")])
    }

    // MARK: - body-less declarations

    func testSwiftProtocolRequirementsKeepTheirDocComments() {
        var src = ["protocol Store {"]
        var docs: [(doc: Int, member: Int)] = []
        for n in 0..<45 {
            src += ["    /// Requirement \(n).", "    /// It returns a number.", "    func req\(n)() -> Int"]
            docs.append((src.count - 2, src.count)); docs.append((src.count - 1, src.count))
        }
        src.append("}")
        let got = chunks(src, "swift")
        XCTAssertGreaterThan(got.count, 1)                          // over 120 lines: split at the requirements
        assertDocsTravelWithMembers(got, docs: docs)
        assertCovered(got, src)
    }

    func testKotlinInterfaceMethodsKeepTheirDocComments() {
        var src = ["interface Repo {"]
        var docs: [(doc: Int, member: Int)] = []
        for n in 0..<45 {
            src += ["    /** Loads item \(n). */", "    @Throws(IOException::class)", "    fun load\(n)(id: Int): Item"]
            docs.append((src.count - 2, src.count)); docs.append((src.count - 1, src.count))
        }
        src.append("}")
        let got = chunks(src, "kt")
        XCTAssertGreaterThan(got.count, 1)
        assertDocsTravelWithMembers(got, docs: docs)
        assertCovered(got, src)
    }

    func testTypeScriptInterfaceMembersKeepTheirDocComments() {
        var src = ["export interface Api {"]
        var docs: [(doc: Int, member: Int)] = []
        for n in 0..<45 {
            src += ["  /** Fetches page \(n). */", "  // cached for a minute", "  fetch\(n)(q: Query): Promise<Page>;"]
            docs.append((src.count - 2, src.count)); docs.append((src.count - 1, src.count))
        }
        src.append("}")
        let got = chunks(src, "ts")
        assertDocsTravelWithMembers(got, docs: docs)
        assertCovered(got, src)
    }

    func testCPrototypesKeepTheirDocComments() {
        var src: [String] = []
        var docs: [(doc: Int, member: Int)] = []
        for n in 0..<45 {
            src += ["/* Parses part \(n). */", "int parse_\(n)(const char *buf)"]
            docs.append((src.count - 1, src.count))
        }
        let got = chunks(src, "c")
        assertDocsTravelWithMembers(got, docs: docs)
        assertCovered(got, src)
    }

    // MARK: - the split rule counts the attached comment

    /// The type alone is 115 lines (no split); with its 10-line doc comment it is 125, so it is split at its members.
    func testACommentThatPushesATypeOverTheLimitSplitsItAtItsMembers() {
        let alpha = ["    func alpha() {"] + (0..<54).map { "        a += \($0)" } + ["    }"]           // 56 lines
        let beta = ["    func beta() {"] + (0..<55).map { "        b += \($0)" } + ["    }"]            // 57 lines
        let src = (0..<10).map { "/// Ledger doc \($0)" } + ["struct Ledger {"] + alpha + beta + ["}"]  // 10 + 115
        XCTAssertEqual(src.count, 125)
        XCTAssertEqual(chunks(src, "swift"), [
            CodeChunk(line0: 1, line1: 67, symbol: "Ledger.alpha"),               // the doc, the header and alpha
            CodeChunk(line0: 68, line1: 125, symbol: "Ledger.beta"),
        ])
    }

    /// A documented type over 120 lines with members: its doc comment is covered and starts the first chunk.
    func testTheDocCommentOfASplitTypeStartsItsFirstChunk() {
        let alpha = ["    func alpha() {"] + (0..<60).map { "        a += \($0)" } + ["    }"]
        let beta = ["    func beta() {"] + (0..<60).map { "        b += \($0)" } + ["    }"]
        let src = ["/// The ledger.", "/// Keeps totals.", "struct Ledger {", "    var a = 0"] + alpha + beta + ["}"]
        let got = chunks(src, "swift")
        XCTAssertEqual(got.first?.line0, 1)
        XCTAssertEqual(got.map { [$0.line0, $0.line1] }, [[1, 4], [5, 66], [67, 129]])
        assertCovered(got, src)
    }
}
