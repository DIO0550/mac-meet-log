import Foundation

struct RecordingNote: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let elapsed: TimeInterval
    var text: String
    let createdAt: Date

    init(id: UUID = UUID(), elapsed: TimeInterval, text: String, createdAt: Date = .now) {
        self.id = id
        self.elapsed = elapsed
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
    }

    var timestamp: String {
        Duration.seconds(elapsed).recorderDisplayString
    }
}
