import CWebP
import CoreGraphics
import Darwin
import Foundation

enum WebPEncoder {
    static func convert(image: CGImage, destination: URL, quality: Double) throws {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              width <= Int(Int32.max), height <= Int(Int32.max) else {
            throw ConversionError.writeFailed("The image dimensions are not valid for WebP.")
        }

        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        defer { buffer.deallocate() }
        memset(buffer, 0, byteCount)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: buffer,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw ConversionError.writeFailed("Could not create a WebP bitmap context.")
        }

        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let pixels = buffer.assumingMemoryBound(to: UInt8.self)
        unpremultiply(pixels, width: width, height: height, bytesPerRow: bytesPerRow)

        var output: UnsafeMutablePointer<UInt8>?
        var outputSize = 0
        let result = ff_webp_encode_rgba(
            pixels,
            Int32(width),
            Int32(height),
            Int32(bytesPerRow),
            Float(min(max(quality, 0.1), 1.0) * 100),
            &output,
            &outputSize
        )
        guard result == 1, let output, outputSize > 0 else {
            throw ConversionError.writeFailed("The WebP encoder could not produce a file.")
        }
        defer { ff_webp_free(output) }

        let directory = destination.deletingLastPathComponent()
        let temporary = directory
            .appendingPathComponent(".fileformatter-\(UUID().uuidString)")
            .appendingPathExtension("webp")
        defer { try? FileManager.default.removeItem(at: temporary) }

        try Data(bytes: output, count: outputSize).write(to: temporary, options: .atomic)
        try ImageConverter.install(temporary: temporary, at: destination)
    }

    private static func unpremultiply(
        _ pixels: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) {
        for y in 0..<height {
            let row = pixels.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let p = row.advanced(by: x * 4)
                let alpha = Int(p[3])
                guard alpha > 0, alpha < 255 else { continue }
                p[0] = UInt8(min(255, Int(p[0]) * 255 / alpha))
                p[1] = UInt8(min(255, Int(p[1]) * 255 / alpha))
                p[2] = UInt8(min(255, Int(p[2]) * 255 / alpha))
            }
        }
    }
}
