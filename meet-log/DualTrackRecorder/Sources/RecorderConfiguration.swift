import Foundation

public struct RecorderConfiguration: Equatable, Sendable {
    public static let `default` = RecorderConfiguration()

    public let outputDirectory: URL
    public let fileNamePrefix: String

    public init(
        outputDirectory: URL = RecordingStorage.defaultOutputDirectoryURL,
        fileNamePrefix: String = "Meet Log"
    ) {
        self.outputDirectory = outputDirectory
        self.fileNamePrefix = fileNamePrefix
    }
}
