#if DEBUG
import CoreGraphics
import Darwin
import FileFormatterCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum AppSelfTest {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--self-test") else { return }
        Task { @MainActor in
            await run()
        }
    }

    @MainActor
    private static func run() async {
        let logURL = URL(fileURLWithPath: "/tmp/fileformatter-selftest.txt")
        try? "Starting FileFormatter self-test\n".write(to: logURL, atomically: true, encoding: .utf8)

        func log(_ message: String) {
            print(message)
            if let data = (message + "\n").data(using: .utf8),
               let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        }

        do {
            let fixture = try DebugFixture.makePNG()
            log("fixture=\(fixture.path)")

            let csv = try DebugFixture.makeCSV()
            let wav = try DebugFixture.makeWAV()
            let service = ConversionService()
            let plan = try await service.makePlan(
                urls: [fixture, csv],
                targets: TargetRecipe(image: .webp, data: .json),
                suffix: "-selftest"
            )
            guard plan.items.count == 2,
                  let imageItem = plan.items.first(where: { $0.kind == .image }),
                  let dataItem = plan.items.first(where: { $0.kind == .data }) else {
                log("FAIL unexpected plan size=\(plan.items.count)")
                exit(1)
            }
            log("plan image=\(imageItem.outputName)/\(imageItem.fidelity.rawValue) data=\(dataItem.outputName)/\(dataItem.fidelity.rawValue)")

            let imageResult = try await service.convert(
                imageItem,
                options: ConversionOptions(
                    target: .webp,
                    quality: 0.85,
                    suffix: "-selftest",
                    preserveMetadata: true
                )
            )
            let dataResult = try await service.convert(
                dataItem,
                options: ConversionOptions(
                    target: .json,
                    quality: 1,
                    suffix: "-selftest",
                    preserveMetadata: true
                )
            )
            guard FileManager.default.fileExists(atPath: imageResult.url.path),
                  imageResult.outputBytes > 0,
                  FileManager.default.fileExists(atPath: dataResult.url.path),
                  dataResult.outputBytes > 0 else {
                log("FAIL output missing")
                exit(1)
            }
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: dataResult.url)) as? [[String: Any]]
            guard json?.first?["name"] as? String == "Ada" else {
                log("FAIL JSON content")
                exit(1)
            }
            log("convert=PASS image=\(imageResult.url.lastPathComponent) data=\(dataResult.url.lastPathComponent)")

            let audioPlan = try await service.makePlan(
                urls: [wav],
                targets: TargetRecipe(audio: .m4a),
                suffix: "-audio"
            )
            guard let audioItem = audioPlan.items.first, audioItem.kind == .audio else {
                log("FAIL audio plan")
                exit(1)
            }
            let audioResult = try await service.convert(
                audioItem,
                options: ConversionOptions(
                    target: .m4a,
                    quality: 0.8,
                    suffix: "-audio",
                    preserveMetadata: true
                )
            )
            let mediaInfo = try await MediaProbe().probe(audioResult.url)
            guard (mediaInfo.duration ?? 0) > 0.1 else {
                log("FAIL audio probe")
                exit(1)
            }
            log("audio=PASS \(audioResult.url.lastPathComponent) duration=\(mediaInfo.duration ?? 0)")

            let journal = RunJournal()
            let summary = RunSummary(
                target: "Mixed",
                outputs: [imageResult.url, dataResult.url, audioResult.url],
                converted: 3,
                skipped: 0,
                failed: 0,
                inputBytes: imageItem.byteSize + dataItem.byteSize + audioItem.byteSize,
                outputBytes: imageResult.outputBytes + dataResult.outputBytes + audioResult.outputBytes
            )
            try await journal.save(summary)
            guard await journal.latest()?.id == summary.id else {
                log("FAIL journal did not persist")
                exit(1)
            }
            log("journal=PASS")

            let undo = await service.undo(summary)
            try await journal.markUndone(id: summary.id)
            guard undo.removed == 3,
                  !FileManager.default.fileExists(atPath: imageResult.url.path),
                  !FileManager.default.fileExists(atPath: dataResult.url.path),
                  !FileManager.default.fileExists(atPath: audioResult.url.path) else {
                log("FAIL undo removed=\(undo.removed) failed=\(undo.failed)")
                exit(1)
            }
            log("undo=PASS")

            // Quick actions run without the window queue: one per family.
            let model = AppModel.shared
            for (url, action) in [(fixture, QuickAction.compressImage), (csv, .to(.yaml)), (wav, .to(.mp3))] {
                guard let quick = await model.quickRun(urls: [url], action: action, showsProgress: false),
                      quick.converted == 1, quick.failed == 0,
                      let output = quick.outputs.first,
                      FileManager.default.fileExists(atPath: output.path) else {
                    log("FAIL quickRun \(action.id)")
                    exit(1)
                }
                _ = await model.undo(quick)
                guard !FileManager.default.fileExists(atPath: output.path) else {
                    log("FAIL quick undo \(action.id)")
                    exit(1)
                }
                if action == .compressImage,
                   !output.deletingPathExtension().lastPathComponent.hasSuffix(AppSettings.suffix(AppSettings.compressSuffix)) {
                    log("FAIL compress suffix \(output.lastPathComponent)")
                    exit(1)
                }
                log("quick=PASS \(action.id) -> \(output.lastPathComponent)")
            }
            let strong = CompressSettings(strength: .strong)
            guard let estimate = await strong.estimate(for: .compressImage, urls: [fixture]),
                  estimate.output > 0, estimate.output <= estimate.input else {
                log("FAIL compress estimate")
                exit(1)
            }
            let capped = CompressSettings(strength: .target, targetMB: 0.1)
            guard let ceiling = await capped.estimate(for: .compressImage, urls: [fixture]),
                  ceiling.atMost, ceiling.output <= max(capped.targetBytes, 1) || ceiling.output == ceiling.input else {
                log("FAIL compress target estimate")
                exit(1)
            }
            log("estimate=PASS \(estimate.input) -> \(estimate.output)")
            log("SELF-TEST PASS")
            exit(0)
        } catch {
            log("FAIL \(error.localizedDescription)")
            exit(1)
        }
    }
}

enum DebugFixture {
    static func makeCSV() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileFormatterSelfTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("people.csv")
        try "name,role\nAda,engineer\nGrace,admiral\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func makeWAV() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileFormatterSelfTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("tone.wav")

        let sampleRate: UInt32 = 8_000
        let sampleCount = 4_000
        var samples = Data()
        for index in 0..<sampleCount {
            let value = sin(2.0 * Double.pi * 440 * Double(index) / Double(sampleRate))
            var sample = Int16(value * 8_000).littleEndian
            withUnsafeBytes(of: &sample) { samples.append(contentsOf: $0) }
        }

        func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        var wav = Data()
        wav.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + samples.count), to: &wav)
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16), to: &wav)
        append(UInt16(1), to: &wav)
        append(UInt16(1), to: &wav)
        append(sampleRate, to: &wav)
        append(sampleRate * 2, to: &wav)
        append(UInt16(2), to: &wav)
        append(UInt16(16), to: &wav)
        wav.append(contentsOf: Array("data".utf8))
        append(UInt32(samples.count), to: &wav)
        wav.append(samples)
        try wav.write(to: url, options: .atomic)
        return url
    }

    static func makePNG() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileFormatterSelfTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("self-test.png")

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 64,
            height: 48,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ConversionError.writeFailed("Could not create a bitmap.")
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 12, y: 12, width: 40, height: 6))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
              ) else {
            throw ConversionError.writeFailed("Could not create the test image destination.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.writeFailed("Could not write the test image.")
        }
        return url
    }
}
#endif
