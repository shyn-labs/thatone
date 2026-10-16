import CoreGraphics
import CoreText
import Foundation
import ImageIO
import XCTest
@testable import ThatOneCore

/// Builds PDFs with CoreGraphics so no real document is ever needed.
enum PDFFixtures {
    enum Page {
        case text(String, fontSize: CGFloat = 12)
        case image(CGImage)
        case blank
        case fill                 // the whole page black
    }

    static func make(_ pages: [Page], at url: URL, password: String? = nil) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        var info: [CFString: Any] = [:]
        if let password { info[kCGPDFContextUserPassword] = password; info[kCGPDFContextOwnerPassword] = password + "-owner" }
        guard let context = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else { return XCTFail("no PDF context") }
        for page in pages {
            context.beginPDFPage(nil)
            switch page {
            case .text(let text, let fontSize):
                let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
                var y: CGFloat = 760
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    let attributed = NSAttributedString(string: String(line), attributes: [.font: font])
                    context.textPosition = CGPoint(x: 36, y: y)
                    CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
                    y -= fontSize * 1.2
                    if y < 20 { break }
                }
            case .image(let image):
                context.draw(image, in: box.insetBy(dx: 20, dy: 20))
            case .blank:
                break
            case .fill:
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.fill(box)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// A white page with big black text, as a bitmap (what a scanner would produce).
    static func scan(_ text: String) -> CGImage {
        let url = TestSupport.tempDir("scan").appendingPathComponent("s.png")
        try! makeImage(width: 1500, height: 600, text: text, at: url)
        return CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
    }

    static func file(_ name: String = "doc.pdf") -> URL { TestSupport.tempDir("pdf").appendingPathComponent(name) }
}
