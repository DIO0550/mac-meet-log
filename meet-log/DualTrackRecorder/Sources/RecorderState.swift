import Foundation

public enum RecorderState: Equatable, Sendable {
    case idle
    case preparing
    case recording(startedAt: Date)
    case paused(elapsed: Duration)
    case finalizing
    case complete(RecordingResult)
    case failed(RecorderError)
}
