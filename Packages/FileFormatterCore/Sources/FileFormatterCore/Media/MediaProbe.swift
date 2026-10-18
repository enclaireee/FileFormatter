import Foundation

public enum MediaError: Error, LocalizedError, Equatable, Sendable {
    case helperMissing(tool: String)
    case probeFailed(message: String)
    case conversionFailed(message: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .helperMissing(let tool):
            "\(tool) is missing. Install FFmpeg or place it in FileFormatter's Helpers folder."
        case .probeFailed(let message):
            "Couldn't inspect this file. \(message)"
        case .conversionFailed(let message):
            "FFmpeg couldn't finish this conversion. \(message)"
        case .cancelled:
            "The conversion was cancelled."
        }
    }
}

public struct MediaInfo: Codable, Equatable, Sendable {
    public let duration: Double?
    public let formatName: String?
    public let streams: [MediaStreamInfo]

    public init(duration: Double?, formatName: String?, streams: [MediaStreamInfo]) {
        self.duration = duration
        self.formatName = formatName
        self.streams = streams
    }
}

public struct MediaStreamInfo: Codable, Equatable, Sendable, Identifiable {
    public let index: Int
    public let codecType: String
    public let codecName: String
    public let width: Int?
    public let height: Int?
    public let channels: Int?
    public let sampleRate: Int?
    public let language: String?
    public let title: String?

    public var id: Int { index }

    public init(
        index: Int,
        codecType: String,
        codecName: String,
        width: Int? = nil,
        height: Int? = nil,
        channels: Int? = nil,
        sampleRate: Int? = nil,
        language: String? = nil,
        title: String? = nil
    ) {
        self.index = index
        self.codecType = codecType
        self.codecName = codecName
        self.width = width
        self.height = height
        self.channels = channels
        self.sampleRate = sampleRate
        self.language = language
        self.title = title
    }
}

/// Reads media metadata with `ffprobe` and normalizes its JSON into `MediaInfo`.
public struct MediaProbe: Sendable {
    private let locator: FFmpegLocator

    public init(locator: FFmpegLocator = .discover()) {
        self.locator = locator
    }

    public func probe(_ url: URL) async throws -> MediaInfo {
        guard let ffprobe = locator.ffprobeURL else {
            throw MediaError.helperMissing(tool: "ffprobe")
        }

        let arguments = [
            "-v", "error",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            url.path
        ]

        let session = MediaProcess(executable: ffprobe, arguments: arguments)
        let result = try await withTaskCancellationHandler {
            try await session.run()
        } onCancel: {
            session.cancel()
        }

        guard result.status == 0 else {
            throw MediaError.probeFailed(message: mediaStderrTail(result.stderr))
        }

        let decoded: ProbeOutput
        do {
            decoded = try JSONDecoder().decode(ProbeOutput.self, from: result.stdout)
        } catch {
            throw MediaError.probeFailed(message: "ffprobe returned unreadable metadata.")
        }

        let duration = decoded.format?.duration
            .flatMap(Double.init)
            .flatMap { $0 > 0 ? $0 : nil }

        let streams = (decoded.streams ?? []).map { stream -> MediaStreamInfo in
            let tags = (stream.tags ?? [:]).reduce(into: [String: String]()) { result, pair in
                result[pair.key.lowercased()] = pair.value
            }
            return MediaStreamInfo(
                index: stream.index,
                codecType: stream.codecType ?? "unknown",
                codecName: stream.codecName ?? "",
                width: stream.width,
                height: stream.height,
                channels: stream.channels,
                sampleRate: stream.sampleRate.flatMap(Int.init),
                language: tags["language"],
                title: tags["title"]
            )
        }

        return MediaInfo(
            duration: duration,
            formatName: decoded.format?.formatName,
            streams: streams
        )
    }
}

func mediaStderrTail(_ data: Data, limit: Int = 2_048) -> String {
    let text = String(decoding: data.suffix(limit), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? "FFmpeg exited without a diagnostic." : text
}

private struct ProbeOutput: Decodable {
    let format: ProbeFormat?
    let streams: [ProbeStream]?

    enum CodingKeys: String, CodingKey {
        case format
        case streams
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decodeIfPresent(ProbeFormat.self, forKey: .format)
        streams = try container.decodeIfPresent([ProbeStream].self, forKey: .streams)
    }
}

private struct ProbeFormat: Decodable {
    let duration: String?
    let formatName: String?

    enum CodingKeys: String, CodingKey {
        case duration
        case formatName = "format_name"
    }
}

private struct ProbeStream: Decodable {
    let index: Int
    let codecType: String?
    let codecName: String?
    let width: Int?
    let height: Int?
    let channels: Int?
    let sampleRate: String?
    let tags: [String: String]?

    enum CodingKeys: String, CodingKey {
        case index
        case codecType = "codec_type"
        case codecName = "codec_name"
        case width
        case height
        case channels
        case sampleRate = "sample_rate"
        case tags
    }
}
