import Foundation

protocol TranscriptSummaryService: Sendable {
    nonisolated func summarize(_ transcript: TranscriptResult) async -> TranscriptSummaryResult
}

enum TranscriptSummaryResult: Equatable, Sendable {
    case summarized(MeetingSummary)
    case unavailable(SummaryUnavailableReason)
    case failed(SummaryError)
}

enum SummaryUnavailableReason: Equatable, LocalizedError, Sendable {
    case foundationModelsUnavailable(String)
    case appleIntelligenceDisabled
    case deviceNotEligible
    case modelNotReady

    var errorDescription: String? {
        switch self {
        case let .foundationModelsUnavailable(message):
            return message
        case .appleIntelligenceDisabled:
            return "Apple Intelligence is disabled in Settings."
        case .deviceNotEligible:
            return "This Mac does not support Apple Intelligence."
        case .modelNotReady:
            return "Apple Intelligence models are still preparing or downloading."
        }
    }
}

enum SummaryError: Error, Equatable, LocalizedError, Sendable {
    case emptyTranscript
    case transcriptTooLong(characterCount: Int, limit: Int)
    case generationFailed(String)
    case invalidStructuredOutput
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "The transcript is empty, so it cannot be summarized."
        case let .transcriptTooLong(characterCount, limit):
            return "The transcript is too long to summarize right now (\(characterCount) characters, limit \(limit))."
        case let .generationFailed(message):
            return "Meeting summary generation failed: \(message)"
        case .invalidStructuredOutput:
            return "Meeting summary generation returned incomplete structured output."
        case let .persistenceFailed(message):
            return "Meeting summary could not be saved or loaded: \(message)"
        }
    }
}

enum SummaryAvailability: Equatable, Sendable {
    case available
    case foundationModelsUnavailable(String)
    case appleIntelligenceDisabled
    case deviceNotEligible
    case modelNotReady

    nonisolated var unavailableReason: SummaryUnavailableReason? {
        switch self {
        case .available:
            return nil
        case let .foundationModelsUnavailable(message):
            return .foundationModelsUnavailable(message)
        case .appleIntelligenceDisabled:
            return .appleIntelligenceDisabled
        case .deviceNotEligible:
            return .deviceNotEligible
        case .modelNotReady:
            return .modelNotReady
        }
    }
}

protocol SummaryAvailabilityChecking: Sendable {
    nonisolated func currentAvailability() -> SummaryAvailability
}

protocol SummaryGenerating: Sendable {
    nonisolated func generate(prompt: SummaryPrompt, transcript: TranscriptResult) async throws -> MeetingSummary
}

struct PromptedTranscriptSummaryService: TranscriptSummaryService {
    private let promptBuilder: SummaryPromptBuilder
    private let availabilityChecker: SummaryAvailabilityChecking
    private let generator: SummaryGenerating

    init(
        promptBuilder: SummaryPromptBuilder = SummaryPromptBuilder(),
        availabilityChecker: SummaryAvailabilityChecking,
        generator: SummaryGenerating
    ) {
        self.promptBuilder = promptBuilder
        self.availabilityChecker = availabilityChecker
        self.generator = generator
    }

    nonisolated func summarize(_ transcript: TranscriptResult) async -> TranscriptSummaryResult {
        if let unavailableReason = availabilityChecker.currentAvailability().unavailableReason {
            return .unavailable(unavailableReason)
        }

        switch promptBuilder.makePrompt(for: transcript) {
        case let .success(prompt):
            do {
                return .summarized(try await generator.generate(prompt: prompt, transcript: transcript))
            } catch let error as SummaryError {
                return .failed(error)
            } catch {
                return .failed(.generationFailed(error.localizedDescription))
            }
        case let .failure(error):
            return .failed(error)
        }
    }
}
