import Foundation

public enum MediaTarget: String, Sendable, CaseIterable, Hashable {
    case mp3
    case m4a
    case flac
    case wav
    case aiff
    case opus
    case ogg
    case mp4
    case mov
    case mkv
    case webm
    case gif

    public var fileExtension: String { rawValue }

    public var isAudio: Bool {
        switch self {
        case .mp3, .m4a, .flac, .wav, .aiff, .opus, .ogg: true
        case .mp4, .mov, .mkv, .webm, .gif: false
        }
    }
}

/// Converts media with the FFmpeg CLI. The caller supplies the final destination;
/// the actor writes there with `-y` and reports progress from `-progress pipe:1`.
public actor MediaConverter {
    private let locator: FFmpegLocator
    private let probe: MediaProbe

    public init(locator: FFmpegLocator = .discover()) {
        self.locator = locator
        self.probe = MediaProbe(locator: locator)
    }

    public func convert(
        source: URL,
        destination: URL,
        format: MediaTarget,
        quality: Double,
        targetBytes: UInt64? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        guard let ffmpeg = locator.ffmpegURL else {
            throw MediaError.helperMissing(tool: "ffmpeg")
        }

        // A failed probe costs progress only; it must not block a conversion.
        let info: MediaInfo?
        do {
            info = try await probe.probe(source)
        } catch let error as MediaError {
            if case .cancelled = error { throw error }
            info = nil
        } catch {
            info = nil
        }
        if Task.isCancelled {
            throw MediaError.cancelled
        }
        let duration = info?.duration
        let sink = ProgressSink(handler: progress)
        sink.report(0)

        let lineHandler: @Sendable (String) -> Void = { line in
            guard let duration, duration > 0 else { return }
            if line.hasPrefix("out_time_ms="),
               let micros = Double(line.dropFirst("out_time_ms=".count)) {
                sink.report(micros / 1_000_000 / duration)
            } else if line.hasPrefix("progress=end") {
                sink.report(1)
            }
        }

        let session = MediaProcess(
            executable: ffmpeg,
            arguments: Self.arguments(
                source: source,
                destination: destination,
                format: format,
                quality: quality,
                targetBytes: targetBytes,
                duration: duration
            ),
            onStdoutLine: lineHandler
        )

        let result: MediaProcess.Result
        do {
            result = try await withTaskCancellationHandler {
                try await session.run()
            } onCancel: {
                session.cancel()
            }
        } catch let error as MediaError {
            throw error
        } catch {
            throw MediaError.conversionFailed(message: error.localizedDescription)
        }

        guard result.status == 0 else {
            throw MediaError.conversionFailed(message: mediaStderrTail(result.stderr))
        }
        sink.report(1)
    }

    nonisolated static func arguments(
        source: URL,
        destination: URL,
        format: MediaTarget,
        quality: Double,
        targetBytes: UInt64? = nil,
        duration: Double? = nil
    ) -> [String] {
        // Without a known duration a size target can't become a bitrate, so it is ignored.
        let sizeTarget: (bytes: UInt64, duration: Double)? = {
            guard let targetBytes, targetBytes > 0, let duration, duration > 0 else { return nil }
            return (targetBytes, duration)
        }()

        var arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-progress", "pipe:1",
            "-nostats",
            "-i", source.path
        ]

        if format.isAudio {
            var kbps = audioBitrate(quality)
            if let t = sizeTarget {
                let raw = Double(t.bytes) * 8 * 0.95 / t.duration / 1000
                kbps = (Int(min(max(raw, 48), 320)) / 8) * 8
            }
            arguments += ["-map", "0:a?", "-map_metadata", "0", "-vn"]
            switch format {
            case .mp3:
                arguments += ["-c:a", "libmp3lame", "-b:a", "\(kbps)k"]
            case .m4a:
                arguments += ["-c:a", "aac", "-b:a", "\(kbps)k"]
            case .flac:
                arguments += ["-c:a", "flac"]
            case .wav:
                arguments += ["-c:a", "pcm_s16le"]
            case .aiff:
                arguments += ["-c:a", "pcm_s16be"]
            case .opus:
                arguments += ["-c:a", "libopus", "-b:a", "\(kbps)k"]
            case .ogg:
                arguments += ["-c:a", "libvorbis", "-b:a", "\(kbps)k"]
            default:
                break
            }
        } else if format == .gif {
            let (fps, width) = quality >= 0.8 ? (15, 800) : quality <= 0.5 ? (10, 480) : (12, 640)
            arguments += [
                "-map", "0:v:0", "-an",
                "-vf", "fps=\(fps),scale='min(\(width),iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4",
                "-loop", "0"
            ]
        } else {
            arguments += ["-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0"]

            if format != .webm {
                arguments += ["-map_chapters", "0", "-map", "0:s?", "-c:s", "copy"]
            }

            var videoKbps: Int?
            if let t = sizeTarget {
                let audioKbps = t.bytes <= 25_000_000 ? 96.0 : 128.0
                let total = Double(t.bytes) * 8 * 0.92 / t.duration / 1000
                let v = Int(max(150, total - audioKbps))
                videoKbps = v
                if v < 600 {
                    arguments += ["-vf", "scale=-2:'min(480,ih)'"]
                } else if v < 1500 {
                    arguments += ["-vf", "scale=-2:'min(720,ih)'"]
                }
            }
            let h264Rate = videoKbps.map {
                ["-b:v", "\($0)k", "-maxrate", "\(Int(Double($0) * 1.2))k", "-bufsize", "\($0 * 2)k"]
            } ?? ["-b:v", "4M"]

            switch format {
            case .mp4, .mov, .mkv:
                arguments += ["-c:v", "h264_videotoolbox", "-allow_sw", "1"] + h264Rate + [
                    "-pix_fmt", "yuv420p",
                    "-c:a", "aac",
                    "-b:a", "\(sizeTarget == nil ? audioBitrate(quality) : (videoKbps != nil && sizeTarget!.bytes <= 25_000_000 ? 96 : 128))k"
                ]
                if format != .mkv {
                    arguments += ["-movflags", "+faststart"]
                }
            case .webm:
                arguments += ["-c:v", "libvpx-vp9"]
                arguments += videoKbps.map { ["-b:v", "\($0)k"] } ?? ["-crf", "32", "-b:v", "0"]
                arguments += [
                    "-pix_fmt", "yuv420p",
                    "-c:a", "libopus",
                    "-b:a", "\(sizeTarget == nil ? audioBitrate(quality) : (sizeTarget!.bytes <= 25_000_000 ? 96 : 128))k"
                ]
            default:
                break
            }
        }

        arguments.append(destination.path)
        return arguments
    }

    private nonisolated static func audioBitrate(_ quality: Double) -> Int {
        let clamped = min(max(quality, 0.3), 1.0)
        let raw = 96.0 + (clamped - 0.3) / 0.7 * 224.0
        return max(96, min(320, (Int(raw.rounded()) / 8) * 8))
    }
}

/// Serializes progress updates and drops duplicates so clients don't receive a flood.
private final class ProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (Double) -> Void
    private var last: Double = -1

    init(handler: @escaping @Sendable (Double) -> Void) {
        self.handler = handler
    }

    func report(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        lock.lock()
        guard clamped > last + 0.001 || (clamped >= 1 && last < 1) else {
            lock.unlock()
            return
        }
        last = clamped
        lock.unlock()
        handler(clamped)
    }
}

/// Runs one FFmpeg process, draining stdout and stderr concurrently so neither
/// pipe can fill and deadlock the child. Cancellation terminates the process.
final class MediaProcess: @unchecked Sendable {
    struct Result: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    private let executable: URL
    private let arguments: [String]
    private let onStdoutLine: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var process: Process?
    private var continuation: CheckedContinuation<Result, Error>?
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutRemainder = ""
    private var stdoutEOF = false
    private var stderrEOF = false
    private var terminated = false
    private var exitStatus: Int32 = -1
    private var cancelled = false
    private var finished = false
    private var launchFailure: String?

    init(
        executable: URL,
        arguments: [String],
        onStdoutLine: (@Sendable (String) -> Void)? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.onStdoutLine = onStdoutLine
    }

    static func run(executable: URL, arguments: [String]) async throws -> Result {
        let session = MediaProcess(executable: executable, arguments: arguments)
        return try await withTaskCancellationHandler {
            try await session.run()
        } onCancel: {
            session.cancel()
        }
    }

    func run() async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(throwing: MediaError.cancelled)
                return
            }
            self.continuation = continuation
            lock.unlock()
            start()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        process?.terminate()
    }

    private func start() {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.readStdout(handle)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.readStderr(handle)
        }
        process.terminationHandler = { [weak self] process in
            self?.processTerminated(status: process.terminationStatus)
        }

        lock.lock()
        self.process = process
        let shouldCancel = cancelled
        lock.unlock()

        if shouldCancel {
            lock.lock()
            terminated = true
            stdoutEOF = true
            stderrEOF = true
            exitStatus = -1
            lock.unlock()
            finishIfReady()
            return
        }

        do {
            try process.run()
        } catch {
            launchFailed(error)
            return
        }

        // Close the race where cancellation arrives after the pre-run check but
        // before the child is actually running.
        lock.lock()
        let cancelAfterLaunch = cancelled
        lock.unlock()
        if cancelAfterLaunch {
            process.terminate()
        }
    }

    private func readStdout(_ handle: FileHandle) {
        let data = handle.availableData
        var lines: [String] = []

        lock.lock()
        if data.isEmpty {
            stdoutEOF = true
            handle.readabilityHandler = nil
        } else {
            stdout.append(data)
            stdoutRemainder += String(decoding: data, as: UTF8.self)
            while let newline = stdoutRemainder.firstIndex(of: "\n") {
                let line = String(stdoutRemainder[..<newline])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                stdoutRemainder.removeSubrange(stdoutRemainder.startIndex...newline)
                if !line.isEmpty {
                    lines.append(line)
                }
            }
        }
        lock.unlock()

        for line in lines {
            onStdoutLine?(line)
        }
        finishIfReady()
    }

    private func readStderr(_ handle: FileHandle) {
        let data = handle.availableData
        lock.lock()
        if data.isEmpty {
            stderrEOF = true
            handle.readabilityHandler = nil
        } else {
            stderr.append(data)
            if stderr.count > 4_096 {
                stderr.removeFirst(stderr.count - 4_096)
            }
        }
        lock.unlock()
        finishIfReady()
    }

    private func processTerminated(status: Int32) {
        lock.lock()
        terminated = true
        exitStatus = status
        lock.unlock()
        finishIfReady()
    }

    private func launchFailed(_ error: Error) {
        lock.lock()
        launchFailure = error.localizedDescription
        terminated = true
        stdoutEOF = true
        stderrEOF = true
        exitStatus = -1
        lock.unlock()
        finishIfReady()
    }

    private func finishIfReady() {
        lock.lock()
        guard !finished,
              let continuation,
              terminated,
              stdoutEOF,
              stderrEOF else {
            lock.unlock()
            return
        }

        finished = true
        self.continuation = nil
        let result = Result(status: exitStatus, stdout: stdout, stderr: stderr)
        let cancelled = self.cancelled
        let launchFailure = self.launchFailure
        lock.unlock()

        if cancelled {
            continuation.resume(throwing: MediaError.cancelled)
        } else if let launchFailure {
            continuation.resume(
                throwing: MediaError.conversionFailed(message: launchFailure)
            )
        } else {
            continuation.resume(returning: result)
        }
    }
}
