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

    /// Applies crop, rotation and flip in that order, all in Core Image so pixels are only encoded once.
    public static func apply(_ edit: ImageEdit, to image: CGImage) throws -> CGImage {
        guard !edit.isIdentity else { return image }
        var work = CIImage(cgImage: image)

        if let spec = edit.crop, let aspect = spec.aspect, aspect > 0 {
            work = cropped(work, aspect: aspect, anchorX: spec.anchorX, anchorY: spec.anchorY)
        }

        switch ((edit.rotation % 360) + 360) % 360 {
        case 90: work = work.oriented(.right)
        case 180: work = work.oriented(.down)
        case 270: work = work.oriented(.left)
        default: break
        }

        switch edit.flip {
        case .horizontal: work = flipped(work, horizontal: true)
        case .vertical: work = flipped(work, horizontal: false)
        case .none: break
        }

        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let result = ImageConverter.ciContext.createCGImage(
            work, from: work.extent, format: .RGBA8, colorSpace: space
        ) else {
            throw ConversionError.writeFailed("Could not apply the image edit.")
        }
        return result
    }

    /// Keeps the largest rectangle of `aspect` that fits, positioned by the anchor (0 = top/leading).
    private static func cropped(_ image: CIImage, aspect: Double, anchorX: Double, anchorY: Double) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        var width = extent.width
        var height = extent.height
        if width / height > aspect {
            width = height * aspect
        } else {
            height = width / aspect
        }
        // Snap to whole pixels, but never below 1 or past the source.
        width = min(max(1, width.rounded(.down)), extent.width)
        height = min(max(1, height.rounded(.down)), extent.height)
        let x = extent.minX + (extent.width - width) * min(max(anchorX, 0), 1)
        // Core Image's origin is bottom-left; anchorY 0 means the top edge.
        let y = extent.minY + (extent.height - height) * (1 - min(max(anchorY, 0), 1))
        let rect = CGRect(x: x.rounded(.down), y: y.rounded(.down), width: width, height: height)
        return image.cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    private static func flipped(_ image: CIImage, horizontal: Bool) -> CIImage {
        let extent = image.extent
        let moved = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let mirrored = moved.transformed(by: horizontal
            ? CGAffineTransform(scaleX: -1, y: 1)
            : CGAffineTransform(scaleX: 1, y: -1))
        return mirrored.transformed(by: CGAffineTransform(
            translationX: horizontal ? extent.width : 0,
            y: horizontal ? 0 : extent.height
        ))
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
        guard let result = ImageConverter.ciContext.createCGImage(ciImage, from: ciImage.extent) else {
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
        return ImageConverter.ciContext.createCGImage(cutout, from: source.extent, format: .RGBA8, colorSpace: space)
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

        // Attempts stay in memory; only the winner is written.
        var fitting: Data?
        var smallest: Data?
        var lastSize = 0
        func attempt(_ image: CGImage, _ quality: Double) throws -> Bool {
            let data = try ImageConverter.data(image: image, target: target, quality: quality, properties: properties)
            lastSize = data.count
            if data.count <= targetBytes {
                fitting = data
                return true
            }
            if data.count < smallest?.count ?? .max { smallest = data }
            return false
        }

        var current = image
        var fits: Bool
        if target.supportsQuality {
            fits = try attempt(current, 0.9)
            if !fits, try attempt(current, 0.4) {
                // 0.4 fits and 0.9 does not: bisect for the highest quality that still fits.
                var low = 0.4, high = 0.9
                for _ in 0..<3 {
                    let mid = (low + high) / 2
                    let previous = fitting
                    if try attempt(current, mid) { low = mid } else { high = mid; fitting = previous }
                }
                fits = true
            }
        } else {
            fits = try attempt(current, quality)
        }
        var steps = 0
        while !fits, steps < 4 {
            // Bytes scale roughly with area, so shrink each side by the square root of the overshoot.
            let factor = min(0.9, max(0.3, (Double(targetBytes) / Double(max(lastSize, 1))).squareRoot() * 0.95))
            guard let smaller = downscale(current, by: factor) else { break }
            current = smaller
            steps += 1
            fits = try attempt(current, target.supportsQuality ? 0.6 : quality)
        }

        guard let winner = fitting ?? smallest else { throw ConversionError.writeFailed("The image encoder did not finish.") }
        try ImageConverter.write(winner, to: destination)
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
