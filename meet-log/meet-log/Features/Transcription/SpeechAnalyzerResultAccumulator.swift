import CoreMedia
import Foundation

/// Stores Apple's finalized result ranges, without inferring utterance or speaker boundaries.
nonisolated struct SpeechAnalyzerResultAccumulator {
    private var segments: [TranscriptSegment] = []
    private var finalizedRanges = Set<FinalizedRange>()

    @discardableResult
    mutating func consume(
        text: String,
        range: CMTimeRange,
        isFinal: Bool
    ) throws -> TranscriptionEvent? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }

        // Volatile results can replace each other; none enter the saved transcript.
        guard isFinal else {
            return .partial(text)
        }

        let timestamp = range.start.seconds
        let duration = range.duration.seconds
        guard range.isValid, timestamp.isFinite, duration.isFinite,
              timestamp >= 0, duration >= 0, (timestamp + duration).isFinite else {
            throw TranscriptionError.recognitionFailed("確定した文字起こしの時刻情報を取得できませんでした。")
        }

        // Final results are immutable. Repeated delivery of the same range keeps
        // its first final value; identical words at different times remain distinct.
        let key = FinalizedRange(timestamp: timestamp, duration: duration)
        guard finalizedRanges.insert(key).inserted else {
            return nil
        }

        segments.append(TranscriptSegment(text: text, timestamp: timestamp, duration: duration))
        return nil
    }

    func transcript(localeIdentifier: String, sourceURL: URL) throws -> TranscriptResult {
        guard !segments.isEmpty else {
            throw TranscriptionError.emptyResult
        }

        let ordered = segments.sorted { $0.timestamp < $1.timestamp }
        return TranscriptResult(
            text: ordered.map(\.text).joined(separator: "\n"),
            localeIdentifier: localeIdentifier,
            sourceURL: sourceURL,
            segments: ordered
        )
    }

    private struct FinalizedRange: Hashable {
        let timestamp: TimeInterval
        let duration: TimeInterval
    }
}
