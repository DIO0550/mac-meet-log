import CoreMedia
import Foundation
import Testing
@testable import meet_log

struct SpeechAnalyzerResultTests {
    private let sourceURL = URL(fileURLWithPath: "/tmp/analyzer.m4a")

    @Test func finalResultsKeepFractionalTimesGapsAndChronologicalText() throws {
        var accumulator = SpeechAnalyzerResultAccumulator()
        try accumulator.consume(text: " 後の発言\n", range: range(start: 25, duration: 6), isFinal: true)
        try accumulator.consume(text: "最初の発言", range: range(start: 5, duration: 7), isFinal: true)
        let result = try accumulator.transcript(localeIdentifier: "ja-JP", sourceURL: sourceURL)

        #expect(result.text == "最初の発言\n後の発言")
        #expect(result.segments == [
            TranscriptSegment(text: "最初の発言", timestamp: 1.25, duration: 1.75),
            TranscriptSegment(text: "後の発言", timestamp: 6.25, duration: 1.5)
        ])
        #expect(result.localeIdentifier == "ja-JP")
        #expect(result.sourceURL == sourceURL)
        #expect(result.participants.isEmpty)
    }

    @Test func volatileReplacementsAndTrailingPartialNeverBecomeSavedSegments() throws {
        var accumulator = SpeechAnalyzerResultAccumulator()
        let first = try accumulator.consume(text: " 途中 ", range: range(start: 0, duration: 4), isFinal: false)
        let replacement = try accumulator.consume(text: "更新した途中", range: range(start: 0, duration: 8), isFinal: false)
        #expect(partialText(first) == "途中")
        #expect(partialText(replacement) == "更新した途中")
        try accumulator.consume(text: "確定", range: range(start: 0, duration: 10), isFinal: true)
        try accumulator.consume(text: "未確定の末尾", range: range(start: 10, duration: 3), isFinal: false)
        let result = try accumulator.transcript(localeIdentifier: "ja-JP", sourceURL: sourceURL)

        #expect(result.text == "確定")
        #expect(result.segments == [TranscriptSegment(text: "確定", timestamp: 0, duration: 2.5)])
    }

    @Test func duplicateFinalRangesKeepFirstValueButRepeatedWordsAtOtherTimesRemain() throws {
        var accumulator = SpeechAnalyzerResultAccumulator()
        let firstRange = range(start: 4, duration: 4)
        try accumulator.consume(text: "はい", range: firstRange, isFinal: true)
        try accumulator.consume(text: "はい", range: firstRange, isFinal: true)
        // Equivalent CMTime values with another timescale are the same audio range.
        try accumulator.consume(text: "置換しない", range: CMTimeRange(
            start: CMTime(value: 8, timescale: 8), duration: CMTime(value: 8, timescale: 8)
        ), isFinal: true)
        try accumulator.consume(text: "はい", range: range(start: 12, duration: 4), isFinal: true)
        let result = try accumulator.transcript(localeIdentifier: "ja-JP", sourceURL: sourceURL)

        #expect(result.text == "はい\nはい")
        #expect(result.segments.map(\.timestamp) == [1, 3])
        #expect(result.segments.map(\.duration) == [1, 1])
    }

    @Test func partialOnlyAndEmptyFinalResultsStillFailWithEmptyResult() throws {
        var accumulator = SpeechAnalyzerResultAccumulator()
        try accumulator.consume(text: "途中", range: range(start: 0, duration: 4), isFinal: false)
        try accumulator.consume(text: " \n ", range: .invalid, isFinal: true)
        #expect(throws: TranscriptionError.emptyResult) {
            try accumulator.transcript(localeIdentifier: "ja-JP", sourceURL: sourceURL)
        }
    }

    @Test(arguments: 0..<6)
    func invalidFinalRangesFailWithoutInventingTiming(index: Int) {
        let invalidRanges: [CMTimeRange] = [
            .invalid,
            CMTimeRange(start: .indefinite, duration: CMTime(value: 1, timescale: 1)),
            CMTimeRange(start: .positiveInfinity, duration: CMTime(value: 1, timescale: 1)),
            CMTimeRange(start: .zero, duration: .positiveInfinity),
            range(start: -1, duration: 4),
            range(start: 0, duration: -1)
        ]
        var accumulator = SpeechAnalyzerResultAccumulator()
        #expect(throws: TranscriptionError.self) {
            try accumulator.consume(text: "確定", range: invalidRanges[index], isFinal: true)
        }
        #expect(throws: TranscriptionError.emptyResult) {
            try accumulator.transcript(localeIdentifier: "ja-JP", sourceURL: sourceURL)
        }
    }

    @Test func timedResultsReachTrackMergeManualNamesPlaybackAndEvidence() async throws {
        let systemURL = URL(fileURLWithPath: "/tmp/system.m4a")
        let microphoneURL = URL(fileURLWithPath: "/tmp/microphone.m4a")
        let system = try transcript(url: systemURL, results: [
            ("最初", range(start: 5, duration: 7)),
            ("次の参加者", range(start: 25, duration: 6))
        ])
        let microphone = try transcript(url: microphoneURL, results: [
            ("自分の返答", range(start: 16, duration: 3))
        ])
        let service = TrackAwareTranscriptionService(service: TimedTranscriptService(transcripts: [
            systemURL: system, microphoneURL: microphone
        ]))
        let merged = try await service.finalTranscript(
            systemAudioURL: systemURL, microphoneURL: microphoneURL, fallbackURL: sourceURL
        )

        #expect(merged.segments.map(\.timestamp) == [1.25, 4, 6.25])
        #expect(merged.segments.map(\.duration) == [1.75, 0.75, 1.5])
        #expect(merged.segments.map(\.speaker) == [.other, .me, .other])
        #expect(merged.text == "相手: 最初\n自分: 自分の返答\n相手: 次の参加者")

        var draft = MeetingEditDraft(transcript: merged)
        draft.addParticipant(named: "山田")
        draft.addParticipant(named: "佐藤")
        draft.assignParticipant(draft.participants[0].id, to: [0])
        draft.assignParticipant(draft.participants[1].id, to: [2])
        let edited = try #require(draft.editedTranscript())
        #expect(edited.audioText == "山田: 最初\n自分: 自分の返答\n佐藤: 次の参加者")
        #expect(edited.segments.map(\.speaker) == merged.segments.map(\.speaker))
        #expect(edited.segments.map(\.timestamp) == merged.segments.map(\.timestamp))
        #expect(edited.segments.map(\.duration) == merged.segments.map(\.duration))
        let reloaded = try TranscriptMarkdownCodec.decode(TranscriptMarkdownCodec.encode(edited, recordingID: "analyzer"))
        #expect(reloaded == edited)
        #expect(reloaded.segments[2].timeRangeText == "00:06–00:07")
        #expect(PlaybackTimeline.position(reloaded.segments[2].timestamp, duration: 30) == 6.25)
        let evidence = SummaryEvidenceCatalog(reloaded)
        #expect(evidence.entries.map(\.timestamp) == [1.25, 4, 6.25])
        #expect(evidence.entries.map(\.duration) == [1.75, 0.75, 1.5])
        #expect(evidence.entries.map(\.speakerName) == ["山田", "自分", "佐藤"])
        #expect(SummaryEvidenceCatalog.modelInput(reloaded).contains("音声 00:06–00:07] 佐藤: 次の参加者"))
    }

    @Test func singleAudioImportRetainsTimedSegmentsWithoutSourceOrParticipantLabels() async throws {
        let input = try transcript(url: sourceURL, results: [
            ("前半", range(start: 4, duration: 3)),
            ("後半", range(start: 12, duration: 5))
        ])
        let service = TrackAwareTranscriptionService(service: TimedTranscriptService(transcripts: [sourceURL: input]))
        let imported = try await service.finalTranscript(
            systemAudioURL: nil, microphoneURL: nil, fallbackURL: sourceURL
        )

        #expect(imported == input)
        #expect(imported.segments.count == 2)
        #expect(imported.segments.allSatisfy { $0.speaker == nil && $0.participantID == nil })
        #expect(try JSONDecoder().decode(TranscriptResult.self, from: JSONEncoder().encode(imported)) == imported)
        #expect(try TranscriptMarkdownCodec.decode(TranscriptMarkdownCodec.encode(imported, recordingID: "import")) == imported)
        #expect(SummaryEvidenceCatalog(imported).entries.map(\.timestamp) == [1, 3])
    }

    @Test func oldTranscriptWithoutSegmentsStillDecodesWithoutInventingRanges() throws {
        let json = """
        {"text":"旧データ","localeIdentifier":"ja-JP","sourceURL":"file:///tmp/old.m4a"}
        """
        let old = try JSONDecoder().decode(TranscriptResult.self, from: Data(json.utf8))

        #expect(old.text == "旧データ")
        #expect(old.segments.isEmpty)
        #expect(old.participants.isEmpty)
        #expect(MeetingEditDraft(transcript: old).editedTranscript() == old)
        #expect(SummaryEvidenceCatalog(old).entries.isEmpty)
        #expect(try TranscriptMarkdownCodec.decode(TranscriptMarkdownCodec.encode(old, recordingID: "old")) == old)
    }

    private func partialText(_ event: TranscriptionEvent?) -> String? {
        guard case .partial(let text)? = event else {
            return nil
        }
        return text
    }

    private func range(start: Int64, duration: Int64) -> CMTimeRange {
        CMTimeRange(start: CMTime(value: start, timescale: 4), duration: CMTime(value: duration, timescale: 4))
    }

    private func transcript(url: URL, results: [(String, CMTimeRange)]) throws -> TranscriptResult {
        var accumulator = SpeechAnalyzerResultAccumulator()
        for (text, range) in results {
            try accumulator.consume(text: text, range: range, isFinal: true)
        }
        return try accumulator.transcript(localeIdentifier: "ja-JP", sourceURL: url)
    }
}

private struct TimedTranscriptService: AudioTranscriptionService {
    let transcripts: [URL: TranscriptResult]

    func transcribe(audioURL: URL, locale: Locale) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let transcript = transcripts[audioURL] else {
                continuation.finish(throwing: TranscriptionError.transcriptionIncomplete)
                return
            }
            continuation.yield(.completed(transcript))
            continuation.finish()
        }
    }
}
