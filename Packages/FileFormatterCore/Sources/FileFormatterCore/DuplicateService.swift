import Foundation
import FileFormatterRust

public struct DuplicateSet: Identifiable, Sendable, Hashable {
    public let id: String
    public let byteSize: UInt64
    public let paths: [URL]

    public init(hash: String, byteSize: UInt64, paths: [URL]) {
        self.id = hash
        self.byteSize = byteSize
        self.paths = paths
    }

    public var wastedBytes: UInt64 {
        byteSize * UInt64(max(0, paths.count - 1))
    }
}

public actor DuplicateService {
    public init() {}

    public func scan(folder: URL) async throws -> [DuplicateSet] {
        try Task.checkCancellation()
        let paths = await Task.detached(priority: .userInitiated) {
            Self.enumerateFiles(in: folder)
        }.value

        try Task.checkCancellation()
        guard paths.count > 1 else { return [] }
        let groups = await Task.detached(priority: .userInitiated) {
            FileFormatterRust.findDuplicates(paths: paths)
        }.value
        try Task.checkCancellation()
        return groups
            .map { group in
                DuplicateSet(
                    hash: group.hash,
                    byteSize: group.byteSize,
                    paths: group.paths.map { URL(fileURLWithPath: $0) }
                )
            }
            .sorted { $0.wastedBytes > $1.wastedBytes }
    }

    public func trashExtras(in set: DuplicateSet, keeping keep: URL) async -> (trashed: Int, failed: Int) {
        let targets = set.paths.filter { $0.standardizedFileURL != keep.standardizedFileURL }
        return await trash(urls: targets)
    }

    public func trash(urls: [URL]) async -> (trashed: Int, failed: Int) {
        var trashed = 0
        var failed = 0
        for path in urls {
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: path, resultingItemURL: &resulting)
                trashed += 1
            } catch {
                failed += 1
            }
        }
        return (trashed, failed)
    }

    private nonisolated static func enumerateFiles(in folder: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var paths: [String] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            paths.append(url.standardizedFileURL.path)
        }
        return paths
    }
}
