import CryptoKit
import Foundation

nonisolated enum TranscriptSpeaker: String, Codable, Equatable, Sendable {
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

nonisolated struct TranscriptResult: Codable, Equatable, Sendable {
    let text: String
    let localeIdentifier: String
    let sourceURL: URL
    let segments: [TranscriptSegment]
    let screenSegments: [ScreenTranscriptSegment]
    let screenOCRReport: ScreenOCRReport?

    nonisolated init(
        text: String,
        localeIdentifier: String,
        sourceURL: URL,
        segments: [TranscriptSegment] = [],
        screenSegments: [ScreenTranscriptSegment] = [],
        screenOCRReport: ScreenOCRReport? = nil
    ) {
        self.text = text
        self.localeIdentifier = localeIdentifier
        self.sourceURL = sourceURL
        self.segments = segments
        self.screenSegments = screenSegments
        self.screenOCRReport = screenOCRReport
    }

    private enum CodingKeys: String, CodingKey {
        case text, localeIdentifier, sourceURL, segments, screenSegments, screenOCRReport
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decode(String.self, forKey: .text)
        localeIdentifier = try values.decode(String.self, forKey: .localeIdentifier)
        sourceURL = try values.decode(URL.self, forKey: .sourceURL)
        segments = try values.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        screenSegments = try values.decodeIfPresent([ScreenTranscriptSegment].self, forKey: .screenSegments) ?? []
        screenOCRReport = try values.decodeIfPresent(ScreenOCRReport.self, forKey: .screenOCRReport)
    }

    var summaryInputFingerprint: String {
        SHA256.hash(data: Data(summaryInputText.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    nonisolated func retainingScreen(from previous: TranscriptResult?) -> TranscriptResult {
        TranscriptResult(
            text: text, localeIdentifier: localeIdentifier, sourceURL: sourceURL,
            segments: segments, screenSegments: previous?.screenSegments ?? [],
            screenOCRReport: previous?.screenOCRReport
        )
    }

    var screenText: String {
        screenSegments.map { "[画面 OCR \($0.timeRangeText)] \($0.text)" }.joined(separator: "\n")
    }

    var summaryInputText: String {
        guard !screenSegments.isEmpty else {
            return text
        }
        return "[音声]\n\(text)\n\n[画面 OCR・補助情報]\n\(screenText)"
    }
}

nonisolated struct TranscriptSegment: Codable, Equatable, Sendable {
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
        guard time.isFinite, time < Double(Int.max) else {
            return "--:--"
        }
        let totalSeconds = Int(max(0, time))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%02d:%02d", minutes, seconds)
    }
}
