#if canImport(FoundationModels) && compiler(>=6.2)
import Foundation
import FoundationModels

@available(macOS 26.0, *)
struct FoundationModelsSummaryService: TranscriptSummaryService {
    private let service: PromptedTranscriptSummaryService

    nonisolated init(promptBuilder: SummaryPromptBuilder = SummaryPromptBuilder()) {
        service = PromptedTranscriptSummaryService(
            promptBuilder: promptBuilder,
            availabilityChecker: SystemSummaryAvailabilityChecker(),
            generator: FoundationModelsSummaryGenerator()
        )
    }

    nonisolated func summarize(_ transcript: TranscriptResult) async -> TranscriptSummaryResult {
        await service.summarize(transcript)
    }

    nonisolated func summarize(_ transcript: TranscriptResult, progress: SummaryProgressHandler) async -> TranscriptSummaryResult {
        await service.summarize(transcript, progress: progress)
    }

    nonisolated func summarize(
        _ transcript: TranscriptResult,
        template: SummaryTemplate,
        progress: SummaryProgressHandler
    ) async -> TranscriptSummaryResult {
        await service.summarize(transcript, template: template, progress: progress)
    }
}

@available(macOS 26.0, *)
private struct SystemSummaryAvailabilityChecker: SummaryAvailabilityChecking {
    nonisolated init() {}

    nonisolated func currentAvailability() -> SummaryAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case let .unavailable(reason):
            return Self.map(reason)
        @unknown default:
            return .foundationModelsUnavailable("Foundation Models availability is unknown.")
        }
    }

    nonisolated private static func map(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> SummaryAvailability {
        switch reason {
        case .deviceNotEligible:
            return .deviceNotEligible
        case .appleIntelligenceNotEnabled:
            return .appleIntelligenceDisabled
        case .modelNotReady:
            return .modelNotReady
        @unknown default:
            return .foundationModelsUnavailable("Foundation Models is unavailable for an unknown reason.")
        }
    }
}

@available(macOS 26.0, *)
private struct FoundationModelsSummaryGenerator: SummaryGenerating {
    nonisolated init() {}

    nonisolated func generate(prompt: SummaryPrompt, transcript: TranscriptResult) async throws -> MeetingSummary {
        let session = LanguageModelSession(instructions: prompt.instructions)
        let response = try await session.respond(to: Self.jsonPrompt(from: prompt.prompt))
        return try Self.decodeSummary(from: response.content, sourceURL: transcript.sourceURL)
    }

    nonisolated private static func jsonPrompt(from prompt: String) -> String {
        """
        \(prompt)

        JSON object only. Do not include markdown fences.
        Schema:
        {
          "summary": "string",
          "evidenceIDs": ["ID from input"],
          "topics": [{"title": "string", "detail": "string", "evidenceIDs": ["ID from input"]}],
          "actionItems": [{"title": "string", "owner": "string", "dueDateText": "string", "evidenceIDs": ["ID from input"]}]
        }
        """
    }

    nonisolated private static func decodeSummary(from content: String, sourceURL: URL) throws -> MeetingSummary {
        let jsonText = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .removingMarkdownJSONFence()

        guard let data = jsonText.data(using: .utf8) else {
            throw SummaryError.invalidStructuredOutput
        }

        do {
            return try JSONDecoder()
                .decode(GeneratedMeetingSummary.self, from: data)
                .meetingSummary(sourceURL: sourceURL)
        } catch let error as SummaryError {
            throw error
        } catch {
            throw SummaryError.invalidStructuredOutput
        }
    }
}

nonisolated private struct GeneratedMeetingSummary: Decodable {
    let summary: String
    let topics: [GeneratedMeetingTopic]
    let actionItems: [GeneratedMeetingActionItem]
    let evidenceIDs: [String]?

    func meetingSummary(sourceURL: URL) throws -> MeetingSummary {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSummary.isEmpty else {
            throw SummaryError.invalidStructuredOutput
        }

        return MeetingSummary(
            summary: trimmedSummary,
            topics: topics.map(\.meetingTopic),
            actionItems: actionItems.map(\.meetingActionItem),
            transcriptSourceURL: sourceURL,
            evidenceIDs: evidenceIDs
        )
    }
}

nonisolated private struct GeneratedMeetingTopic: Decodable {
    let title: String
    let detail: String
    let evidenceIDs: [String]?

    var meetingTopic: MeetingTopic {
        MeetingTopic(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            detail: detail.trimmedNilIfEmpty,
            evidenceIDs: evidenceIDs
        )
    }
}

nonisolated private struct GeneratedMeetingActionItem: Decodable {
    let title: String
    let owner: String
    let dueDateText: String
    let evidenceIDs: [String]?

    var meetingActionItem: MeetingActionItem {
        MeetingActionItem(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            owner: owner.trimmedNilIfEmpty,
            dueDateText: dueDateText.trimmedNilIfEmpty,
            evidenceIDs: evidenceIDs
        )
    }
}

private extension String {
    nonisolated func removingMarkdownJSONFence() -> String {
        var text = self
        if text.hasPrefix("```json") {
            text.removeFirst("```json".count)
        } else if text.hasPrefix("```") {
            text.removeFirst("```".count)
        }

        if text.hasSuffix("```") {
            text.removeLast("```".count)
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif

