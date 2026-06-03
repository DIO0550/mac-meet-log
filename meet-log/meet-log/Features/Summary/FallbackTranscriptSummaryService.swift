import Foundation

struct FallbackTranscriptSummaryService: TranscriptSummaryService {
    private let primary: TranscriptSummaryService
    private let fallback: TranscriptSummaryService

    nonisolated init(primary: TranscriptSummaryService, fallback: TranscriptSummaryService) {
        self.primary = primary
        self.fallback = fallback
    }

    nonisolated func summarize(_ transcript: TranscriptResult) async -> TranscriptSummaryResult {
        let result = await primary.summarize(transcript)

        switch result {
        case .summarized, .failed:
            return result
        case .unavailable:
            return await fallback.summarize(transcript)
        }
    }
}

struct ExtractiveTranscriptSummaryService: TranscriptSummaryService {
    private let sentenceLimit: Int
    private let summaryCharacterLimit: Int
    private let topicLimit: Int

    nonisolated init(sentenceLimit: Int = 3, summaryCharacterLimit: Int = 280, topicLimit: Int = 5) {
        self.sentenceLimit = sentenceLimit
        self.summaryCharacterLimit = summaryCharacterLimit
        self.topicLimit = topicLimit
    }

    nonisolated func summarize(_ transcript: TranscriptResult) async -> TranscriptSummaryResult {
        let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .failed(.emptyTranscript)
        }

        let sentences = Self.sentences(from: text)
        let summaryText = Self.summaryText(
            sentences: sentences,
            fallback: text,
            sentenceLimit: sentenceLimit,
            characterLimit: summaryCharacterLimit
        )

        return .summarized(
            MeetingSummary(
                summary: summaryText,
                topics: Self.topics(from: sentences, fallback: summaryText, limit: topicLimit),
                actionItems: [],
                transcriptSourceURL: transcript.sourceURL
            )
        )
    }

    nonisolated private static func sentences(from text: String) -> [String] {
        let separators = CharacterSet(charactersIn: "。．.!?！？\n")
        return text
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    nonisolated private static func summaryText(
        sentences: [String],
        fallback: String,
        sentenceLimit: Int,
        characterLimit: Int
    ) -> String {
        let source = sentences.prefix(sentenceLimit).joined(separator: "。")
        let text = source.isEmpty ? fallback : source + (source.hasSuffix("。") ? "" : "。")
        return text.clipped(to: characterLimit)
    }

    nonisolated private static func topics(from sentences: [String], fallback: String, limit: Int) -> [MeetingTopic] {
        let source = sentences.isEmpty ? [fallback] : Array(sentences.prefix(limit))
        return source.map { sentence in
            MeetingTopic(
                title: sentence.clipped(to: 40),
                detail: sentence
            )
        }
    }
}

private extension String {
    nonisolated func clipped(to limit: Int) -> String {
        guard count > limit else {
            return self
        }

        let endIndex = index(startIndex, offsetBy: max(0, limit - 1))
        return String(self[..<endIndex]) + "..."
    }
}
