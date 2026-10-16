import Foundation
import XCTest

enum DocFixtures {
    static func dir() -> URL { TestSupport.tempDir("docs") }

    static func write(_ text: String, to url: URL) {
        try! text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Converts HTML to another format with the system tool (so fixtures are real docx/odt/rtf files).
    static func convert(html: String, to ext: String, in folder: URL) -> URL {
        let source = folder.appendingPathComponent("source.html")
        write(html, to: source)
        let out = folder.appendingPathComponent("doc.\(ext)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        p.arguments = ["-convert", ext, "-output", out.path, source.path]
        try! p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "textutil could not make a .\(ext) fixture")
        return out
    }

    static let sampleHTML = """
    <html><head><meta charset="utf-8"></head><body>
    <h1>Notice period</h1>
    <p>The notice period under this agreement is thirty days from the date of written notice, and either party may give it.</p>
    <h1>Payment terms</h1>
    <p>Invoices are due within forty five days of receipt, and late payments carry interest at the agreed monthly rate.</p>
    <p>ಬೆಂಗಳೂರು ನಗರದ ಹವಾಮಾನ ಇಂದು ಚೆನ್ನಾಗಿದೆ ಮತ್ತು ಮಳೆ ಬರುವ ಸಾಧ್ಯತೆ ಇದೆ ಎಂದು ಹೇಳಲಾಗಿದೆ.</p>
    </body></html>
    """

    /// A stand-in for textutil: a script with the given body.
    static func fakeTool(_ body: String) -> String {
        let url = dir().appendingPathComponent("fake-textutil.sh")
        write("#!/bin/sh\n\(body)\n", to: url)
        chmod(url.path, 0o755)
        return url.path
    }
}
