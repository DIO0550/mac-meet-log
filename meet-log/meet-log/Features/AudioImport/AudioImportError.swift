import Foundation

enum AudioImportError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedFormat(String)
    case fileNotFound
    case emptyFile
    case permissionDenied(String)
    case unreadable(String)
    case metadataUnavailable(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(fileExtension):
            let suffix = fileExtension.isEmpty ? "no extension" : ".\(fileExtension)"
            return "Unsupported audio format: \(suffix). Choose an mp3, m4a, or wav file."
        case .fileNotFound:
            return "The selected audio file could not be found."
        case .emptyFile:
            return "The selected audio file is empty."
        case let .permissionDenied(message):
            return "The selected audio file could not be accessed: \(message)"
        case let .unreadable(message):
            return "The selected audio file could not be read: \(message)"
        case let .metadataUnavailable(message):
            return "Audio metadata could not be read: \(message)"
        }
    }
}
