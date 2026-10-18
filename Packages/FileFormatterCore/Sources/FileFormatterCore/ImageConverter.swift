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
        let properties: [CFString: Any] = preserveMetadata ? sourceProperties : [:]

        try encode(
            image: image,
            destination: destination,
            target: target,
            quality: quality,
            properties: properties
        )
    }

    /// One shared context: creating a CIContext per image costs more than the work it does.
    static let ciContext = CIContext()

    static func encode(
        image: CGImage,
        destination: URL,
        target: ConversionTarget,
        quality: Double,
        properties: [CFString: Any] = [:]
    ) throws {
        try write(data(image: image, target: target, quality: quality, properties: properties), to: destination)
    }

    /// Encodes in memory, so size searches never touch the disk.
    static func data(
        image: CGImage,
        target: ConversionTarget,
        quality: Double,
        properties sourceProperties: [CFString: Any] = [:]
    ) throws -> Data {
        if target == .webp { return try WebPEncoder.data(image: image, quality: quality) }
        if target == .pdf { return try PDFConverter.data(image: image) }

        var properties = sourceProperties
        properties[kCGImagePropertyOrientation] = 1
        if target.supportsQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0.1), 1.0)
        }

        let output = NSMutableData()
        guard let imageDestination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            target.utType.identifier as CFString,
            1,
            nil
        ) else {
            throw ConversionError.cannotCreateDestination(target.displayName)
        }

        CGImageDestinationAddImage(imageDestination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(imageDestination) else {
            throw ConversionError.writeFailed("The image encoder did not finish.")
        }
        return output as Data
    }

    static func write(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".fileformatter-\(UUID().uuidString)")
            .appendingPathExtension(destination.pathExtension)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        try install(temporary: temporary, at: destination)
    }

    static func install(temporary: URL, at destination: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: destination)
        }
    }

    private static func applyOrientation(_ image: CGImage, orientation: UInt32) -> CGImage? {
        guard orientation != 1, orientation <= 8 else { return nil }
        let input = CIImage(cgImage: image).oriented(forExifOrientation: Int32(orientation))
        return ciContext.createCGImage(input, from: input.extent)
    }
}
