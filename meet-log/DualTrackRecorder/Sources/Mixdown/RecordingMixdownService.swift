import Foundation

public struct RecordingMixdownService: Sendable {
    private let exporter = MixdownExporter()

    public init() {}

    public func export(
        systemAudioURL: URL?,
        microphoneURL: URL?,
        destinationURL: URL
    ) async throws -> URL {
        try await exporter.export(
            systemAudioURL: systemAudioURL,
            microphoneURL: microphoneURL,
            destinationURL: destinationURL
        )
    }
}
