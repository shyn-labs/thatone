import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

public enum ImagePrepError: Error, Equatable {
    case unreadable(String)
    case tooLarge(String)
}

public struct DecodedImage {
    public let ocrImage: CGImage      // upright, long side <= 3000 px, for text recognition
    public let smallImage: CGImage    // upright, long side <= 1024 px, what the embedding model sees
}

public struct PreparedImage {
    public let ocrImage: CGImage
    public let embedJPEG: URL
}

public enum ImagePrep {
    public static let ocrMaxSide = 3000
    public static let embedMaxSide = 1024
    /// Images that would need an unreasonable amount of memory to decode (decompression bombs) are refused up front.
    public static var maxPixels = 150_000_000
    public static var maxFileBytes: Int64 = 300_000_000

    static func thumbnail(_ source: CGImageSource, maxSide: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // applies EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Decodes any ImageIO format (HEIC, PNG, TIFF, ...) in memory. Nothing is written to disk here, so OCR and the
    /// secret gate can run before any copy of the image exists outside the original file.
    public static func decode(_ url: URL) throws -> DecodedImage {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= maxFileBytes else { throw ImagePrepError.tooLarge(url.path) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ImagePrepError.unreadable(url.path) }
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int,
           width * height > maxPixels {
            throw ImagePrepError.tooLarge(url.path)
        }
        guard let ocr = thumbnail(source, maxSide: ocrMaxSide), let small = thumbnail(source, maxSide: embedMaxSide)
        else { throw ImagePrepError.unreadable(url.path) }
        return DecodedImage(ocrImage: ocr, smallImage: small)
    }

    /// The same preparation for an image that is already in memory (a Photos asset): upright is assumed.
    public static func decode(cgImage: CGImage) throws -> DecodedImage {
        guard cgImage.width * cgImage.height <= maxPixels else { throw ImagePrepError.tooLarge("photos") }
        guard let ocr = scaled(cgImage, maxSide: ocrMaxSide), let small = scaled(cgImage, maxSide: embedMaxSide)
        else { throw ImagePrepError.unreadable("photos") }
        return DecodedImage(ocrImage: ocr, smallImage: small)
    }

    static func scaled(_ image: CGImage, maxSide: Int) -> CGImage? {
        let longSide = max(image.width, image.height)
        guard longSide > maxSide else { return image }
        let factor = Double(maxSide) / Double(longSide)
        let width = max(1, Int((Double(image.width) * factor).rounded())), height = max(1, Int((Double(image.height) * factor).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// The JPEG the embedder would see, in memory (its hash identifies the picture's content).
    public static func jpegData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Writes the small image as a JPEG the sidecar's Python image library can open, whatever the original format.
    public static func writeJPEG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ImagePrepError.unreadable(url.path) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImagePrepError.unreadable(url.path) }
    }

    /// Decode and write in one step (used where no gate sits between the two).
    public static func prepare(_ url: URL, workDir: URL, name: String) throws -> PreparedImage {
        let decoded = try decode(url)
        let out = workDir.appendingPathComponent("\(name).jpg")
        try writeJPEG(decoded.smallImage, to: out)
        return PreparedImage(ocrImage: decoded.ocrImage, embedJPEG: out)
    }
}

public enum OCR {
    /// One for the whole process, so the cap on stuck Vision calls holds across every indexer and reader.
    /// Replaceable only by tests (to prove the default paths use it).
    static var shared = BoundedOCR()

    /// Recognised text in reading order, joined by spaces. Empty string when nothing is found. Bounded in time:
    /// throws `ReadFailure.timedOut` when Vision takes longer than `BoundedOCR.defaultDeadline`, and `OCRUnavailable`
    /// when too many earlier calls are still stuck (see `BoundedOCR`).
    public static func text(in image: CGImage) throws -> String {
        try shared.text(in: image)
    }

    /// The Vision call itself, unbounded; `cancellation` cancels the request.
    public static func vision(_ image: CGImage, _ cancellation: OCRCancellation) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        cancellation.onCancel { request.cancel() }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
