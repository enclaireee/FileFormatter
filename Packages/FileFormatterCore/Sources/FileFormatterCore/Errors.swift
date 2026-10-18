import Foundation

public enum ConversionError: LocalizedError, Sendable {
    case unsupportedTarget(String)
    case cannotReadSource(String)
    case cannotCreateDestination(String)
    case writeFailed(String)
    case cancelled
    case core(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedTarget(let name):
            "\(name) output is not available in this build."
        case .cannotReadSource(let name):
            "Could not read \(name). The file may be corrupt or in an unsupported format."
        case .cannotCreateDestination(let name):
            "Could not create \(name). Check that the folder is writable."
        case .writeFailed(let message):
            "The conversion could not be completed. \(message)"
        case .cancelled:
            "The conversion was cancelled."
        case .core(let message):
            message
        }
    }
}
