import Foundation

public struct RecordingSources: Equatable, Sendable {
    public let systemAudioEnabled: Bool
    public let microphoneEnabled: Bool
    public let screenCaptureEnabled: Bool

    public init(
        systemAudioEnabled: Bool = true,
        microphoneEnabled: Bool = true,
        screenCaptureEnabled: Bool = false
    ) {
        self.systemAudioEnabled = systemAudioEnabled
        self.microphoneEnabled = microphoneEnabled
        self.screenCaptureEnabled = screenCaptureEnabled
    }

    public var hasAnyEnabledSource: Bool {
        systemAudioEnabled || microphoneEnabled
    }

    public func validate() throws {
        guard hasAnyEnabledSource else {
            throw RecorderError.invalidSources("At least one audio source must be enabled.")
        }
    }
}
