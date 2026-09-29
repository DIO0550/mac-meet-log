import Foundation

public enum RecordingMixdownOutcome: Equatable, Sendable {
    case mixed(URL)
    case failed(RecorderError)

    public var url: URL? {
        switch self {
        case let .mixed(url):
            url
        case .failed:
            nil
        }
    }

    public var error: RecorderError? {
        switch self {
        case .mixed:
            nil
        case let .failed(error):
            error
        }
    }
}
