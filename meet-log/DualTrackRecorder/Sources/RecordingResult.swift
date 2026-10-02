import Foundation

public struct RecordingResult: Equatable, Sendable {
    public let duration: Duration
    public let systemAudioURL: URL?
    public let microphoneURL: URL?
    public let screenCaptureURL: URL?
    public let mixdown: RecordingMixdownOutcome
    public let displayFileName: String

    public var mixdownURL: URL? {
        mixdown.url
    }

    public init(
        duration: Duration,
        systemAudioURL: URL?,
        microphoneURL: URL?,
        screenCaptureURL: URL? = nil,
        mixdown: RecordingMixdownOutcome,
        displayFileName: String
    ) {
        self.duration = duration
        self.systemAudioURL = systemAudioURL
        self.microphoneURL = microphoneURL
        self.screenCaptureURL = screenCaptureURL
        self.mixdown = mixdown
        self.displayFileName = displayFileName
    }
}
