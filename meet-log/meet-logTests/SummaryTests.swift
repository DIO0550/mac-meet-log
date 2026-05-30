import Foundation
import Testing
@testable import meet_log

struct SummaryTests {
    @Test func meetingSummaryRoundTripsThroughJSON() throws {
        let summary = sampleSummary
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(summary)
        let decoded = try decoder.decode(MeetingSummary.self, from: data)

        #expect(decoded == summary)
    }

    @Test func promptBuilderRejectsEmptyTranscript() {
        let builder = SummaryPromptBuilder(characterLimit: 100)
        let result = builder.makePrompt(for: transcript(text: "   \n "))

        #expect(result == .failure(.emptyTranscript))
    }

    @Test func promptBuilderRejectsTranscriptOverLimit() {
        let builder = SummaryPromptBuilder(characterLimit: 4)
        let result = builder.makePrompt(for: transcript(text: "12345"))

        #expect(result == .failure(.transcriptTooLong(characterCount: 5, limit: 4)))
    }

    @Test func promptBuilderIncludesJapaneseMeetingInstructionsAndExtractionTargets() throws {
        let builder = SummaryPromptBuilder(characterLimit: 100)
        let prompt = try #require(builder.makePrompt(for: transcript(text: "次回は設計を確認します。")).success)

        #expect(prompt.instructions.contains("日本語"))
        #expect(prompt.instructions.contains("会議"))
        #expect(prompt.prompt.contains("要約"))
        #expect(prompt.prompt.contains("主要トピック"))
        #expect(prompt.prompt.contains("アクションアイテム"))
        #expect(prompt.prompt.contains("次回は設計を確認します。"))
    }

    @Test func unavailableSummaryServiceReturnsReason() async {
        let service = UnavailableSummaryService(reason: .modelNotReady)

        let result = await service.summarize(transcript(text: "本文"))

        #expect(result == .unavailable(.modelNotReady))
    }

    @Test func summaryErrorsAndUnavailableReasonsHaveUserFacingDescriptions() {
        let errors: [SummaryError] = [
            .emptyTranscript,
            .transcriptTooLong(characterCount: 10, limit: 5),
            .generationFailed("failed"),
            .invalidStructuredOutput,
            .persistenceFailed("disk")
        ]
        let reasons: [SummaryUnavailableReason] = [
            .foundationModelsUnavailable("unavailable"),
            .appleIntelligenceDisabled,
            .deviceNotEligible,
            .modelNotReady
        ]

        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }

        for reason in reasons {
            #expect(reason.errorDescription?.isEmpty == false)
        }
    }

    @Test func promptedSummaryServiceGeneratesWhenAvailable() async {
        let generator = FakeSummaryGenerator(result: .success(sampleSummary))
        let service = PromptedTranscriptSummaryService(
            promptBuilder: SummaryPromptBuilder(characterLimit: 100),
            availabilityChecker: FixedSummaryAvailabilityChecker(availability: .available),
            generator: generator
        )

        let result = await service.summarize(transcript(text: "本文"))

        #expect(result == .summarized(sampleSummary))
    }

    @Test func promptedSummaryServiceMapsAvailabilityToUnavailableReason() async {
        let service = PromptedTranscriptSummaryService(
            promptBuilder: SummaryPromptBuilder(characterLimit: 100),
            availabilityChecker: FixedSummaryAvailabilityChecker(availability: .deviceNotEligible),
            generator: FakeSummaryGenerator(result: .success(sampleSummary))
        )

        let result = await service.summarize(transcript(text: "本文"))

        #expect(result == .unavailable(.deviceNotEligible))
    }

    @Test func promptedSummaryServiceMapsGeneratorFailure() async {
        let service = PromptedTranscriptSummaryService(
            promptBuilder: SummaryPromptBuilder(characterLimit: 100),
            availabilityChecker: FixedSummaryAvailabilityChecker(availability: .available),
            generator: FakeSummaryGenerator(result: .failure(SummaryError.invalidStructuredOutput))
        )

        let result = await service.summarize(transcript(text: "本文"))

        #expect(result == .failed(.invalidStructuredOutput))
    }

    @MainActor
    @Test func sidecarStoreSavesAndLoadsSummary() async throws {
        let directoryURL = try makeTemporaryDirectory()
        let item = libraryItem(directoryURL: directoryURL)
        let store = MeetingSummarySidecarStore()

        try await store.save(sampleSummary, for: item)
        let loaded = try await store.summary(for: item)

        #expect(loaded == sampleSummary)
        #expect(FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent("2026-05-19_10-30-00_summary.json").path))
    }

    @MainActor
    @Test func sidecarStoreReturnsNilWhenSummaryFileDoesNotExist() async throws {
        let store = MeetingSummarySidecarStore()
        let item = libraryItem(directoryURL: try makeTemporaryDirectory())

        let loaded = try await store.summary(for: item)

        #expect(loaded == nil)
    }
}

private extension Result {
    var success: Success? {
        if case let .success(value) = self {
            return value
        }

        return nil
    }
}

private let sampleSummary = MeetingSummary(
    summary: "設計方針を確認した。",
    topics: [
        MeetingTopic(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: "設計",
            detail: "Foundation Models の利用方針"
        )
    ],
    actionItems: [
        MeetingActionItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            title: "実装計画を更新する",
            owner: "DIO",
            dueDateText: "次回まで"
        )
    ],
    transcriptSourceURL: URL(fileURLWithPath: "/tmp/sample.m4a"),
    createdAt: Date(timeIntervalSince1970: 1_800_000_000)
)

private func transcript(text: String) -> TranscriptResult {
    TranscriptResult(
        text: text,
        localeIdentifier: "ja-JP",
        sourceURL: URL(fileURLWithPath: "/tmp/sample.m4a")
    )
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SummaryTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func libraryItem(directoryURL: URL) -> RecordingLibraryItem {
    RecordingLibraryItem(
        id: "2026-05-19_10-30-00",
        title: "Recording",
        createdAt: Date(timeIntervalSince1970: 0),
        duration: .seconds(60),
        mixdownURL: directoryURL.appendingPathComponent("2026-05-19_10-30-00_mix.m4a"),
        systemAudioURL: nil,
        microphoneURL: nil,
        fileExistence: RecordingLibraryFileExistence(
            mixdownExists: true,
            systemAudioExists: false,
            microphoneExists: false
        )
    )
}

private struct FixedSummaryAvailabilityChecker: SummaryAvailabilityChecking {
    let availability: SummaryAvailability

    func currentAvailability() -> SummaryAvailability {
        availability
    }
}

private struct FakeSummaryGenerator: SummaryGenerating {
    let result: Result<MeetingSummary, Error>

    func generate(prompt: SummaryPrompt, transcript: TranscriptResult) async throws -> MeetingSummary {
        try result.get()
    }
}
