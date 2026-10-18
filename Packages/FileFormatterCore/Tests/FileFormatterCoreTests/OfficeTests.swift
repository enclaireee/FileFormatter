import Foundation
import Testing
@testable import FileFormatterCore

@Suite("Office extraction")
struct OfficeTests {
    @Test func extractsDocxToMarkdown() async throws {
        let fixture = try #require(
            Bundle.module.url(forResource: "sample", withExtension: "docx", subdirectory: "Fixtures"),
            "missing DOCX fixture"
        )
        let service = ConversionService()
        let plan = try await service.makePlan(
            urls: [fixture],
            targets: TargetRecipe(document: .markdown),
            suffix: "-text"
        )

        let item = try #require(plan.items.first)
        #expect(item.kind == .document)
        #expect(item.fidelity == .extract)
        #expect(item.outputName == "sample-text.md")

        let result = try await service.convert(
            item,
            options: ConversionOptions(
                target: .markdown,
                quality: 1,
                suffix: "-text",
                preserveMetadata: false
            )
        )
        let text = try String(contentsOf: result.url, encoding: .utf8)
        #expect(text.contains("FileFormatter Office extraction"))
        #expect(text.contains("Hello from a DOCX file."))
    }
}
