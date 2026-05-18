import Foundation

public enum RecorderError: Error, Equatable, LocalizedError, Sendable {
    case permissionDenied(String)
    case captureFailed(String)
    case outputFailed(String)
    case invalidState(operation: String, state: String)
    case invalidSources(String)
    case mixdownFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .permissionDenied(message),
             let .captureFailed(message),
             let .outputFailed(message),
             let .invalidSources(message),
             let .mixdownFailed(message):
            message
        case let .invalidState(operation, state):
            "Cannot \(operation) while recorder is \(state)."
        }
    }
}
