import Foundation

nonisolated struct RecordingNote: Codable, Equatable, Identifiable, Sendable {
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

    @MainActor var timestamp: String {
        guard elapsed.isFinite, elapsed >= 0, elapsed < Double(Int64.max) else {
            return "--:--"
        }
        return Duration.seconds(elapsed).recorderDisplayString
    }
}
