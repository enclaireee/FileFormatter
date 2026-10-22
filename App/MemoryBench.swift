#if BENCH
import AppKit
import CoreText
import Darwin
import FileFormatterCore
import Foundation
import ImageIO
import Synchronization

/// `--memory-bench <minutes> <csv>`: loops every heavy feature through the quick-run path and logs phys_footprint.
/// Built only by scripts/memory-bench.sh; shipped builds never contain it.
enum MemoryBench {
    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "--memory-bench"), args.count > flag + 2,
              let minutes = Double(args[flag + 1]) else { return }
        let csv = URL(fileURLWithPath: args[flag + 2])
        Task { @MainActor in await run(minutes: minutes, csv: csv) }
    }

    private static let peak = Mutex<UInt64>(0)

    private static func footprint() -> (now: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return (info.phys_footprint, UInt64(info.ledger_phys_footprint_peak))
    }

    /// A 20 Hz sampler off the main actor catches the peak inside each step.
    private nonisolated static func startSampler() -> DispatchSourceTimer {
        let sampler = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        sampler.schedule(deadline: .now(), repeating: .milliseconds(50))
        sampler.setEventHandler { let now = footprint().now; peak.withLock { $0 = max($0, now) } }
        sampler.resume()
        return sampler
    }

    @MainActor
    private static func run(minutes: Double, csv: URL) async {
        try? "step,pass,footprint_mb,step_peak_mb,lifetime_peak_mb,seconds\n".write(to: csv, atomically: true, encoding: .utf8)
        let start = Date()
        func log(_ step: String, _ pass: Int) {
            let (now, lifetime) = footprint()
            let stepPeak = peak.withLock { max($0, now) }
            let mb = { (bytes: UInt64) in String(format: "%.1f", Double(bytes) / 1_048_576) }
            let line = "\(step),\(pass),\(mb(now)),\(mb(stepPeak)),\(mb(lifetime)),\(Int(Date().timeIntervalSince(start)))\n"
            if let handle = try? FileHandle(forWritingTo: csv) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            }
            peak.withLock { $0 = 0 }
        }

        let sampler = startSampler()

        try? await Task.sleep(for: .seconds(5))
        log("launch", 0)
        // What the popover's SwiftUI tree costs once built, before any conversion muddies the heap.
        StatusItemController.shared.perform(NSSelectorFromString("toggle"))
        try? await Task.sleep(for: .seconds(1))
        StatusItemController.shared.perform(NSSelectorFromString("toggle"))
        try? await Task.sleep(for: .seconds(2))
        log("popover-first", 0)
        let photo: URL, pdf: URL, csvFile: URL, wav: URL
        do {
            photo = try makePhoto(width: 4_000, height: 3_000)
            pdf = try makePDF(pages: 20)
            csvFile = try DebugFixture.makeCSV()
            wav = try DebugFixture.makeWAV()
        } catch {
            print("BENCH FAIL fixtures: \(error)")
            exit(1)
        }

        let steps: [(String, URL, QuickAction)] = [
            ("image-jpeg", photo, .to(.jpeg)),
            ("image-compress", photo, .compressImage),
            ("bg-remove", photo, .removeBackground),
            ("image-pdf", photo, .makePDF),
            ("pdf-png", pdf, .to(.png)),
            ("pdf-split", pdf, .splitPDF),
            ("pdf-compress", pdf, .compressPDF),
            ("pdf-ocr", pdf, .ocr),
            ("data-json", csvFile, .to(.json)),
            ("audio-mp3", wav, .to(.mp3)),
        ]
        let model = AppModel.shared
        var pass = 0
        repeat {
            pass += 1
            for (name, url, action) in steps {
                guard let summary = await model.quickRun(urls: [url], action: action, showsProgress: false),
                      summary.failed == 0, summary.converted > 0 else {
                    print("BENCH FAIL \(name)")
                    exit(1)
                }
                _ = await model.undo(summary)
                try? await Task.sleep(for: .seconds(1))
                log(name, pass)
            }
            // Open and close the menu bar popover like a user would.
            StatusItemController.shared.perform(NSSelectorFromString("toggle"))
            try? await Task.sleep(for: .seconds(1))
            StatusItemController.shared.perform(NSSelectorFromString("toggle"))
            try? await Task.sleep(for: .seconds(1))
            log("popover", pass)
        } while Date().timeIntervalSince(start) < minutes * 60

        try? await Task.sleep(for: .seconds(30))
        log("idle-30s", pass)
        sampler.cancel()
        print("BENCH DONE passes=\(pass)")
        exit(0)
    }

    /// A gradient with one clear subject, so background removal finds something to cut out.
    private static func makeImage(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ConversionError.writeFailed("Could not create a bitmap.") }
        let colors = [CGColor(red: 0.85, green: 0.9, blue: 0.95, alpha: 1), CGColor(red: 0.6, green: 0.7, blue: 0.8, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        context.setFillColor(CGColor(red: 0.8, green: 0.25, blue: 0.2, alpha: 1))
        context.fillEllipse(in: CGRect(x: width / 3, y: height / 4, width: width / 3, height: height / 2))
        guard let image = context.makeImage() else { throw ConversionError.writeFailed("Could not create a bitmap.") }
        return image
    }

    private static func makePhoto(width: Int, height: Int) throws -> URL {
        let url = try benchDirectory().appendingPathComponent("photo.png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw ConversionError.writeFailed("Could not create the bench photo.")
        }
        CGImageDestinationAddImage(destination, try makeImage(width: width, height: height), nil)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.writeFailed("Could not write the bench photo.") }
        return url
    }

    private static func benchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileFormatterBench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Scan-like pages: a photo plus real text, so compress has images to shrink and OCR has text to read.
    private static func makePDF(pages: Int) throws -> URL {
        let url = try benchDirectory().appendingPathComponent("bench.pdf")
        let photo = try makeImage(width: 1_600, height: 1_200)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw ConversionError.writeFailed("Could not create the bench PDF.")
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        for page in 1...pages {
            context.beginPDFPage(nil)
            context.draw(photo, in: CGRect(x: 48, y: 48, width: 516, height: 387))
            for row in 0..<16 {
                let text = NSAttributedString(
                    string: "Page \(page) line \(row): The quick brown fox jumps over the lazy dog.",
                    attributes: [.font: font]
                )
                context.textPosition = CGPoint(x: 48, y: 740 - CGFloat(row) * 17)
                CTLineDraw(CTLineCreateWithAttributedString(text), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
}
#endif
