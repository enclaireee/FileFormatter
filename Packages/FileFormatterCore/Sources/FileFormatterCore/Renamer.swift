import Foundation

/// Batch rename with a token pattern. The extension is always kept.
/// Tokens: {name} original name, {n} counter, {n:3} zero-padded counter,
/// {date} file creation date (yyyy-MM-dd), {ext} original extension.
public enum Renamer {
    public struct Rename: Sendable, Equatable, Identifiable {
        public let from: URL
        public let to: URL
        public let problem: String?
        public var id: URL { from }
    }

    public static func preview(_ urls: [URL], pattern: String, start: Int = 1) -> [Rename] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let sources = Set(urls.map { $0.standardizedFileURL.path.lowercased() })

        var drafts: [(URL, URL, String?)] = []
        for (offset, url) in urls.enumerated() {
            let ext = url.pathExtension
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
            let stem = expand(
                pattern,
                name: url.deletingPathExtension().lastPathComponent,
                number: start + offset,
                date: formatter.string(from: created),
                ext: ext
            ).trimmingCharacters(in: .whitespaces)
            let fileName = ext.isEmpty ? stem : "\(stem).\(ext)"
            let target = url.deletingLastPathComponent().appendingPathComponent(fileName)

            var problem: String?
            if stem.isEmpty {
                problem = "Name is empty"
            } else if stem.contains("/") || stem.contains(":") || stem.hasPrefix(".") {
                problem = "Names can't contain / or : or start with a dot"
            } else if target.path.lowercased() != url.path.lowercased(),
                      FileManager.default.fileExists(atPath: target.path),
                      !sources.contains(target.standardizedFileURL.path.lowercased()) {
                problem = "\(fileName) already exists"
            }
            drafts.append((url, target, problem))
        }

        var counts: [String: Int] = [:]
        for draft in drafts { counts[draft.1.path.lowercased(), default: 0] += 1 }
        return drafts.map { from, to, problem in
            Rename(
                from: from,
                to: to,
                problem: problem ?? (counts[to.path.lowercased(), default: 0] > 1 ? "Two files would get this name" : nil)
            )
        }
    }

    /// Renames in two phases (through temporary names) so swaps and cycles work.
    /// Returns the completed [from, to] pairs for the journal. Rolls back on failure.
    public static func apply(_ renames: [Rename]) throws -> [[URL]] {
        if let bad = renames.first(where: { $0.problem != nil }) {
            throw ConversionError.writeFailed(bad.problem ?? "Invalid name")
        }
        let moves = renames.filter { $0.from.path != $0.to.path }
        let manager = FileManager.default
        var staged: [(Rename, URL)] = []
        var done: [[URL]] = []
        do {
            for rename in moves {
                let temporary = rename.from.deletingLastPathComponent()
                    .appendingPathComponent(".fileformatter-rename-\(UUID().uuidString)")
                try manager.moveItem(at: rename.from, to: temporary)
                staged.append((rename, temporary))
            }
            for (rename, temporary) in staged {
                try manager.moveItem(at: temporary, to: rename.to)
                done.append([rename.from, rename.to])
            }
        } catch {
            let finished = Set(done.map { $0[0] })
            for (rename, temporary) in staged where !finished.contains(rename.from) {
                try? manager.moveItem(at: temporary, to: rename.from)
            }
            _ = revert(done)
            throw ConversionError.writeFailed(error.localizedDescription)
        }
        return done
    }

    /// Moves each [from, to] pair back. Returns (restored, failed).
    @discardableResult
    public static func revert(_ pairs: [[URL]]) -> (restored: Int, failed: Int) {
        let valid = pairs.filter { $0.count == 2 }
        let preview = valid.map { Rename(from: $0[1], to: $0[0], problem: nil) }
        do {
            return (try apply(preview).count, 0)
        } catch {
            return (0, valid.count)
        }
    }

    static func expand(_ pattern: String, name: String, number: Int, date: String, ext: String) -> String {
        var result = pattern
            .replacingOccurrences(of: "{name}", with: name)
            .replacingOccurrences(of: "{date}", with: date)
            .replacingOccurrences(of: "{ext}", with: ext)
            .replacingOccurrences(of: "{n}", with: String(number))
        while let range = result.range(of: #"\{n:(\d)\}"#, options: .regularExpression) {
            let width = Int(result[range].dropFirst(3).dropLast()) ?? 1
            let digits = String(number)
            result.replaceSubrange(range, with: String(repeating: "0", count: max(0, width - digits.count)) + digits)
        }
        return result
    }
}
