import Foundation

/// Locates the FFmpeg helper tools without relying on a login shell or Homebrew paths.
///
/// Search order for each tool:
/// 1. `Bundle.main.resourceURL/Helpers`
/// 2. `vendor/ffmpeg/bin` in the source checkout (located with `#filePath`)
/// 3. `/opt/homebrew/bin`
public struct FFmpegLocator: Sendable {
    public let ffmpegURL: URL?
    public let ffprobeURL: URL?

    /// Creates an explicitly configured locator. Tests use this to inject paths or to
    /// simulate a missing helper.
    public init(ffmpegURL: URL?, ffprobeURL: URL?) {
        self.ffmpegURL = ffmpegURL
        self.ffprobeURL = ffprobeURL
    }

    /// Discovers the tools using the production search order.
    public static func discover() -> FFmpegLocator {
        FFmpegLocator(
            ffmpegURL: locate("ffmpeg"),
            ffprobeURL: locate("ffprobe")
        )
    }

    /// The repository root, found by walking up from this source file until the
    /// `Packages` directory is visible. Using `#filePath` keeps this correct for
    /// command-line tests and Xcode builds without relying on the working directory.
    static var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let manager = FileManager.default
        while url.path != "/" {
            if manager.fileExists(atPath: url.appendingPathComponent("Packages").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    private static func locate(_ name: String) -> URL? {
        var directories: [URL] = []

        if let resources = Bundle.main.resourceURL {
            directories.append(resources.appendingPathComponent("Helpers", isDirectory: true))
        }
        directories.append(
            repositoryRoot
                .appendingPathComponent("vendor", isDirectory: true)
                .appendingPathComponent("ffmpeg", isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)
        )
        directories.append(URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true))

        let manager = FileManager.default
        for directory in directories {
            let candidate = directory.appendingPathComponent(name, isDirectory: false)
            if manager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
