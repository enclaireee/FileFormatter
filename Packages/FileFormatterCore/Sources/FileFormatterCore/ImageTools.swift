import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

public enum ImageTools {
    public static func load(_ url: URL, maxPixelSize: Int?) throws -> (image: CGImage, properties: [CFString: Any]) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw ConversionError.cannotReadSource(url.lastPathComponent)
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let original = max(width, height)
        let limit = original > 0 ? min(maxPixelSize ?? original, original) : (maxPixelSize ?? 16_384)

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(limit, 1)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ConversionError.cannotReadSource(url.lastPathComponent)
        }
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImagePropertyPixelWidth] = image.width
        properties[kCGImagePropertyPixelHeight] = image.height
        return (image, properties)
    }

    public static func removeBackground(_ image: CGImage, cropToSubject: Bool = false) throws -> CGImage {
        let noSubject = ConversionError.core("No clear subject was found to cut out.")
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw noSubject
        }
        let buffer = try observation.generateMaskedImage(
            ofInstances: observation.allInstances,
            from: handler,
            croppedToInstancesExtent: cropToSubject
        )
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let result = CIContext().createCGImage(ciImage, from: ciImage.extent) else {
            throw ConversionError.writeFailed("Could not render the cut-out image.")
        }
        return result
    }

    public static func encode(
        image: CGImage,
        destination: URL,
        target: ConversionTarget,
        quality: Double,
        properties: [CFString: Any] = [:],
        targetBytes: UInt64?
    ) throws {
        guard let targetBytes else {
            try ImageConverter.encode(image: image, destination: destination, target: target, quality: quality, properties: properties)
            return
        }

        let directory = destination.deletingLastPathComponent()
        let manager = FileManager.default
        func makeTemp() -> URL {
            directory.appendingPathComponent(".fileformatter-\(UUID().uuidString)").appendingPathExtension(target.fileExtension)
        }

        var best: (url: URL, size: UInt64)?
        defer { if let best { try? manager.removeItem(at: best.url) } }

        // Returns true when the attempt fits; otherwise keeps it only if it is the smallest so far.
        func attempt(_ image: CGImage, _ quality: Double) throws -> Bool {
            let temp = makeTemp()
            try ImageConverter.encode(image: image, destination: temp, target: target, quality: quality, properties: properties)
            let size = (try manager.attributesOfItem(atPath: temp.path)[.size] as? UInt64) ?? .max
            if let old = best, old.size <= size, size > targetBytes {
                try? manager.removeItem(at: temp)
                return false
            }
            if let old = best { try? manager.removeItem(at: old.url) }
            best = (temp, size)
            return size <= targetBytes
        }

        // ponytail: linear search, ~8–14 encodes worst case; switch to bisection if large batches feel slow.
        var current = image
        var fits = false
        if target.supportsQuality {
            for q in [0.9, 0.8, 0.7, 0.6, 0.5, 0.4] where !fits {
                fits = try attempt(current, q)
            }
        } else {
            fits = try attempt(current, quality)
        }
        var steps = 0
        while !fits, steps < 6, let smaller = downscale(current, by: 0.85) {
            current = smaller
            steps += 1
            fits = try attempt(current, target.supportsQuality ? 0.6 : quality)
        }

        guard let winner = best else { throw ConversionError.writeFailed("The image encoder did not finish.") }
        try ImageConverter.install(temporary: winner.url, at: destination)
        best = nil
    }

    private static func downscale(_ image: CGImage, by factor: Double) -> CGImage? {
        let width = Int(Double(image.width) * factor)
        let height = Int(Double(image.height) * factor)
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
