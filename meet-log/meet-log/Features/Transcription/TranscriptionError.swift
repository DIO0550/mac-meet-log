import Foundation

enum TranscriptionError: Error, Equatable, LocalizedError, Sendable {
    case authorizationDenied
    case authorizationRestricted
    case authorizationUnavailable
    case recognizerUnsupportedForLocale(localeIdentifier: String)
    case recognizerTemporarilyUnavailable(localeIdentifier: String)
    case onDeviceRecognitionUnavailable(localeIdentifier: String)
    case recognitionFailed(String)
    case emptyResult
    case transcriptionIncomplete

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "Speech recognition permission is denied."
        case .authorizationRestricted:
            return "Speech recognition is restricted on this Mac."
        case .authorizationUnavailable:
            return "Speech recognition permission could not be confirmed."
        case let .recognizerUnsupportedForLocale(localeIdentifier):
            return "Speech recognition is not supported for \(localeIdentifier) on this Mac."
        case let .recognizerTemporarilyUnavailable(localeIdentifier):
            return "Speech recognition for \(localeIdentifier) is temporarily unavailable."
        case let .onDeviceRecognitionUnavailable(localeIdentifier):
            return "On-device speech recognition is unavailable for \(localeIdentifier)."
        case let .recognitionFailed(message):
            return "Speech recognition failed: \(message)"
        case .emptyResult:
            return "Speech recognition finished without transcript text."
        case .transcriptionIncomplete:
            return "Speech recognition ended before a final transcript was produced."
        }
    }
}
