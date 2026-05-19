import Foundation

struct RecorderDependencies {
    var outputDirectoryFactory: (URL) -> OutputDirectory
    var writerFactory: (RecordingTrack, URL) throws -> any TrackWriting
    var microphoneCaptureFactory: (MicrophoneInputDeviceSelection, @escaping AudioBufferHandler) -> any AudioCapture
    var systemAudioCaptureFactory: (@escaping AudioBufferHandler) -> any AudioCapture
    var microphoneDeviceProvider: any MicrophoneDeviceProviding
    var mixdownExporter: any MixdownExporting

    static let live = RecorderDependencies(
        outputDirectoryFactory: { OutputDirectory(url: $0) },
        writerFactory: { _, url in TrackFileWriter(url: url) },
        microphoneCaptureFactory: { selection, handler in
            MicrophoneCapture(deviceSelection: selection, bufferHandler: handler)
        },
        systemAudioCaptureFactory: { SystemAudioTap(bufferHandler: $0) },
        microphoneDeviceProvider: CoreAudioMicrophoneDeviceProvider(),
        mixdownExporter: MixdownExporter()
    )
}
