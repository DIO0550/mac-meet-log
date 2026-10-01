import Foundation
import Testing
@testable import meet_log

struct ChunkedSummaryTests {
    @Test func exactLimitUsesOneChunk() throws {
        #expect(try TranscriptChunker(characterLimit: 10).split("0123456789") == ["0123456789"])
    }

    @Test func prefersUtteranceBoundariesAndPreservesText() throws {
        let text = "alpha beta\ngamma delta\nomega"
        let chunks = try TranscriptChunker(characterLimit: 15).split(text)
        #expect(chunks == ["alpha beta\n", "gamma delta\n", "omega"])
        #expect(chunks.joined() == text)
    }

    @Test func longSentenceSplitsOnlyBetweenWords() throws {
        let text = String(repeating: "alpha beta gamma ", count: 100) + "end."
        let chunks = try TranscriptChunker(characterLimit: 40).split(text)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 40 })
        #expect(chunks.joined() == text)
        #expect(chunks.flatMap { $0.split(whereSeparator: \.isWhitespace) } == text.split(whereSeparator: \.isWhitespace))
    }

    @Test func japaneseSentencesAndEmojiRemainIntact() throws {
        let text = String(repeating: "今日は設計を確認します。次は実装を進めます。👨‍👩‍👧‍👦\n", count: 20)
        let chunks = try TranscriptChunker(characterLimit: 80).split(text)
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { $0.count <= 80 })
    }

    @Test func oversizedWordIsReportedWithoutTruncation() {
        #expect(throws: SummaryError.unsplittableWord(limit: 10)) {
            try TranscriptChunker(characterLimit: 10).split("abcdefghijklmnopqrstuvwxyz")
        }
    }

    @Test func shortTranscriptKeepsSingleGenerationAndOriginalResult() async throws {
        let generator = RecordingSummaryGenerator()
        let progress = SummaryProgressRecorder()
        let result = await service(generator: generator, limit: 200).summarize(transcript("短い本文")) {
            await progress.append($0)
        }
        guard case .summarized = result else {
            Issue.record("Expected a summary")
            return
        }
        #expect(await generator.inputs.count == 1)
        #expect(await generator.inputs.first?.text == "短い本文")
        #expect(await progress.values.isEmpty)
    }

    @Test func transcriptFarOverDefaultLimitCompletesAndReportsProgress() async throws {
        let generator = RecordingSummaryGenerator()
        let progress = SummaryProgressRecorder()
        let text = String(repeating: "今日の会議では設計と検証について確認しました。\n", count: 4_000)
        let result = await service(generator: generator).summarize(transcript(text)) { await progress.append($0) }
        guard case let .summarized(summary) = result else {
            Issue.record("Expected a summary, received \(result)")
            return
        }
        let inputs = await generator.inputs
        let events = await progress.values
        #expect(text.count > 72_000)
        #expect(inputs.allSatisfy { $0.text.count <= 24_000 })
        #expect(summary.transcriptSourceURL == sourceURL)
        guard case let .chunk(_, total) = try #require(events.first) else {
            Issue.record("Expected chunk progress")
            return
        }
        #expect(total > 3)
        #expect(inputs.prefix(total).map(\.text).joined() == text)
        #expect(events.contains(.chunk(completed: total, total: total)))
        #expect(events.last == .integration(round: 1, completed: 1, total: 1))
        #expect(await generator.prompts.last?.instructions.contains("横断して統合") == true)
    }

    @Test func integrationUsesMultipleBoundedRounds() async {
        let generator = RecordingSummaryGenerator()
        let progress = SummaryProgressRecorder()
        let text = String(repeating: "This is a sentence about the project.\n", count: 100)
        let result = await service(generator: generator, limit: 180).summarize(transcript(text)) { await progress.append($0) }
        guard case .summarized = result else {
            Issue.record("Expected hierarchical integration, received \(result)")
            return
        }
        #expect(await generator.inputs.allSatisfy { $0.text.count <= 180 })
        #expect(await progress.values.contains { event in
            if case let .integration(round, _, _) = event {
                return round > 1
            }
            return false
        })
    }

    @Test func failedChunkStopsWithoutPublishingPartialSummary() async {
        let generator = RecordingSummaryGenerator(failAt: 2)
        let result = await service(generator: generator, limit: 200).summarize(transcript(String(repeating: "word ", count: 200)))
        guard case let .failed(.chunkFailed(index, total, _)) = result else {
            Issue.record("Expected chunk failure, received \(result)")
            return
        }
        #expect(index == 2)
        #expect(total > 2)
        #expect(await generator.inputs.count == 2)
    }

    @Test func failedIntegrationIsNotPublishedAsComplete() async {
        let generator = RecordingSummaryGenerator(failAt: 3)
        let result = await service(generator: generator, limit: 200).summarize(transcript(String(repeating: "word ", count: 60)))
        guard case .failed(.integrationFailed) = result else {
            Issue.record("Expected integration failure, received \(result)")
            return
        }
    }

    @Test func nonCompressingIntermediateSummariesFailInsteadOfLooping() async {
        let generator = RecordingSummaryGenerator(summaryText: String(repeating: "x", count: 150))
        let result = await service(generator: generator, limit: 200).summarize(transcript(String(repeating: "word ", count: 100)))
        guard case .failed(.integrationFailed) = result else {
            Issue.record("Expected bounded integration failure")
            return
        }
        #expect(await generator.inputs.count == 3)
    }

    @Test func duplicateTopicsRetainDetailsAndDistinctTaskOwnersRemain() {
        let summary = MeetingSummary(
            summary: "統合結果",
            topics: [MeetingTopic(title: "API", detail: "認証"), MeetingTopic(title: " api ", detail: "検証")],
            actionItems: [
                MeetingActionItem(title: "更新", owner: "自分", dueDateText: "明日"),
                MeetingActionItem(title: " 更新。", owner: "自分", dueDateText: "明日"),
                MeetingActionItem(title: "更新", owner: "相手", dueDateText: "明日")
            ],
            transcriptSourceURL: sourceURL
        )
        let result = MeetingSummaryMerger.removingDuplicates(summary)
        #expect(result.topics.count == 1)
        #expect(result.topics.first?.detail == "認証\n検証")
        #expect(result.actionItems.count == 2)
        #expect(MeetingSummaryMerger.integrationText([summary]).contains("担当: 相手"))
    }

    @Test func fallbackForwardsChunkProgress() async {
        let generator = RecordingSummaryGenerator()
        let recorder = SummaryProgressRecorder()
        let fallback = FallbackTranscriptSummaryService(
            primary: service(generator: generator, limit: 200),
            fallback: ExtractiveTranscriptSummaryService()
        )
        _ = await fallback.summarize(transcript(String(repeating: "word ", count: 60))) { await recorder.append($0) }
        #expect(await recorder.values.contains(.chunk(completed: 2, total: 2)))
    }

    private func service(generator: RecordingSummaryGenerator, limit: Int = 24_000) -> PromptedTranscriptSummaryService {
        PromptedTranscriptSummaryService(
            promptBuilder: SummaryPromptBuilder(characterLimit: limit),
            availabilityChecker: AvailableSummaryChecker(),
            generator: generator
        )
    }

    private func transcript(_ text: String) -> TranscriptResult {
        TranscriptResult(text: text, localeIdentifier: "ja-JP", sourceURL: sourceURL)
    }

    private var sourceURL: URL { URL(fileURLWithPath: "/tmp/long-meeting.m4a") }
}

private actor RecordingSummaryGenerator: SummaryGenerating {
    var inputs: [TranscriptResult] = []
    var prompts: [SummaryPrompt] = []
    let failAt: Int?
    let summaryText: String

    init(failAt: Int? = nil, summaryText: String = "会議の結論。") {
        self.failAt = failAt
        self.summaryText = summaryText
    }

    func generate(prompt: SummaryPrompt, transcript: TranscriptResult) async throws -> MeetingSummary {
        inputs.append(transcript)
        prompts.append(prompt)
        if inputs.count == failAt {
            throw SummaryError.generationFailed("test failure")
        }
        return MeetingSummary(summary: summaryText, topics: [], actionItems: [], transcriptSourceURL: transcript.sourceURL)
    }
}

private actor SummaryProgressRecorder {
    var values: [SummaryProgress] = []
    func append(_ value: SummaryProgress) { values.append(value) }
}

private struct AvailableSummaryChecker: SummaryAvailabilityChecking {
    nonisolated func currentAvailability() -> SummaryAvailability { .available }
}
