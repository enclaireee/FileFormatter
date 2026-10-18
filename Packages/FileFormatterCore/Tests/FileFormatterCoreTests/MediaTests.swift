import Foundation
import Testing
@testable import FileFormatterCore

@Suite("Media backend")
struct MediaTests {
    @Test func exposesTargetMetadata() {
        #expect(MediaTarget.mp3.isAudio)
        #expect(MediaTarget.flac.isAudio)
        #expect(!MediaTarget.mp4.isAudio)
        #expect(!MediaTarget.webm.isAudio)
        #expect(MediaTarget.webm.fileExtension == "webm")
        #expect(MediaTarget.aiff.fileExtension == "aiff")
    }

    @Test func convertsAudioAndVideoThroughFFmpeg() async throws {
        let locator = FFmpegLocator.discover()
        let ffmpeg = try #require(
            locator.ffmpegURL,
            "ffmpeg was not found. Install FFmpeg or place it in vendor/ffmpeg/bin."
        )
        _ = try #require(
            locator.ffprobeURL,
            "ffprobe was not found. Install FFmpeg or place it in vendor/ffmpeg/bin."
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileFormatterMediaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let wav = directory.appendingPathComponent("tone.wav")
        try await generateSineWAV(ffmpeg: ffmpeg, destination: wav)

        let probe = MediaProbe(locator: locator)
        let wavInfo = try await probe.probe(wav)
        #expect((wavInfo.duration ?? 0) > 0.8)
        #expect(wavInfo.streams.contains { $0.codecType == "audio" })

        let converter = MediaConverter(locator: locator)
        for target in [MediaTarget.m4a, .mp3, .flac] {
            let destination = directory.appendingPathComponent("tone.\(target.fileExtension)")
            let recorder = ProgressRecorder()
            try await converter.convert(
                source: wav,
                destination: destination,
                format: target,
                quality: 0.6
            ) { value in
                recorder.record(value)
            }

            #expect(FileManager.default.fileExists(atPath: destination.path), "\(target) output missing")
            let info = try await probe.probe(destination)
            #expect(info.streams.contains { $0.codecType == "audio" }, "\(target) has no audio stream")
            #expect(recorder.values.contains(1.0), "\(target) never reported completion")
        }

        let mp4 = directory.appendingPathComponent("color.mp4")
        try await generateColorMP4(ffmpeg: ffmpeg, destination: mp4)
        let mp4Info = try await probe.probe(mp4)
        #expect(mp4Info.streams.contains { $0.codecType == "video" })

        let webm = directory.appendingPathComponent("color.webm")
        let recorder = ProgressRecorder()
        try await converter.convert(
            source: mp4,
            destination: webm,
            format: .webm,
            quality: 0.5
        ) { value in
            recorder.record(value)
        }
        #expect(FileManager.default.fileExists(atPath: webm.path))
        let webmInfo = try await probe.probe(webm)
        #expect(webmInfo.streams.contains { $0.codecType == "video" })
        #expect(recorder.values.contains(1.0))
    }

    @Test func probeReportsMissingHelper() async {
        let probe = MediaProbe(locator: FFmpegLocator(ffmpegURL: nil, ffprobeURL: nil))
        do {
            _ = try await probe.probe(URL(fileURLWithPath: "/tmp/does-not-exist.wav"))
            Issue.record("Expected MediaError.helperMissing")
        } catch let error as MediaError {
            #expect(error == .helperMissing(tool: "ffprobe"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func generateSineWAV(ffmpeg: URL, destination: URL) async throws {
        try await runFFmpeg(ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi",
            "-i", "sine=frequency=440:sample_rate=44100:duration=1",
            "-c:a", "pcm_s16le",
            destination.path
        ])
    }

    private func generateColorMP4(ffmpeg: URL, destination: URL) async throws {
        try await runFFmpeg(ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi",
            "-i", "testsrc=size=160x120:rate=15:duration=1",
            "-f", "lavfi",
            "-i", "sine=frequency=440:sample_rate=44100:duration=1",
            "-c:v", "h264_videotoolbox",
            "-allow_sw", "1",
            "-b:v", "1M",
            "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            "-shortest",
            destination.path
        ])
    }

    private func runFFmpeg(_ executable: URL, _ arguments: [String]) async throws {
        let result = try await MediaProcess.run(executable: executable, arguments: arguments)
        guard result.status == 0 else {
            throw MediaError.conversionFailed(message: mediaStderrTail(result.stderr))
        }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
