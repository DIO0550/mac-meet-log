import Foundation

/// Small atomic checkpoint; media and notes are stored independently beside it.
public struct RecordingJournal: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case recording, paused, finalizing, finalized }
    public static let fileName = "session.json"
    public static let completionFileName = "session-complete"
    public let id: UUID
    public let startedAt: Date
    public let stem: String
    public let systemAudioEnabled: Bool
    public let microphoneEnabled: Bool
    public let screenCaptureEnabled: Bool
    public var elapsed: TimeInterval
    public var updatedAt: Date
    public var phase: Phase

    public init(startedAt: Date, stem: String, sources: RecordingSources) {
        id = UUID()
        self.startedAt = startedAt
        self.stem = stem
        systemAudioEnabled = sources.systemAudioEnabled
        microphoneEnabled = sources.microphoneEnabled
        screenCaptureEnabled = sources.screenCaptureEnabled
        elapsed = 0
        updatedAt = startedAt
        phase = .recording
    }

    public func save(in directory: URL) throws {
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    public static func load(in directory: URL) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent(fileName)))
        guard value.elapsed.isFinite, value.elapsed >= 0, !value.stem.isEmpty,
              value.stem != ".", value.stem != "..", !value.stem.contains("/"), !value.stem.contains("\\") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }

    public static func markComplete(in directory: URL) throws {
        try Data().write(to: directory.appendingPathComponent(completionFileName), options: .atomic)
    }
}
