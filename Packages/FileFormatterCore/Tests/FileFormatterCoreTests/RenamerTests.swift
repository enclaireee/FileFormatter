import Foundation
import Testing
@testable import FileFormatterCore

@Suite("Batch rename")
struct RenamerTests {
    private func folder(_ names: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in names {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }
        return directory
    }

    @Test func expandsTokens() {
        #expect(Renamer.expand("trip-{n:3}-{name}", name: "IMG", number: 7, date: "2026-10-18", ext: "jpg") == "trip-007-IMG")
        #expect(Renamer.expand("{date}_{n}.{ext}", name: "a", number: 12, date: "2026-10-18", ext: "png") == "2026-10-18_12.png")
    }

    @Test func flagsCollisions() throws {
        let directory = try folder(["a.txt", "b.txt", "keep.txt"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = ["a.txt", "b.txt"].map { directory.appendingPathComponent($0) }

        #expect(Renamer.preview(urls, pattern: "same").allSatisfy { $0.problem != nil })
        #expect(Renamer.preview([urls[0]], pattern: "keep").first?.problem != nil)
        #expect(Renamer.preview(urls, pattern: "x/{n}").allSatisfy { $0.problem != nil })
    }

    @Test func swapsNamesAndUndoes() throws {
        let directory = try folder(["1.txt", "2.txt"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = ["1.txt", "2.txt"].map { directory.appendingPathComponent($0) }

        // Reverse numbering forces a swap: 1 -> 2 and 2 -> 1.
        let plan = Renamer.preview(urls.reversed(), pattern: "{n}")
        #expect(plan.allSatisfy { $0.problem == nil })
        let done = try Renamer.apply(plan)
        #expect(done.count == 2)
        #expect(try String(contentsOf: urls[0], encoding: .utf8) == "2.txt")

        let undone = Renamer.revert(done)
        #expect(undone.restored == 2)
        #expect(try String(contentsOf: urls[0], encoding: .utf8) == "1.txt")
    }
}
