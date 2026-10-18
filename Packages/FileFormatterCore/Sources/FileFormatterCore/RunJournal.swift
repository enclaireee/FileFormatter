import Foundation

public actor RunJournal {
    public static let shared = RunJournal()

    private let fileURL: URL
    private let maximumRuns = 20

    public init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("FileFormatter", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        self.fileURL = directory.appendingPathComponent("runs.json")
    }

    public func all() -> [RunSummary] {
        load()
    }

    public func latest() -> RunSummary? {
        load().last
    }

    public func save(_ summary: RunSummary) throws {
        var runs = load()
        runs.append(summary)
        if runs.count > maximumRuns {
            runs.removeFirst(runs.count - maximumRuns)
        }
        try write(runs)
    }

    public func markUndone(id: UUID) throws {
        var runs = load()
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[index].undone = true
        try write(runs)
    }

    private func load() -> [RunSummary] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RunSummary].self, from: data)) ?? []
    }

    private func write(_ runs: [RunSummary]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(runs)
        try data.write(to: fileURL, options: .atomic)
    }
}

public enum ByteCount {
    public static func string(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(clamping: bytes),
            countStyle: .file
        )
    }
}
