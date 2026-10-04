import Foundation

struct RecordingLibraryItem: Equatable, Identifiable, Sendable {
    enum TrackKind: String, CaseIterable, Sendable {
        case mixdown = "mix"
        case systemAudio = "system"
        case microphone
        case screen

        var fileExtension: String {
            switch self {
            case .screen:
                "mp4"
            case .mixdown, .systemAudio, .microphone:
                "m4a"
            }
        }
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
    let screenCaptureURL: URL?
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
        if !hasTranscribableAudio, screenCaptureURL == nil { return "Notes only" }
        if systemAudioURL == nil, microphoneURL == nil, screenCaptureURL != nil {
            if fileExistence.mixdownExists {
                return "Mixdown + screen"
            }
            return "Screen only"
        }

        let audioSummary = switch (systemAudioURL != nil, microphoneURL != nil) {
        case (true, true):
            "System audio + microphone"
        case (true, false):
            "System audio only"
        case (false, true):
            "Microphone only"
        case (false, false):
            "Mixdown only"
        }
        if screenCaptureURL != nil {
            return "\(audioSummary) + screen"
        }

        return audioSummary
    }

    var hasMissingFiles: Bool {
        mixdownStatus == .unavailable
            || (systemAudioURL != nil && !fileExistence.systemAudioExists)
            || (microphoneURL != nil && !fileExistence.microphoneExists)
            || (screenCaptureURL != nil && !fileExistence.screenCaptureExists)
    }

    var hasUsableMixdown: Bool {
        fileExistence.mixdownExists
    }

    var hasTranscribableAudio: Bool {
        fileExistence.mixdownExists || fileExistence.systemAudioExists || fileExistence.microphoneExists
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

    var existingScreenCaptureURL: URL? {
        guard fileExistence.screenCaptureExists else {
            return nil
        }

        return screenCaptureURL
    }

    init(
        id: String,
        title: String,
        createdAt: Date,
        duration: Duration?,
        mixdownURL: URL,
        systemAudioURL: URL?,
        microphoneURL: URL?,
        screenCaptureURL: URL? = nil,
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
        self.screenCaptureURL = screenCaptureURL
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
        let screenCaptureURL = Self.optionalTrackURL(
            stem: stem,
            kind: .screen,
            directoryURL: directoryURL,
            directoryContents: directoryContents
        )
        let mixdownExists = directoryContents.contains("\(stem)_\(TrackKind.mixdown.rawValue).m4a")
            && fileManager.fileExists(atPath: mixdownURL.path)
        let systemAudioExists = systemAudioURL.map { fileManager.fileExists(atPath: $0.path) } ?? false
        let microphoneExists = microphoneURL.map { fileManager.fileExists(atPath: $0.path) } ?? false
        let screenCaptureExists = screenCaptureURL.map { fileManager.fileExists(atPath: $0.path) } ?? false

        let hasRecoveredNotes = directoryContents.contains("recovery-report.json") && directoryContents.contains("\(stem)_notes.json")
        guard mixdownExists || systemAudioExists || microphoneExists || screenCaptureExists || hasRecoveredNotes else {
            return nil
        }

        let existence = RecordingLibraryFileExistence(
            mixdownExists: mixdownExists,
            systemAudioExists: systemAudioExists,
            microphoneExists: microphoneExists,
            screenCaptureExists: screenCaptureExists
        )
        let durationURL = mixdownExists
            ? mixdownURL
            : (systemAudioURL ?? microphoneURL ?? screenCaptureURL)
        let createdAt = Self.date(from: stem)
            ?? durationURL.flatMap { try? fileManager.attributesOfItem(atPath: $0.path)[.creationDate] as? Date }
            ?? .now

        self.init(
            id: (try? RecordingRecoveryStore.loadReport(in: directoryURL)).map { "recovered-\($0.sessionID.uuidString)" } ?? stem,
            title: Self.title(from: stem),
            createdAt: createdAt,
            duration: durationURL.flatMap { durationProvider.duration(for: $0) },
            mixdownURL: mixdownURL,
            systemAudioURL: systemAudioURL,
            microphoneURL: microphoneURL,
            screenCaptureURL: screenCaptureURL,
            fileExistence: existence,
            sessionDirectoryURL: directoryURL,
            mixdownStatus: Self.mixdownStatus(
                mixdownExists: mixdownExists,
                systemAudioExists: systemAudioExists,
                microphoneExists: microphoneExists
            )
        )
    }

    static func mixdownStem(from url: URL) -> String? {
        stem(fromFileName: url.lastPathComponent, kind: .mixdown)
    }

    static func stem(fromFileName fileName: String, kind: TrackKind) -> String? {
        let suffix = "_\(kind.rawValue).\(kind.fileExtension)"
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
        let fileName = "\(stem)_\(kind.rawValue).\(kind.fileExtension)"
        guard directoryContents.contains(fileName) else {
            return nil
        }

        return directoryURL.appendingPathComponent(fileName, isDirectory: false)
    }

    private static func mixdownStatus(
        mixdownExists: Bool,
        systemAudioExists: Bool,
        microphoneExists: Bool
    ) -> MixdownStatus {
        if mixdownExists {
            return .mixed
        }

        if systemAudioExists || microphoneExists {
            return .needsMix
        }

        return .unavailable
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
    let screenCaptureExists: Bool

    init(
        mixdownExists: Bool,
        systemAudioExists: Bool,
        microphoneExists: Bool,
        screenCaptureExists: Bool = false
    ) {
        self.mixdownExists = mixdownExists
        self.systemAudioExists = systemAudioExists
        self.microphoneExists = microphoneExists
        self.screenCaptureExists = screenCaptureExists
    }
}

protocol RecordingDurationProviding: Sendable {
    func duration(for url: URL) -> Duration?
}
