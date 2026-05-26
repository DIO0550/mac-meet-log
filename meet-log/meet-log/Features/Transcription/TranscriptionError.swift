import Foundation

enum TranscriptionError: Error, Equatable, LocalizedError, Sendable {
    case authorizationDenied
    case authorizationRestricted
    case authorizationUnavailable
    case recognizerUnavailable(localeIdentifier: String)
    case recognizerNotAvailable(localeIdentifier: String)
    case onDeviceRecognitionUnavailable(localeIdentifier: String)
    case recognitionFailed(String)
    case emptyResult
    case cancelled

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "Speech recognition permission is denied."
        case .authorizationRestricted:
            return "Speech recognition is restricted on this Mac."
        case .authorizationUnavailable:
            return "Speech recognition permission could not be confirmed."
        case let .recognizerUnavailable(localeIdentifier):
            return "Speech recognition is unavailable for \(localeIdentifier)."
        case let .recognizerNotAvailable(localeIdentifier):
            return "Speech recognition for \(localeIdentifier) is not currently available."
        case let .onDeviceRecognitionUnavailable(localeIdentifier):
            return "On-device speech recognition is unavailable for \(localeIdentifier)."
        case let .recognitionFailed(message):
            return "Speech recognition failed: \(message)"
        case .emptyResult:
            return "Speech recognition finished without transcript text."
        case .cancelled:
            return "Speech recognition was cancelled."
        }
    }
}
