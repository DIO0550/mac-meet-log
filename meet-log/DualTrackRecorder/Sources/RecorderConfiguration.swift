import Foundation

public struct RecorderConfiguration: Equatable, Sendable {
    public static let `default` = RecorderConfiguration()

    public let outputDirectory: URL
    public let fileNamePrefix: String

    public init(
        outputDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music", isDirectory: true)
            .appendingPathComponent("meet-log", isDirectory: true),
        fileNamePrefix: String = "Meet Log"
    ) {
        self.outputDirectory = outputDirectory
        self.fileNamePrefix = fileNamePrefix
    }
}
