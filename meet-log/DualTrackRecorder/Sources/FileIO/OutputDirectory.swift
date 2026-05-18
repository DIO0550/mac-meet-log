import Foundation

struct OutputDirectory {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Music", isDirectory: true)
        .appendingPathComponent("meet-log", isDirectory: true)

    let url: URL
    private let fileManager: FileManager

    init(url: URL = Self.defaultURL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    func prepare() throws -> URL {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            throw RecorderError.outputFailed("Could not create output directory: \(error.localizedDescription)")
        }
    }

    func fileSet(for date: Date) throws -> OutputFileSet {
        let directory = try prepare()
        let timestamp = Self.timestampFormatter.string(from: date)

        return OutputFileSet(
            systemAudioURL: directory.appendingPathComponent("\(timestamp)_system.m4a", isDirectory: false),
            microphoneURL: directory.appendingPathComponent("\(timestamp)_microphone.m4a", isDirectory: false),
            mixdownURL: directory.appendingPathComponent("\(timestamp)_mix.m4a", isDirectory: false),
            displayFileName: "\(timestamp)_mix.m4a"
        )
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()
}

struct OutputFileSet: Equatable, Sendable {
    let systemAudioURL: URL
    let microphoneURL: URL
    let mixdownURL: URL
    let displayFileName: String
}
