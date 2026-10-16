import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Writes a white PNG, optionally with black text and an EXIF orientation tag.
func makeImage(width: Int, height: Int, text: String?, orientation: Int? = nil, at url: URL) throws {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    if let text {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, CGFloat(height) / 5, nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        ctx.textPosition = CGPoint(x: CGFloat(width) / 20, y: CGFloat(height) / 2.5)
        CTLineDraw(line, ctx)
    }
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    var properties: [CFString: Any] = [:]
    if let orientation { properties[kCGImagePropertyOrientation] = orientation }
    CGImageDestinationAddImage(destination, ctx.makeImage()!, properties as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
}
