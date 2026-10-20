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

    /// Alpha at a corner pixel (0 = fully cut out).
    private func cornerAlpha(_ image: CGImage) throws -> UInt8 {
        var pixel = [UInt8](repeating: 255, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
        let corner = try #require(image.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)))
        context.draw(corner, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel[3]
    }

    @Test func removeBackgroundHDKeepsAlpha() throws {
        let photo = "/Library/User Pictures/Animals/Eagle.heic"
        // Fetched by `make bootstrap-model`; not in git.
        let model = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("../../vendor/birefnet/BiRefNetLite.mlmodelc").standardized
        guard FileManager.default.fileExists(atPath: photo), FileManager.default.fileExists(atPath: model.path) else {
            Issue.record("Skipped: needs \(photo) and `make bootstrap-model`.")
            return
        }
        let loaded = try ImageTools.load(URL(fileURLWithPath: photo), maxPixelSize: nil)
        let result = try ImageTools.removeBackground(loaded.image, hdModel: model)
        #expect(result.width == loaded.image.width && result.height == loaded.image.height)
        #expect(try cornerAlpha(result) == 0)
        // A silent fallback would produce Vision's exact pixels.
        let vision = try ImageTools.removeBackground(loaded.image)
        #expect(result.dataProvider?.data as Data? != vision.dataProvider?.data as Data?)
    }

    @Test func rotateSwapsDimensions() throws {
        let image = try makeImage(width: 120, height: 80, noisy: false)
        let right = try ImageTools.apply(ImageEdit(rotation: 90), to: image)
        #expect(right.width == 80 && right.height == 120)
        let half = try ImageTools.apply(ImageEdit(rotation: 180), to: image)
        #expect(half.width == 120 && half.height == 80)
        let left = try ImageTools.apply(ImageEdit(rotation: 270), to: image)
        #expect(left.width == 80 && left.height == 120)
        #expect(try ImageTools.apply(ImageEdit(), to: image).width == 120)
    }

    @Test func cropKeepsRequestedAspectAndAnchor() throws {
        let image = try makeImage(width: 120, height: 80, noisy: false)
        let squareCenter = try ImageTools.apply(
            ImageEdit(crop: ImageCrop(aspect: 1)),
            to: image
        )
        #expect(squareCenter.width == 80 && squareCenter.height == 80)

        let squareLeft = try ImageTools.apply(
            ImageEdit(crop: ImageCrop(aspect: 1, anchorX: 0, anchorY: 0.5)),
            to: image
        )
        #expect(squareLeft.width == 80 && squareLeft.height == 80)
    }

    @Test func flipMirrorsPixels() throws {
        // Two pixels: red then blue.
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 0, 255, 255]
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let strip = try #require(CGImage(
            width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))

        let flipped = try ImageTools.apply(ImageEdit(flip: .horizontal), to: strip)
        #expect(flipped.width == 2 && flipped.height == 1)
        let left = try pixelColor(flipped, x: 0, y: 0)
        #expect(left.blue > 200 && left.red < 50)
        let right = try pixelColor(flipped, x: 1, y: 0)
        #expect(right.red > 200 && right.blue < 50)
    }

    private func pixelColor(_ image: CGImage, x: Int, y: Int) throws -> (red: Int, green: Int, blue: Int) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let corner = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        context.draw(corner, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    @Test func removeBackgroundFallsBackToVisionWhenModelFails() throws {
        let photo = "/Library/User Pictures/Animals/Eagle.heic"
        guard FileManager.default.fileExists(atPath: photo) else {
            Issue.record("Skipped: \(photo) is not present on this Mac.")
            return
        }
        let loaded = try ImageTools.load(URL(fileURLWithPath: photo), maxPixelSize: nil)
        let missing = URL(fileURLWithPath: "/nonexistent/Model.mlmodelc")
        let result = try ImageTools.removeBackground(loaded.image, hdModel: missing)
        #expect(result.width == loaded.image.width && result.height == loaded.image.height)
        #expect(try cornerAlpha(result) < 255)
    }
}
