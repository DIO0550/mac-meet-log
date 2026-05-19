import AVFoundation
import Foundation
@testable import DualTrackRecorder

final class FakeRecorderHarness {
    let baseURL: URL
    private var microphoneCaptures = [FakeAudioCapture()]
    var systemAudioCapture = FakeAudioCapture()
    var microphoneDeviceProvider = FakeMicrophoneDeviceProvider(devices: AudioInputDevice.previewDevices)
    var mixdownExporter = FakeMixdownExporter()
    private(set) var requestedMicrophoneSelections: [MicrophoneInputDeviceSelection] = []
    private(set) var writers: [RecordingTrack: FakeTrackWriter] = [:]

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    var microphoneCapture: FakeAudioCapture {
        microphoneCaptures[0]
    }

    func enqueueMicrophoneCapture(_ capture: FakeAudioCapture) {
        microphoneCaptures.append(capture)
    }

    func microphoneCapture(at index: Int) -> FakeAudioCapture? {
        guard microphoneCaptures.indices.contains(index) else {
            return nil
        }

        return microphoneCaptures[index]
    }

    var dependencies: RecorderDependencies {
        RecorderDependencies(
            outputDirectoryFactory: { [baseURL] _ in OutputDirectory(url: baseURL) },
            writerFactory: { [weak self] track, url in
                let writer = FakeTrackWriter(url: url)
                self?.writers[track] = writer
                return writer
            },
            microphoneCaptureFactory: { [weak self] selection, _ in
                guard let self else {
                    return FakeAudioCapture()
                }

                let index = self.requestedMicrophoneSelections.count
                self.requestedMicrophoneSelections.append(selection)

                if self.microphoneCaptures.indices.contains(index) {
                    return self.microphoneCaptures[index]
                }

                let capture = FakeAudioCapture()
                self.microphoneCaptures.append(capture)
                return capture
            },
            systemAudioCaptureFactory: { [systemAudioCapture] _ in systemAudioCapture },
            microphoneDeviceProvider: microphoneDeviceProvider,
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

final class FakeMicrophoneDeviceProvider: MicrophoneDeviceProviding, @unchecked Sendable {
    var devicesResult: Result<[AudioInputDevice], RecorderError>
    private var continuation: AsyncStream<[AudioInputDevice]>.Continuation?

    init(devices: [AudioInputDevice]) {
        self.devicesResult = .success(devices)
    }

    func devices() throws -> [AudioInputDevice] {
        try devicesResult.get()
    }

    func deviceChanges() -> AsyncStream<[AudioInputDevice]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.continuation = continuation

            if case let .success(devices) = devicesResult {
                continuation.yield(devices)
            }
        }
    }

    func send(_ devices: [AudioInputDevice]) {
        devicesResult = .success(devices)
        continuation?.yield(devices)
    }
}
