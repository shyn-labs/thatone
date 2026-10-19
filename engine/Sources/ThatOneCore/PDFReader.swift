import CoreGraphics
import Foundation
import PDFKit

/// Reads a PDF page by page: the text layer where there is one, and for pages that are only a picture of text (scans)
/// a rendering that is OCR'd and also kept as an image for the visual embedding. One page is rendered at a time.
public final class PDFReader: FileReader {
    public static let ocrSide = 1600
    private let ocr: (CGImage) throws -> String

    public init(ocr: @escaping (CGImage) throws -> String = { try OCR.text(in: $0) }) { self.ocr = ocr }

    public func read(_ url: URL) throws -> ReadResult {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= ReadLimits.maxFileBytes else { throw ReadFailure.tooLarge(url.lastPathComponent) }
        guard let document = PDFDocument(url: url) else { throw ReadFailure.unreadable("not a readable PDF") }
        if document.isLocked && !document.unlock(withPassword: "") { throw ReadFailure.locked }
        guard document.pageCount > 0 else { throw ReadFailure.empty("no pages") }

        var segments: [ReadSegment] = []
        var notes: [String] = []
        var characters = 0
        var scanned = 0
        var skippedScans = 0
        let pages = min(document.pageCount, ReadLimits.maxPages)
        if document.pageCount > ReadLimits.maxPages { notes.append("first \(ReadLimits.maxPages) pages") }

        for index in 0..<pages {
            if characters >= ReadLimits.maxChars { notes.append("stopped at page \(index) (text limit)"); break }
            try autoreleasepool {
                guard let page = document.page(at: index) else { return }
                let number = index + 1
                let text = Self.clean(page.string ?? "")
                if text.count >= ReadLimits.scannedPageThreshold {
                    characters += text.count
                    let chunks = TextChunker.chunks(text)
                    for chunk in chunks {
                        segments.append(ReadSegment(modality: "text",
                                                    anchor: TextChunker.anchorJSON(page: number, part: chunks.count > 1 ? chunk.index + 1 : nil, heading: nil),
                                                    text: chunk.text))
                    }
                    return
                }
                guard scanned < ReadLimits.maxScannedPages else { skippedScans += 1; return }
                scanned += 1
                guard let rendered = Self.render(page, longSide: Self.ocrSide) else { return }
                let recognized: String
                do { recognized = Self.clean(try ocr(rendered)) }
                catch ReadFailure.timedOut { throw ReadFailure.timedOut }                // fails the file: "reading took too long"
                catch let busy as OCRUnavailable { throw busy }                           // nothing ran: the file waits
                catch { throw ReadFailure.unreadable("ocr failed on page \(number)") }   // the secret gate could not run
                let anchor = TextChunker.anchorJSON(page: number, part: nil, heading: nil)
                characters += recognized.count
                if recognized.count >= 3 { segments.append(ReadSegment(modality: "text", anchor: anchor, text: recognized)) }
                if !Self.isBlank(rendered), let small = ImagePrep.scaled(rendered, maxSide: ImagePrep.embedMaxSide) {
                    segments.append(ReadSegment(modality: "image", anchor: anchor, text: recognized, image: small))
                }
            }
        }
        if skippedScans > 0 { notes.append("\(skippedScans) scanned pages beyond the first \(ReadLimits.maxScannedPages) not read") }
        guard !segments.isEmpty else { throw ReadFailure.empty("no text found") }
        return ReadResult(segments: segments, note: notes.joined(separator: "; "))
    }

    /// Control characters out, runs of blanks collapsed, line structure kept.
    static func clean(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var lastWasBlank = false
        for scalar in text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars {
            if scalar == "\n" || scalar == "\r" { out.append("\n"); lastWasBlank = false; continue }
            if scalar.properties.isWhitespace { if !lastWasBlank { out.append(" ") }; lastWasBlank = true; continue }   // tabs and form feeds too
            if scalar.properties.generalCategory == .control || scalar == "\u{FFFD}" { continue }
            out.append(scalar); lastWasBlank = false
        }
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A page that is one flat colour (an empty scan) has nothing to embed.
    static func isBlank(_ image: CGImage) -> Bool {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn, let low = pixels.min(), let high = pixels.max() else { return false }
        return high - low < 12
    }

    /// The page drawn on white so that its long side is about `longSide` pixels, upright (rotation is applied).
    static func render(_ page: PDFPage, longSide: Int) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)                       // already turned by the page's rotation
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = Double(longSide) / Double(max(bounds.width, bounds.height))
        let width = max(1, Int((Double(bounds.width) * scale).rounded())), height = max(1, Int((Double(bounds.height) * scale).rounded()))
        guard width * height <= 40_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))          // the page is drawn in points: scale it up to the canvas
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}
