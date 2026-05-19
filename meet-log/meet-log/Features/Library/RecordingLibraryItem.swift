import Foundation

struct RecordingLibraryItem: Equatable, Identifiable, Sendable {
    enum TrackKind: String, CaseIterable, Sendable {
        case mixdown = "mix"
        case systemAudio = "system"
        case microphone
    }

    let id: String
    let title: String
    let createdAt: Date
    let duration: Duration?
    let mixdownURL: URL
    let systemAudioURL: URL?
    let microphoneURL: URL?
    let fileExistence: RecordingLibraryFileExistence

    var dateText: String {
        Self.dateFormatter.string(from: createdAt)
    }

    var durationText: String {
        guard let duration else {
            return "Unknown length"
        }

        return duration.libraryDisplayString
    }

    var sourceSummary: String {
        switch (systemAudioURL != nil, microphoneURL != nil) {
        case (true, true):
            return "System audio + microphone"
        case (true, false):
            return "System audio only"
        case (false, true):
            return "Microphone only"
        case (false, false):
            return "Mixdown only"
        }
    }

    var hasMissingFiles: Bool {
        !fileExistence.mixdownExists
            || (systemAudioURL != nil && !fileExistence.systemAudioExists)
            || (microphoneURL != nil && !fileExistence.microphoneExists)
    }

    init(
        id: String,
        title: String,
        createdAt: Date,
        duration: Duration?,
        mixdownURL: URL,
        systemAudioURL: URL?,
        microphoneURL: URL?,
        fileExistence: RecordingLibraryFileExistence
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.mixdownURL = mixdownURL
        self.systemAudioURL = systemAudioURL
        self.microphoneURL = microphoneURL
        self.fileExistence = fileExistence
    }

    init?(
        mixdownURL: URL,
        directoryContents: Set<String>,
        fileManager: FileManager = .default,
        durationProvider: RecordingDurationProviding = AVRecordingDurationProvider()
    ) {
        guard let stem = Self.mixdownStem(from: mixdownURL) else {
            return nil
        }

        let systemAudioURL = Self.optionalTrackURL(
            stem: stem,
            kind: .systemAudio,
            directoryURL: mixdownURL.deletingLastPathComponent(),
            directoryContents: directoryContents
        )
        let microphoneURL = Self.optionalTrackURL(
            stem: stem,
            kind: .microphone,
            directoryURL: mixdownURL.deletingLastPathComponent(),
            directoryContents: directoryContents
        )
        let createdAt = Self.date(from: stem)
            ?? ((try? fileManager.attributesOfItem(atPath: mixdownURL.path)[.creationDate] as? Date) ?? .now)
        let existence = RecordingLibraryFileExistence(
            mixdownExists: fileManager.fileExists(atPath: mixdownURL.path),
            systemAudioExists: systemAudioURL.map { fileManager.fileExists(atPath: $0.path) } ?? false,
            microphoneExists: microphoneURL.map { fileManager.fileExists(atPath: $0.path) } ?? false
        )

        self.init(
            id: stem,
            title: Self.title(from: stem),
            createdAt: createdAt,
            duration: durationProvider.duration(for: mixdownURL),
            mixdownURL: mixdownURL,
            systemAudioURL: systemAudioURL,
            microphoneURL: microphoneURL,
            fileExistence: existence
        )
    }

    static func mixdownStem(from url: URL) -> String? {
        let fileName = url.lastPathComponent
        guard fileName.hasSuffix("_\(TrackKind.mixdown.rawValue).m4a") else {
            return nil
        }

        return String(fileName.dropLast("_\(TrackKind.mixdown.rawValue).m4a".count))
    }

    private static func optionalTrackURL(
        stem: String,
        kind: TrackKind,
        directoryURL: URL,
        directoryContents: Set<String>
    ) -> URL? {
        let fileName = "\(stem)_\(kind.rawValue).m4a"
        guard directoryContents.contains(fileName) else {
            return nil
        }

        return directoryURL.appendingPathComponent(fileName, isDirectory: false)
    }

    private static func date(from stem: String) -> Date? {
        timestampFormatter.date(from: stem)
    }

    private static func title(from stem: String) -> String {
        guard let date = date(from: stem) else {
            return stem
        }

        return "Recording \(titleFormatter.string(from: date))"
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

struct RecordingLibraryFileExistence: Equatable, Sendable {
    let mixdownExists: Bool
    let systemAudioExists: Bool
    let microphoneExists: Bool
}

protocol RecordingDurationProviding: Sendable {
    func duration(for url: URL) -> Duration?
}

extension Duration {
    var libraryDisplayString: String {
        let totalSeconds = max(0, Int(components.seconds))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d hr %02d min", hours, minutes)
        }

        if minutes > 0 {
            return String(format: "%d min %02d sec", minutes, seconds)
        }

        return String(format: "%d sec", seconds)
    }
}
