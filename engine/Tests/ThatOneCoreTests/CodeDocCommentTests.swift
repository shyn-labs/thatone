import XCTest
@testable import ThatOneCore

/// A doc comment, a decorator or an attribute directly above a declaration belongs to that declaration's chunk
/// (M5 acceptance: a hit's anchor landed on the comment and the preview showed only the comment).
final class CodeDocCommentTests: XCTestCase {
    func chunks(_ lines: [String], _ ext: String) -> [CodeChunk] { CodeChunker.chunks(lines, language: .forExtension(ext)) }
    func body(_ n: Int, _ pad: String = "    ") -> [String] { (0..<n).map { "\(pad)total += \($0)" } }

    /// The exact acceptance shape: a JSDoc block on lines 1-4, the function on 5-16.
    static let netTS = ["/**", " * Fetches a URL again and again with exponential backoff until it answers.",
                        " * @param url where to fetch from", " */",
                        "export async function fetchPersistently(url: string) {"]
        + (0..<10).map { "  delay *= 2; // step \($0)" } + ["}"]

    func testTypeScriptJSDocBlockJoinsItsFunction() {
        XCTAssertEqual(chunks(Self.netTS, "ts"), [CodeChunk(line0: 1, line1: 16, symbol: "fetchPersistently")])
        let oneLine = ["// Caches results for a minute."] + ["export function cached(key: string) {"] + body(8, "  ") + ["}"]
        XCTAssertEqual(chunks(oneLine, "ts"), [CodeChunk(line0: 1, line1: 11, symbol: "cached")])
    }

    func testSwiftDocCommentAndAttributesJoinTheFunction() {
        let swift = ["import CryptoKit", "", "/// Hex digest of a file.", "/// - Parameter url: the file.", "/// - Returns: 64 hex characters.",
                     "/// Reads in 1 MB pieces.", "/// Never throws for an empty file.", "@available(macOS 13, *)", "@discardableResult",
                     "public func digest(of url: URL) -> String {"] + body(8) + ["}"]
        XCTAssertEqual(chunks(swift, "swift"), [CodeChunk(line0: 1, line1: 2, symbol: nil),
                                                CodeChunk(line0: 3, line1: 19, symbol: "digest")])
    }

    func testPythonCommentsAndDecoratorsJoinTheFunction() {
        let py = ["import re", "", "# Collapses whitespace.", "# Used by the indexer.", "@functools.cache",
                  "@app.route(\"/text\", methods=[\"GET\"])", "def normalise(text):"] + body(8) + ["", "x = 1"]
        XCTAssertEqual(chunks(py, "py"), [CodeChunk(line0: 1, line1: 2, symbol: nil),
                                          CodeChunk(line0: 3, line1: 15, symbol: "normalise"),
                                          CodeChunk(line0: 16, line1: 17, symbol: nil)])
    }

    func testPythonCommentIndentedUnderThePreviousBlockStaysWithIt() {
        let py = ["def a():"] + body(8) + ["    # the tail of a", "# What b does.", "def b():"] + body(8)
        XCTAssertEqual(chunks(py, "py").last, CodeChunk(line0: 11, line1: 20, symbol: "b"))
    }

    func testShellCommentJoinsTheFunctionButTheShebangHeaderDoesNot() {
        let sh = ["#!/bin/bash", "# Housekeeping for the log folder.", "", "# Deletes logs older than a week.",
                  "# Keeps the newest one.", "# Safe to run twice.", "housekeeping() {"] + body(8, "  ") + ["}"]
        XCTAssertEqual(chunks(sh, "sh"), [CodeChunk(line0: 1, line1: 3, symbol: nil),
                                          CodeChunk(line0: 4, line1: 16, symbol: "housekeeping")])
        let adjacent = ["#!/bin/sh", "# Cleans up.", "cleanup() {"] + body(8, "  ") + ["}"]
        XCTAssertEqual(chunks(adjacent, "sh"), [CodeChunk(line0: 1, line1: 1, symbol: nil),     // a shebang is never a doc comment
                                                CodeChunk(line0: 2, line1: 12, symbol: "cleanup")])
    }

    func testGoDocCommentJoinsTheFunction() {
        let go = ["package net", "", "// Retry calls fn until it succeeds.", "// It waits longer each time.",
                  "func Retry(fn func() error) error {"] + body(8, "\t") + ["}"]
        XCTAssertEqual(chunks(go, "go"), [CodeChunk(line0: 1, line1: 2, symbol: nil),
                                          CodeChunk(line0: 3, line1: 14, symbol: "Retry")])
    }

    func testRustDocCommentAndAttributesJoinTheFunction() {
        let rs = ["use std::io;", "", "/// Embeds one batch.", "/// Returns the vectors in order.", "#[inline]",
                  "#[derive(Debug,", "         Clone)]", "pub fn embed(batch: &[String]) -> Vec<f32> {"] + body(8) + ["}"]
        XCTAssertEqual(chunks(rs, "rs"), [CodeChunk(line0: 1, line1: 2, symbol: nil),
                                          CodeChunk(line0: 3, line1: 17, symbol: "embed")])
        let inner = ["//! The embedding module.", "fn first() {"] + body(8) + ["}"]          // a module doc is not the function's
        XCTAssertEqual(chunks(inner, "rs").last, CodeChunk(line0: 2, line1: 11, symbol: "first"))
    }

    func testCFamilyBlockCommentJoinsTheFunction() {
        let c = ["#include <stdio.h>", "", "/* Parses a header.", "   Returns -1 on a short buffer. */",
                 "static int parse_header(const char *buf, size_t n)", "{"] + body(8) + ["}"]
        XCTAssertEqual(chunks(c, "c"), [CodeChunk(line0: 1, line1: 2, symbol: nil),
                                        CodeChunk(line0: 3, line1: 15, symbol: "parse_header")])
        let cs = ["// Runs the job.", "[Obsolete(\"use RunAsync\")]", "public int Run(int n)", "{"] + body(8) + ["}"]
        XCTAssertEqual(chunks(cs, "cs"), [CodeChunk(line0: 1, line1: 13, symbol: "Run")])
    }

    func testALicenceHeaderFollowedByABlankLineIsNotSwallowed() {
        let licence = ["/*", " * Copyright 2026 shyn labs.", " * Licensed under the Elastic License 2.0.", " */", "",
                       "func run() {"] + body(10) + ["}"]
        XCTAssertEqual(chunks(licence, "swift"), [CodeChunk(line0: 1, line1: 5, symbol: nil),
                                                  CodeChunk(line0: 6, line1: 17, symbol: "run")])
        let jsdocThenBlank = ["/** Not attached across a blank line. */", "", "export function later() {"] + body(8, "  ") + ["}"]
        XCTAssertEqual(chunks(jsdocThenBlank, "ts"), [CodeChunk(line0: 1, line1: 2, symbol: nil),
                                                      CodeChunk(line0: 3, line1: 12, symbol: "later")])
        let divider = ["// MARK: - Helpers", "", "func helper() {"] + body(8) + ["}"]
        XCTAssertEqual(chunks(divider, "swift").first, CodeChunk(line0: 1, line1: 2, symbol: nil))
    }

    func testADecoratorOnlyPrefixJoinsTheDeclaration() {
        let py = ["@dataclass", "class Point:"] + body(8)
        XCTAssertEqual(chunks(py, "py"), [CodeChunk(line0: 1, line1: 10, symbol: "Point")])
        let ts = ["@Component({", "  selector: \"app-root\",", "})", "export class AppComponent {"] + body(8, "  ") + ["}"]
        XCTAssertEqual(chunks(ts, "ts"), [CodeChunk(line0: 1, line1: 13, symbol: "AppComponent")])
    }

    func testMembersOfALongTypeKeepTheirDocComments() {
        let alpha = ["    /// Adds the alphas.", "    func alpha() {"] + (0..<60).map { "        a += \($0)" } + ["    }"]
        let beta = ["    /// Adds the betas.", "    @inlinable", "    func beta() {"] + (0..<60).map { "        b += \($0)" } + ["    }"]
        let src = ["struct Ledger {", "    var a = 0"] + alpha + beta + ["}"]
        XCTAssertEqual(chunks(src, "swift"), [
            CodeChunk(line0: 1, line1: 2, symbol: "Ledger"),
            CodeChunk(line0: 3, line1: 65, symbol: "Ledger.alpha"),
            CodeChunk(line0: 66, line1: 130, symbol: "Ledger.beta"),
        ])
    }

    func testTheSplitRuleCountsTheAttachedComment() {
        let src = (0..<10).map { "/// line \($0)" } + ["func big() {"] + body(113) + ["}"]   // 10 + 115 = 125 lines
        let got = chunks(src, "swift")
        XCTAssertEqual(got.map { [$0.line0, $0.line1] }, [[1, 60], [41, 100], [81, 125]])
        XCTAssertTrue(got.allSatisfy { $0.symbol == "big" })
    }

    func testCoverageStillHoldsWithCommentsEverywhere() {
        let inputs: [(String, [String])] = [
            ("swift", ["/// a"] + ["func a() {"] + body(3) + ["}", "/* x", "", "y */", "@objc", "func b() {"] + body(9) + ["}", "// end"]),
            ("py", ["# a", "@d", "def a():"] + body(2) + ["# b", "", "# c", "class C:", "    # m", "    @property", "    def m(self):"] + body(9, "        ")),
            ("ts", ["/**", "", " */", "function f() {"] + body(12, "  ") + ["}"]),
        ]
        for (ext, lines) in inputs {
            let result = chunks(lines, ext)
            var covered = [Int](repeating: 0, count: lines.count)
            for c in result {
                XCTAssertLessThanOrEqual(c.line0, c.line1, ext)
                for n in c.line0...c.line1 { covered[n - 1] += 1 }
            }
            for (i, line) in lines.enumerated() where !CodeChunker.isBlank(line) {
                XCTAssertEqual(covered[i], 1, "\(ext): line \(i + 1)")
            }
        }
    }

    func testTheStoredAnchorOfADocCommentedFunctionSpansCommentThroughFunction() throws {
        let repo = TestSupport.tempDir("repo")
        CodeIndexingTests.write(Self.netTS.joined(separator: "\n") + "\n", "src/net.ts", in: repo)
        let e = try CodeIndexingTests.makeEngine()
        try CodeIndexingTests.indexAll(e, repo)
        let hits = try Searcher(store: e.store).search(query: "exponential backoff", queryVector: nil, filters: SearchFilters(kinds: ["code"]))
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.anchors.map(\.anchor), [#"{"line0":1,"line1":16,"symbol":"fetchPersistently"}"#])
    }
}
