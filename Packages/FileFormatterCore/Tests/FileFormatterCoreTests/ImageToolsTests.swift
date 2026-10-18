import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FileFormatterCore

@Suite("Image tools")
struct ImageToolsTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageToolsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeImage(width: Int, height: Int, noisy: Bool) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        if noisy {
            var generator = SystemRandomNumberGenerator()
            for i in 0..<pixels.count where i % 4 != 3 { pixels[i] = UInt8.random(in: 0...255, using: &generator) }
        } else {
            for i in stride(from: 0, to: pixels.count, by: 4) { pixels[i] = 40; pixels[i + 1] = 100; pixels[i + 2] = 220 }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func loadDownscalesAndNeverUpscales() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("a.png")
        try writePNG(makeImage(width: 1200, height: 800, noisy: false), to: url)

        let small = try ImageTools.load(url, maxPixelSize: 256)
        #expect(max(small.image.width, small.image.height) == 256)
        #expect(abs(Double(small.image.width) / Double(small.image.height) - 1.5) < 0.02)
        #expect(small.properties[kCGImagePropertyPixelWidth] as? Int == small.image.width)

        let big = try ImageTools.load(url, maxPixelSize: 5000)
        #expect(big.image.width == 1200 && big.image.height == 800)
        let same = try ImageTools.load(url, maxPixelSize: nil)
        #expect(same.image.width == 1200)
    }

    @Test func encodeFitsTargetBytes() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("out.jpg")
        try ImageTools.encode(
            image: makeImage(width: 2000, height: 2000, noisy: true),
            destination: output, target: .jpeg, quality: 0.9, targetBytes: 300_000
        )
        let size = try #require(FileManager.default.attributesOfItem(atPath: output.path)[.size] as? UInt64)
        #expect(size <= 300_000)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers == ["out.jpg"])
    }

    @Test func removeBackgroundKeepsAlpha() throws {
        let path = "/Library/User Pictures/Animals/Eagle.heic"
        guard FileManager.default.fileExists(atPath: path) else {
            Issue.record("Skipped: \(path) is not present on this Mac.")
            return
        }
        let loaded = try ImageTools.load(URL(fileURLWithPath: path), maxPixelSize: 1024)
        let result = try ImageTools.removeBackground(loaded.image)
        #expect(result.width == loaded.image.width && result.height == loaded.image.height)
        #expect(![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(result.alphaInfo))

        var pixel = [UInt8](repeating: 255, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.draw(result, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(pixel[3] < 255)
    }
}
