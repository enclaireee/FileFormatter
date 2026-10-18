import Foundation
import Testing
@testable import FileFormatterCore

@Suite("ConversionTarget")
struct ConversionTargetTests {
    @Test func jpegSupportsQuality() {
        #expect(ConversionTarget.jpeg.supportsQuality)
    }

    @Test func pngDoesNotSupportQuality() {
        #expect(!ConversionTarget.png.supportsQuality)
    }

    @Test func avifHasAType() {
        #expect(!ConversionTarget.avif.utType.identifier.isEmpty)
    }
}

@Suite("RunSummary")
struct RunSummaryTests {
    @Test func savedBytes() {
        let summary = RunSummary(
            target: "jpeg",
            outputs: [],
            converted: 2,
            skipped: 0,
            failed: 0,
            inputBytes: 1_000,
            outputBytes: 400
        )
        #expect(summary.bytesSaved == 600)
    }
}
