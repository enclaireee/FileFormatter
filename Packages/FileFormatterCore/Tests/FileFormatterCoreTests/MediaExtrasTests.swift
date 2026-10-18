import Foundation
import Testing
@testable import FileFormatterCore

@Suite("Media extras")
struct MediaExtrasTests {
    private let src = URL(fileURLWithPath: "/tmp/in.mp4")
    private let dst = URL(fileURLWithPath: "/tmp/out")

    @Test func gifArguments() {
        let args = MediaConverter.arguments(source: src, destination: dst, format: .gif, quality: 0.6)
        #expect(args.contains { $0.contains("palettegen") })
        #expect(args.contains("-loop"))
        #expect(args.contains("-an"))
        #expect(MediaTarget.gif.fileExtension == "gif" && !MediaTarget.gif.isAudio)
    }

    @Test func targetSizeLowersVideoBitrate() throws {
        let args = MediaConverter.arguments(
            source: src, destination: dst, format: .mp4, quality: 0.6,
            targetBytes: 10_000_000, duration: 60
        )
        let i = try #require(args.firstIndex(of: "-b:v"))
        let kbps = try #require(Int(args[i + 1].dropLast()))
        #expect(kbps < 1400)
        #expect(args.contains("-vf"))
        #expect(!args.contains("4M"))
    }

    @Test func convertsToGifAndFitsSize() async throws {
        let locator = FFmpegLocator.discover()
        let ffmpeg = try #require(locator.ffmpegURL, "ffmpeg was not found.")
        _ = try #require(locator.ffprobeURL, "ffprobe was not found.")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileFormatterExtras-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let video = dir.appendingPathComponent("in.mp4")
        try await makeTestVideo(ffmpeg: ffmpeg, destination: video)
        let converter = MediaConverter(locator: locator)

        let gif = dir.appendingPathComponent("out.gif")
        try await converter.convert(source: video, destination: gif, format: .gif, quality: 0.6)
        let head = try FileHandle(forReadingFrom: gif).read(upToCount: 4) ?? Data()
        #expect(String(decoding: head, as: UTF8.self) == "GIF8")

        let small = dir.appendingPathComponent("small.mp4")
        try await converter.convert(
            source: video, destination: small, format: .mp4, quality: 0.6, targetBytes: 600_000
        )
        let size = try #require(
            try FileManager.default.attributesOfItem(atPath: small.path)[.size] as? NSNumber
        ).doubleValue
        #expect(size <= 600_000 * 1.15)
    }

    private func makeTestVideo(ffmpeg: URL, destination: URL) async throws {
        let result = try await MediaProcess.run(executable: ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=size=1280x720:rate=30",
            "-f", "lavfi", "-i", "sine=frequency=440",
            "-t", "3",
            "-c:v", "h264_videotoolbox", "-allow_sw", "1", "-b:v", "8M",
            "-pix_fmt", "yuv420p", "-c:a", "aac",
            destination.path
        ])
        guard result.status == 0 else {
            throw MediaError.conversionFailed(message: mediaStderrTail(result.stderr))
        }
    }
}
