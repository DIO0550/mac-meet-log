import AVFoundation
import Foundation
@testable import DualTrackRecorder

final class FakeRecorderHarness {
    let baseURL: URL
    var microphoneCapture = FakeAudioCapture()
    var systemAudioCapture = FakeAudioCapture()
    var mixdownExporter = FakeMixdownExporter()
    private(set) var writers: [RecordingTrack: FakeTrackWriter] = [:]

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    var dependencies: RecorderDependencies {
        RecorderDependencies(
            outputDirectoryFactory: { [baseURL] _ in OutputDirectory(url: baseURL) },
            writerFactory: { [weak self] track, url in
                let writer = FakeTrackWriter(url: url)
                self?.writers[track] = writer
                return writer
            },
            microphoneCaptureFactory: { [microphoneCapture] _ in microphoneCapture },
            systemAudioCaptureFactory: { [systemAudioCapture] _ in systemAudioCapture },
            mixdownExporter: mixdownExporter
        )
    }
}

final class FakeAudioCapture: AudioCapture {
    var startError: RecorderError?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() async throws {
        startCount += 1

        if let startError {
            throw startError
        }
    }

    func stop() {
        stopCount += 1
    }
}

final class FakeTrackWriter: TrackWriting {
    let url: URL
    var closeError: RecorderError?
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var closeCount = 0

    init(url: URL) {
        self.url = url
    }

    func write(_: AVAudioPCMBuffer) throws {}

    func pause() {
        pauseCount += 1
    }

    func resume() {
        resumeCount += 1
    }

    func close() throws -> URL {
        closeCount += 1

        if let closeError {
            throw closeError
        }

        return url
    }
}

final class FakeMixdownExporter: MixdownExporting {
    var exportError: RecorderError?
    private(set) var requestedSystemAudioURL: URL?
    private(set) var requestedMicrophoneURL: URL?
    private(set) var requestedDestinationURL: URL?

    func export(
        systemAudioURL: URL?,
        microphoneURL: URL?,
        destinationURL: URL
    ) async throws -> URL {
        requestedSystemAudioURL = systemAudioURL
        requestedMicrophoneURL = microphoneURL
        requestedDestinationURL = destinationURL

        if let exportError {
            throw exportError
        }

        return destinationURL
    }
}
