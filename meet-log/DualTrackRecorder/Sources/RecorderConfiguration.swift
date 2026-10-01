import Foundation

public struct RecorderConfiguration: Equatable, Sendable {
    public static let `default` = RecorderConfiguration()

    public let outputDirectory: URL
    public let fileNamePrefix: String
    public let screenCaptureVideo: ScreenCaptureVideoConfiguration

    public init(
        outputDirectory: URL = RecordingStorage.defaultOutputDirectoryURL,
        fileNamePrefix: String = "Meet Log",
        screenCaptureVideo: ScreenCaptureVideoConfiguration = .default
    ) {
        self.outputDirectory = outputDirectory
        self.fileNamePrefix = fileNamePrefix
        self.screenCaptureVideo = screenCaptureVideo
    }
}
