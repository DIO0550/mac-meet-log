import Foundation

protocol TranscriptSummaryService: Sendable {
    nonisolated func summarize(_ transcript: TranscriptResult) async -> TranscriptSummaryResult
    nonisolated func summarize(_ transcript: TranscriptResult, progress: SummaryProgressHandler) async -> TranscriptSummaryResult
    nonisolated func summarize(
        _ transcript: TranscriptResult,
        template: SummaryTemplate,
        progress: SummaryProgressHandler
    ) async -> TranscriptSummaryResult
}

extension TranscriptSummaryService {
    nonisolated func summarize(_ transcript: TranscriptResult, progress: SummaryProgressHandler) async -> TranscriptSummaryResult {
        await summarize(transcript)
    }

    nonisolated func summarize(
        _ transcript: TranscriptResult,
        template: SummaryTemplate,
        progress: SummaryProgressHandler
    ) async -> TranscriptSummaryResult {
        await summarize(transcript, progress: progress)
    }
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
    case unsplittableWord(limit: Int)
    case chunkFailed(index: Int, total: Int, message: String)
    case integrationFailed(String)
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
        case let .unsplittableWord(limit):
            return "単語の途中で分割できない文字列が要約上限 (\(limit)文字) を超えています。"
        case let .chunkFailed(index, total, message):
            return "チャンク \(index) / \(total) の要約に失敗しました。部分要約は保存していません: \(message)"
        case let .integrationFailed(message):
            return "要約の統合に失敗しました。部分要約は保存していません: \(message)"
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

    nonisolated init(
        promptBuilder: SummaryPromptBuilder = SummaryPromptBuilder(),
        availabilityChecker: SummaryAvailabilityChecking,
        generator: SummaryGenerating
    ) {
        self.promptBuilder = promptBuilder
        self.availabilityChecker = availabilityChecker
        self.generator = generator
    }

    nonisolated func summarize(_ transcript: TranscriptResult) async -> TranscriptSummaryResult {
        await summarize(transcript, progress: { _ in })
    }

    nonisolated func summarize(_ transcript: TranscriptResult, progress: SummaryProgressHandler) async -> TranscriptSummaryResult {
        await summarize(transcript, template: promptBuilder.template, progress: progress)
    }

    nonisolated func summarize(
        _ transcript: TranscriptResult,
        template: SummaryTemplate,
        progress: SummaryProgressHandler
    ) async -> TranscriptSummaryResult {
        let promptBuilder = SummaryPromptBuilder(characterLimit: promptBuilder.characterLimit, template: template)
        if let unavailableReason = availabilityChecker.currentAvailability().unavailableReason {
            return .unavailable(unavailableReason)
        }

        if SummaryEvidenceCatalog.modelInput(transcript).trimmingCharacters(in: .whitespacesAndNewlines).count > promptBuilder.characterLimit {
            do {
                let summary = try await ChunkedSummaryPipeline(promptBuilder: promptBuilder, generator: generator)
                    .summarize(transcript, progress: progress)
                return .summarized(summary.recording(template: template))
            } catch let error as SummaryError {
                return .failed(error)
            } catch {
                return .failed(.generationFailed(error.localizedDescription))
            }
        }

        switch promptBuilder.makePrompt(for: transcript) {
        case let .success(prompt):
            do {
                let summary = try await generator.generate(prompt: prompt, transcript: transcript)
                let catalog = SummaryEvidenceCatalog(transcript)
                return .summarized(summary.restrictingEvidence(to: catalog.ids, fingerprint: catalog.fingerprint)
                    .recording(template: template))
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

