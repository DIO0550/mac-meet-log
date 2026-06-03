import Foundation

public enum RecordingStorage {
    public static let applicationFolderName = "meet-log"
    public static let recordingsFolderName = "Recordings"

    public static var defaultOutputDirectoryURL: URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)

        return baseURL
            .appendingPathComponent(applicationFolderName, isDirectory: true)
            .appendingPathComponent(recordingsFolderName, isDirectory: true)
    }

    public static var defaultOutputDirectoryDisplayPath: String {
        "~/Library/Application Support/\(applicationFolderName)/\(recordingsFolderName)"
    }
}
