import CoreGraphics
import CoreImage
import CoreML
import Foundation
import ImageIO
import Synchronization
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

    /// Cuts out the subject. With `hdModel` (a compiled BiRefNet-lite), uses it for sharper edges and
    /// falls back to Vision if the model fails or finds nothing.
    public static func removeBackground(_ image: CGImage, cropToSubject: Bool = false, hdModel: URL? = nil) throws -> CGImage {
        if let hdModel, !cropToSubject, let result = try? matte(image, model: hdModel) {
            return result
        }
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

    // ponytail: one cached model; conversions run one at a time. Keyed by URL so tests can swap models.
    private static let cachedModel = Mutex<(url: URL, model: MLModel)?>(nil)

    private static func loadModel(_ url: URL) throws -> MLModel {
        try cachedModel.withLock { cached in
            if let cached, cached.url == url { return cached.model }
            let config = MLModelConfiguration()
            // ponytail: cpuAndGPU only; on this model the Neural Engine takes ~110 s to load and .all fails to build.
            config.computeUnits = .cpuAndGPU
            let model = try MLModel(contentsOf: url, configuration: config)
            cached = (url, model)
            return model
        }
    }

    /// BiRefNet-lite: 1024² ImageNet-normalized NCHW in, mask logits out. Returns nil for an empty mask.
    private static func matte(_ image: CGImage, model url: URL) throws -> CGImage? {
        let side = 1024, plane = side * side
        var rgba = [UInt8](repeating: 0, count: plane * 4)
        guard let context = CGContext(
            data: &rgba, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
        let pixels = input.dataPointer.assumingMemoryBound(to: Float.self)
        let mean: [Float] = [0.485, 0.456, 0.406], std: [Float] = [0.229, 0.224, 0.225]
        for i in 0..<plane {
            for c in 0..<3 { pixels[c * plane + i] = (Float(rgba[i * 4 + c]) / 255 - mean[c]) / std[c] }
        }

        let output = try loadModel(url).prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input]))
        guard let logits = output.featureValue(for: "mask_logits")?.multiArrayValue,
              logits.count == plane, logits.dataType == .float32 else { return nil }
        let raw = logits.dataPointer.assumingMemoryBound(to: Float.self)
        var alpha = [UInt8](repeating: 0, count: plane)
        var solid = 0
        for i in 0..<plane {
            alpha[i] = UInt8(max(0, min(255, 255 / (1 + exp(-raw[i])))))
            if alpha[i] > 127 { solid += 1 }
        }
        guard solid * 1000 >= plane else { return nil }

        let small = CIImage(bitmapData: Data(alpha), bytesPerRow: side, size: CGSize(width: side, height: side),
                            format: .L8, colorSpace: nil)
        let source = CIImage(cgImage: image)
        let mask = small.transformed(by: CGAffineTransform(
            scaleX: CGFloat(image.width) / CGFloat(side), y: CGFloat(image.height) / CGFloat(side)
        ))
        let cutout = source.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask
        ])
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CIContext().createCGImage(cutout, from: source.extent, format: .RGBA8, colorSpace: space)
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
