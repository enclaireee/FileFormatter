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

            let service = ConversionService()
            let plan = try await service.makePlan(
                urls: [fixture],
                target: .jpeg,
                suffix: "-selftest"
            )
            guard let item = plan.items.first else {
                log("FAIL no plan item")
                exit(1)
            }
            log("plan=\(item.outputName) fidelity=\(item.fidelity.rawValue)")

            let result = try await service.convert(
                item,
                options: ConversionOptions(
                    target: .jpeg,
                    quality: 0.85,
                    suffix: "-selftest",
                    preserveMetadata: true
                )
            )
            guard FileManager.default.fileExists(atPath: result.url.path),
                  result.outputBytes > 0 else {
                log("FAIL output missing")
                exit(1)
            }
            log("convert=PASS \(result.url.path) bytes=\(result.outputBytes)")

            let journal = RunJournal()
            let summary = RunSummary(
                target: "JPEG",
                outputs: [result.url],
                converted: 1,
                skipped: 0,
                failed: 0,
                inputBytes: item.byteSize,
                outputBytes: result.outputBytes
            )
            try await journal.save(summary)
            guard await journal.latest()?.id == summary.id else {
                log("FAIL journal did not persist")
                exit(1)
            }
            log("journal=PASS")

            let undo = await service.undo(summary)
            try await journal.markUndone(id: summary.id)
            guard undo.removed == 1, !FileManager.default.fileExists(atPath: result.url.path) else {
                log("FAIL undo removed=\(undo.removed) failed=\(undo.failed)")
                exit(1)
            }
            log("undo=PASS")
            log("SELF-TEST PASS")
            exit(0)
        } catch {
            log("FAIL \(error.localizedDescription)")
            exit(1)
        }
    }
}

enum DebugFixture {
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
