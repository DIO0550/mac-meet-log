import Foundation

struct RecordingLibraryItem: Equatable, Identifiable, Sendable {
    enum TrackKind: String, CaseIterable, Sendable {
        case mixdown = "mix"
        case systemAudio = "system"
        case microphone
    }

    enum MixdownStatus: Equatable, Sendable {
        case mixed
        case needsMix
        case unavailable
    }

    let id: String
    let title: String
    let createdAt: Date
    let duration: Duration?
    let sessionDirectoryURL: URL
    let mixdownURL: URL
    let systemAudioURL: URL?
    let microphoneURL: URL?
    let fileExistence: RecordingLibraryFileExistence
    let mixdownStatus: MixdownStatus

    var dateText: String {
        Self.dateFormatter.string(from: createdAt)
    }

    var durationText: String {
        guard let duration else {
            return "Unknown length"
        }

        return duration.mediaDurationDisplayString
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
        mixdownStatus == .unavailable
            || (systemAudioURL != nil && !fileExistence.systemAudioExists)
            || (microphoneURL != nil && !fileExistence.microphoneExists)
    }

    var hasUsableMixdown: Bool {
        fileExistence.mixdownExists
    }

    var canRemix: Bool {
        mixdownStatus == .needsMix
    }

    var existingSystemAudioURL: URL? {
        guard fileExistence.systemAudioExists else {
            return nil
        }

        return systemAudioURL
    }

    var existingMicrophoneURL: URL? {
        guard fileExistence.microphoneExists else {
            return nil
        }

        return microphoneURL
    }

    init(
        id: String,
        title: String,
        createdAt: Date,
        duration: Duration?,
        mixdownURL: URL,
        systemAudioURL: URL?,
        microphoneURL: URL?,
        fileExistence: RecordingLibraryFileExistence,
        sessionDirectoryURL: URL? = nil,
        mixdownStatus: MixdownStatus? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.sessionDirectoryURL = sessionDirectoryURL ?? mixdownURL.deletingLastPathComponent()
        self.mixdownURL = mixdownURL
        self.systemAudioURL = systemAudioURL
        self.microphoneURL = microphoneURL
        self.fileExistence = fileExistence
        self.mixdownStatus = mixdownStatus ?? (fileExistence.mixdownExists ? .mixed : .unavailable)
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

        self.init(
            stem: stem,
            directoryURL: mixdownURL.deletingLastPathComponent(),
            directoryContents: directoryContents,
            fileManager: fileManager,
            durationProvider: durationProvider
        )
    }

    init?(
        stem: String,
        directoryURL: URL,
        directoryContents: Set<String>,
        fileManager: FileManager = .default,
        durationProvider: RecordingDurationProviding = AVRecordingDurationProvider()
    ) {
        let mixdownURL = directoryURL.appendingPathComponent(
            "\(stem)_\(TrackKind.mixdown.rawValue).m4a",
            isDirectory: false
        )
        let systemAudioURL = Self.optionalTrackURL(
            stem: stem,
            kind: .systemAudio,
            directoryURL: directoryURL,
            directoryContents: directoryContents
        )
        let microphoneURL = Self.optionalTrackURL(
            stem: stem,
            kind: .microphone,
            directoryURL: directoryURL,
            directoryContents: directoryContents
        )
        let mixdownExists = directoryContents.contains("\(stem)_\(TrackKind.mixdown.rawValue).m4a")
            && fileManager.fileExists(atPath: mixdownURL.path)
        let systemAudioExists = systemAudioURL.map { fileManager.fileExists(atPath: $0.path) } ?? false
        let microphoneExists = microphoneURL.map { fileManager.fileExists(atPath: $0.path) } ?? false

        guard mixdownExists || systemAudioExists || microphoneExists else {
            return nil
        }

        let createdAt = Self.date(from: stem)
            ?? ((try? fileManager.attributesOfItem(atPath: mixdownURL.path)[.creationDate] as? Date) ?? .now)
        let existence = RecordingLibraryFileExistence(
            mixdownExists: mixdownExists,
            systemAudioExists: systemAudioExists,
            microphoneExists: microphoneExists
        )
        let durationURL = mixdownExists
            ? mixdownURL
            : (systemAudioURL ?? microphoneURL)

        self.init(
            id: stem,
            title: Self.title(from: stem),
            createdAt: createdAt,
            duration: durationURL.flatMap { durationProvider.duration(for: $0) },
            mixdownURL: mixdownURL,
            systemAudioURL: systemAudioURL,
            microphoneURL: microphoneURL,
            fileExistence: existence,
            sessionDirectoryURL: directoryURL,
            mixdownStatus: mixdownExists ? .mixed : .needsMix
        )
    }

    static func mixdownStem(from url: URL) -> String? {
        stem(fromFileName: url.lastPathComponent, kind: .mixdown)
    }

    static func stem(fromFileName fileName: String, kind: TrackKind) -> String? {
        let suffix = "_\(kind.rawValue).m4a"
        guard fileName.hasSuffix(suffix) else {
            return nil
        }

        return String(fileName.dropLast(suffix.count))
    }

    static func stem(fromFileName fileName: String) -> String? {
        for kind in TrackKind.allCases {
            if let stem = stem(fromFileName: fileName, kind: kind) {
                return stem
            }
        }

        return nil
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
