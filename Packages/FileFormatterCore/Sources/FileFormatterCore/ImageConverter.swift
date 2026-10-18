import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageConverter {
    static func convert(
        source: URL,
        destination: URL,
        target: ConversionTarget,
        quality: Double,
        preserveMetadata: Bool
    ) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw ConversionError.cannotReadSource(source.lastPathComponent)
        }
        guard CGImageSourceGetCount(imageSource) > 0,
              let original = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw ConversionError.cannotReadSource(source.lastPathComponent)
        }

        let sourceProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = (sourceProperties[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let image = applyOrientation(original, orientation: orientation) ?? original

        var properties: [CFString: Any] = preserveMetadata ? sourceProperties : [:]
        properties[kCGImagePropertyOrientation] = 1
        if target.supportsQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0.1), 1.0)
        }

        let directory = destination.deletingLastPathComponent()
        let temporary = directory
            .appendingPathComponent(".fileformatter-\(UUID().uuidString)")
            .appendingPathExtension(target.fileExtension)
        defer { try? FileManager.default.removeItem(at: temporary) }

        guard let imageDestination = CGImageDestinationCreateWithURL(
            temporary as CFURL,
            target.utType.identifier as CFString,
            1,
            nil
        ) else {
            throw ConversionError.cannotCreateDestination(destination.lastPathComponent)
        }

        CGImageDestinationAddImage(imageDestination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(imageDestination) else {
            throw ConversionError.writeFailed("The image encoder did not finish.")
        }

        try install(temporary: temporary, at: destination)
    }

    private static func applyOrientation(_ image: CGImage, orientation: UInt32) -> CGImage? {
        guard orientation != 1, orientation <= 8 else { return nil }
        let input = CIImage(cgImage: image).oriented(forExifOrientation: Int32(orientation))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(input, from: input.extent)
    }

    private static func install(temporary: URL, at destination: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: destination)
        }
    }
}
