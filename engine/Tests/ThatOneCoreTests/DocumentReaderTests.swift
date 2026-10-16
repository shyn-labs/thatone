import Darwin
import XCTest
@testable import ThatOneCore

final class DocumentReaderTests: XCTestCase {
    func anchor(_ s: ReadSegment) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(s.anchor.utf8)) as? [String: Any]) ?? [:] }

    func assertSampleRead(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let result = try DocumentReader().read(url)
        let all = result.segments.map { $0.text }.joined(separator: "\n")
        XCTAssertTrue(all.contains("notice period under this agreement"), all, file: file, line: line)
        XCTAssertTrue(all.contains("forty five days"), file: file, line: line)
        XCTAssertTrue(all.contains("ಬೆಂಗಳೂರು ನಗರದ ಹವಾಮಾನ"), "Kannada must survive the conversion", file: file, line: line)
        XCTAssertTrue(result.segments.allSatisfy { $0.modality == "text" && $0.image == nil }, file: file, line: line)
        XCTAssertEqual(result.segments.compactMap { anchor($0)["heading"] as? String }.first, "Notice period", file: file, line: line)
    }

    func testDocxRtfOdtAndHtmlAreRead() throws {
        let folder = DocFixtures.dir()
        for ext in ["docx", "rtf", "odt"] {
            try assertSampleRead(DocFixtures.convert(html: DocFixtures.sampleHTML, to: ext, in: DocFixtures.dir()))
        }
        let html = folder.appendingPathComponent("page.html")
        DocFixtures.write(DocFixtures.sampleHTML, to: html)
        try assertSampleRead(html)
    }

    func testPlainTextAndMarkdownAreReadDirectlyWithoutTextutil() throws {
        let folder = DocFixtures.dir()
        let txt = folder.appendingPathComponent("notes.txt")
        DocFixtures.write("Meeting notes\n\nWe agreed the notice period is thirty days and the next review is in March after the harvest.", to: txt)
        let reader = DocumentReader(textutil: "/nonexistent/textutil")             // must not be needed for txt and md
        let result = try reader.read(txt)
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertTrue(result.segments[0].text.contains("notice period is thirty days"))
        let md = folder.appendingPathComponent("readme.md")
        DocFixtures.write("# Title\n\nSome markdown body text that is long enough to be a paragraph of its own here.", to: md)
        XCTAssertFalse(try reader.read(md).segments.isEmpty)
    }

    func testInvalidUTF8IsReadLossilyNotRejected() throws {
        let url = DocFixtures.dir().appendingPathComponent("latin1.txt")
        try Data([0x63, 0x61, 0x66, 0xE9, 0x20, 0x6D, 0x65, 0x6E, 0x75, 0x20, 0x61, 0x6E, 0x64, 0x20, 0x70, 0x72, 0x69, 0x63, 0x65, 0x73]).write(to: url)
        let text = try DocumentReader().read(url).segments.first?.text ?? ""
        XCTAssertTrue(text.contains("menu and prices"), text)
    }

    func testCorruptAndEmptyDocumentsAreRefusedWithReasons() throws {
        let folder = DocFixtures.dir()
        let corrupt = folder.appendingPathComponent("broken.docx")
        try Data((0..<2000).map { UInt8(($0 * 37 + 11) % 256) }).write(to: corrupt)
        XCTAssertThrowsError(try DocumentReader().read(corrupt)) { XCTAssertTrue($0 is ReadFailure, "\($0)") }
        let empty = folder.appendingPathComponent("empty.txt")
        DocFixtures.write("  \n\n \t ", to: empty)
        XCTAssertThrowsError(try DocumentReader().read(empty)) { guard case .empty? = $0 as? ReadFailure else { return XCTFail("\($0)") } }
        let emptyRTF = DocFixtures.convert(html: "<html><body></body></html>", to: "rtf", in: DocFixtures.dir())
        XCTAssertThrowsError(try DocumentReader().read(emptyRTF)) { guard case .empty? = $0 as? ReadFailure else { return XCTFail("\($0)") } }
    }

    func testAToolThatHangsIsKilledAfterTheTimeout() throws {
        let url = DocFixtures.dir().appendingPathComponent("a.html")
        DocFixtures.write("x", to: url)
        let reader = DocumentReader(textutil: DocFixtures.fakeTool("sleep 30"), timeout: 1)
        let started = Date()
        XCTAssertThrowsError(try reader.read(url)) { XCTAssertEqual($0 as? ReadFailure, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
    }

    func testAToolThatPrintsTooMuchIsStopped() throws {
        let url = DocFixtures.dir().appendingPathComponent("a.html")
        DocFixtures.write("x", to: url)
        let reader = DocumentReader(textutil: DocFixtures.fakeTool("head -c 20000000 /dev/zero | tr '\\0' 'a'"), timeout: 20, maxOutputBytes: 1_000_000)
        let started = Date()
        XCTAssertThrowsError(try reader.read(url)) { guard case .tooLarge? = $0 as? ReadFailure else { return XCTFail("\($0)") } }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testAMissingToolIsAnUnreadableFileNotACrash() throws {
        let url = DocFixtures.dir().appendingPathComponent("a.html")
        DocFixtures.write("x", to: url)
        XCTAssertThrowsError(try DocumentReader(textutil: "/nonexistent/textutil").read(url)) {
            guard case .unreadable? = $0 as? ReadFailure else { return XCTFail("\($0)") }
        }
    }

    func testHugeTextIsCappedWithANote() throws {
        let saved = ReadLimits.maxChars
        ReadLimits.maxChars = 3000
        defer { ReadLimits.maxChars = saved }
        let url = DocFixtures.dir().appendingPathComponent("big.txt")
        DocFixtures.write(String(repeating: "A reasonably ordinary sentence about notice periods. ", count: 400), to: url)
        let result = try DocumentReader().read(url)
        XCTAssertEqual(result.note, "first 3000 characters")
        XCTAssertLessThanOrEqual(result.segments.map { $0.text.count }.reduce(0, +), 3200)
    }

    func testOversizedFilesAreRefusedWithoutReadingThem() throws {
        let url = DocFixtures.dir().appendingPathComponent("big.txt")
        DocFixtures.write(String(repeating: "x", count: 5000), to: url)
        XCTAssertThrowsError(try DocumentReader(maxOutputBytes: 1000).read(url)) { guard case .tooLarge? = $0 as? ReadFailure else { return XCTFail("\($0)") } }
    }

    func testPartAnchorsNumberChunksFromOne() throws {
        let url = DocFixtures.dir().appendingPathComponent("long.txt")
        let paragraph = String(repeating: "The quick brown fox jumps over the lazy dog near the river bank. ", count: 15)
        DocFixtures.write(Array(repeating: paragraph, count: 8).joined(separator: "\n\n"), to: url)
        let result = try DocumentReader().read(url)
        XCTAssertGreaterThan(result.segments.count, 3)
        XCTAssertEqual(result.segments.compactMap { anchor($0)["part"] as? Int }, Array(1...result.segments.count))
    }

    /// A listener on a local TCP port that records whether anything connected to it.
    final class Listener {
        let fd: Int32
        let port: UInt16
        init() {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = UInt32(0x7F000001).bigEndian
            address.sin_port = 0
            _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            listen(descriptor, 4)
            var bound = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
            fd = descriptor
            port = UInt16(bigEndian: bound.sin_port)
        }
        deinit { close(fd) }
    }

    func testTheConverterRunsWithoutNetworkAccess() throws {
        let listener = Listener()
        let url = DocFixtures.dir().appendingPathComponent("a.html")
        DocFixtures.write("x", to: url)
        // The stand-in tries to connect to the local listener and reports what happened.
        let tool = DocFixtures.fakeTool("if /usr/bin/nc -z -w 2 127.0.0.1 \(listener.port) 2>/dev/null; then echo CONNECTED; else echo BLOCKED; fi")
        let control = try DocumentReader(textutil: tool, sandboxed: false).read(url)
        XCTAssertTrue(control.segments[0].text.contains("CONNECTED"), "control run: \(control.segments[0].text)")   // proves the probe can connect at all
        let sandboxed = try DocumentReader(textutil: tool).read(url)
        XCTAssertTrue(sandboxed.segments[0].text.contains("BLOCKED"), "sandboxed run: \(sandboxed.segments[0].text)")
    }

    func testTheConverterCannotWriteFiles() throws {
        let marker = DocFixtures.dir().appendingPathComponent("written.txt")
        let url = DocFixtures.dir().appendingPathComponent("a.html")
        DocFixtures.write("x", to: url)
        let tool = DocFixtures.fakeTool("echo hello > '\(marker.path)' 2>/dev/null; echo done")
        _ = try DocumentReader(textutil: tool).read(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        _ = try DocumentReader(textutil: tool, sandboxed: false).read(url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))                  // control: it could write without the sandbox
    }

    /// The real textutil on an HTML file full of remote references: nothing may connect (neither the converter nor any
    /// helper process it starts, which a sandbox on the converter alone would not cover).
    func testRealConversionOfHTMLWithRemoteReferencesMakesNoConnection() throws {
        let listener = Listener()
        let url = DocFixtures.dir().appendingPathComponent("remote.html")
        DocFixtures.write("""
        <html><head><link rel="stylesheet" href="http://127.0.0.1:\(listener.port)/s.css"></head>
        <body><img src="http://127.0.0.1:\(listener.port)/pixel.png"><iframe src="http://127.0.0.1:\(listener.port)/f.html"></iframe>
        <p>hello world text that is the real content of this page</p></body></html>
        """, to: url)
        let result = try DocumentReader().read(url)
        XCTAssertTrue(result.segments[0].text.contains("hello world"))
        Thread.sleep(forTimeInterval: 1.5)                                                   // let any late fetch happen
        var pending = pollfd(fd: listener.fd, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&pending, 1, 0), 0, "something connected to the listener while a document was converted")
    }

    func testSignatureCheckAcceptsHTMLSavedAsDocAndAByteOrderMarkIsNotAProblemOfOurs() throws {
        let folder = DocFixtures.dir()
        let rtf = DocFixtures.convert(html: DocFixtures.sampleHTML, to: "rtf", in: DocFixtures.dir())
        let withBOM = folder.appendingPathComponent("bom.rtf")
        try (Data([0xEF, 0xBB, 0xBF]) + Data(contentsOf: rtf)).write(to: withBOM)
        // textutil itself refuses an RTF that starts with a byte order mark; that must be a reported failure, not a crash or garbage.
        XCTAssertThrowsError(try DocumentReader().read(withBOM)) { XCTAssertTrue($0 is ReadFailure, "\($0)") }
        let webDoc = folder.appendingPathComponent("saved-as-web-page.doc")
        DocFixtures.write(DocFixtures.sampleHTML, to: webDoc)                              // Word's "Web Page" export is HTML with a .doc name
        XCTAssertFalse(try DocumentReader().read(webDoc).segments.isEmpty)
    }

    func testAFileThatFinishesJustBeforeTheWatchdogIsNotReportedAsTimedOut() throws {
        let url = DocFixtures.dir().appendingPathComponent("quick.html")
        DocFixtures.write("x", to: url)
        // Exits at about the timeout: whichever wins, a clean exit must never be reported as a timeout.
        let reader = DocumentReader(textutil: DocFixtures.fakeTool("sleep 0.9; echo finished text"), timeout: 1.0)
        for _ in 0..<3 {
            if let result = try? reader.read(url) { XCTAssertTrue(result.segments[0].text.contains("finished")) }
        }
    }
}
