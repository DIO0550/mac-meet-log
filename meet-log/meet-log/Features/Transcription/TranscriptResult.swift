import Foundation

struct TranscriptResult: Equatable, Sendable {
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

struct TranscriptSegment: Equatable, Sendable {
    let text: String
    let timestamp: TimeInterval
    let duration: TimeInterval

    nonisolated init(text: String, timestamp: TimeInterval, duration: TimeInterval) {
        self.text = text
        self.timestamp = timestamp
        self.duration = duration
    }
}
