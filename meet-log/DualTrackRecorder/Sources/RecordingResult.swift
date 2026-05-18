import Foundation

public struct RecordingResult: Equatable, Sendable {
    public let duration: Duration
    public let systemAudioURL: URL?
    public let microphoneURL: URL?
    public let mixdownURL: URL
    public let displayFileName: String

    public init(
        duration: Duration,
        systemAudioURL: URL?,
        microphoneURL: URL?,
        mixdownURL: URL,
        displayFileName: String
    ) {
        self.duration = duration
        self.systemAudioURL = systemAudioURL
        self.microphoneURL = microphoneURL
        self.mixdownURL = mixdownURL
        self.displayFileName = displayFileName
    }
}
