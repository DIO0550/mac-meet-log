import Foundation

struct RecorderDependencies {
    var outputDirectoryFactory: (URL) -> OutputDirectory
    var writerFactory: (RecordingTrack, URL) throws -> any TrackWriting
    var microphoneCaptureFactory: (@escaping AudioBufferHandler) -> any AudioCapture
    var systemAudioCaptureFactory: (@escaping AudioBufferHandler) -> any AudioCapture
    var mixdownExporter: any MixdownExporting

    static let live = RecorderDependencies(
        outputDirectoryFactory: { OutputDirectory(url: $0) },
        writerFactory: { _, url in TrackFileWriter(url: url) },
        microphoneCaptureFactory: { MicrophoneCapture(bufferHandler: $0) },
        systemAudioCaptureFactory: { SystemAudioTap(bufferHandler: $0) },
        mixdownExporter: MixdownExporter()
    )
}
