import Foundation

public struct RecordingSources: Equatable, Sendable {
    public let systemAudioEnabled: Bool
    public let microphoneEnabled: Bool

    public init(systemAudioEnabled: Bool = true, microphoneEnabled: Bool = true) {
        self.systemAudioEnabled = systemAudioEnabled
        self.microphoneEnabled = microphoneEnabled
    }

    public var hasAnyEnabledSource: Bool {
        systemAudioEnabled || microphoneEnabled
    }

    public func validate() throws {
        guard hasAnyEnabledSource else {
            throw RecorderError.invalidSources("At least one recording source must be enabled.")
        }
    }
}
