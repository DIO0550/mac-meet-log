import Foundation

enum TranscriptSpeaker: String, Codable, Equatable, Sendable {
    case me
    case other

    var displayName: String {
        switch self {
        case .me:
            return "自分"
        case .other:
            return "相手"
        }
    }
}

struct TranscriptResult: Codable, Equatable, Sendable {
    let text: String
    let localeIdentifier: String
    let sourceURL: URL
    let segments: [TranscriptSegment]

    nonisolated init(
        text: String,
        localeIdentifier: String,
        sourceURL: URL,
        segments: [TranscriptSegment] = []
    ) {
        self.text = text
        self.localeIdentifier = localeIdentifier
        self.sourceURL = sourceURL
        self.segments = segments
    }
}

struct TranscriptSegment: Codable, Equatable, Sendable {
    let text: String
    let timestamp: TimeInterval
    let duration: TimeInterval
    let speaker: TranscriptSpeaker?

    nonisolated init(
        text: String,
        timestamp: TimeInterval,
        duration: TimeInterval,
        speaker: TranscriptSpeaker? = nil
    ) {
        self.text = text
        self.timestamp = timestamp
        self.duration = duration
        self.speaker = speaker
    }

    var timeRangeText: String {
        "\(Self.timeText(timestamp))–\(Self.timeText(timestamp + duration))"
    }

    nonisolated private static func timeText(_ time: TimeInterval) -> String {
        let totalSeconds = max(0, Int(time))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%02d:%02d", minutes, seconds)
    }
}
