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

    @Test func promptBuilderUsesSelectedTemplatePerspective() throws {
        let template = SummaryTemplate(
            name: "設計レビュー",
            instructions: "設計上の判断とリスクを抽出してください。",
            outputPerspective: "- 要約: 判断の背景\n- 主要トピック: 設計案とリスク\n- アクションアイテム: 担当者と期限"
        )
        let builder = SummaryPromptBuilder(characterLimit: 100, template: template)
        let prompt = try builder.makePrompt(for: transcript(text: "案Aを採用します。")).get()

        #expect(prompt.instructions.contains("設計上の判断"))
        #expect(prompt.prompt.contains("設計案とリスク"))
        #expect(prompt.prompt.contains("案Aを採用します。"))
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

        #expect(result == .summarized(sampleSummary.recording(template: .builtIn)))
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

    @Test func fallbackSummaryServiceUsesFallbackWhenPrimaryIsUnavailable() async throws {
        let fallbackSummary = MeetingSummary(
            summary: "ローカル要約",
            topics: [],
            actionItems: [],
            transcriptSourceURL: URL(fileURLWithPath: "/tmp/sample.m4a"),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let service = FallbackTranscriptSummaryService(
            primary: FakeTranscriptSummaryService(result: .unavailable(.appleIntelligenceDisabled)),
            fallback: FakeTranscriptSummaryService(result: .summarized(fallbackSummary))
        )

        let result = await service.summarize(transcript(text: "本文"))

        #expect(result == .summarized(fallbackSummary.recording(fallbackReason: .appleIntelligenceDisabled)))
    }

    @Test func extractiveSummaryServiceSummarizesTranscriptWithoutAppleIntelligence() async throws {
        let service = ExtractiveTranscriptSummaryService(sentenceLimit: 2, summaryCharacterLimit: 100, topicLimit: 2)

        let result = await service.summarize(transcript(text: "今日は録音を確認しました。次に保存先を直しました。最後に要約を確認します。"))

        guard case let .summarized(summary) = result else {
            Issue.record("Expected a summarized result.")
            return
        }

        #expect(summary.summary == "今日は録音を確認しました。次に保存先を直しました。")
        #expect(summary.topics.map(\.title) == ["今日は録音を確認しました", "次に保存先を直しました"])
        #expect(summary.actionItems.isEmpty)
        #expect(summary.transcriptSourceURL == URL(fileURLWithPath: "/tmp/sample.m4a"))
    }

    @Test(arguments: [
        SummaryUnavailableReason.appleIntelligenceDisabled,
        .deviceNotEligible, .modelNotReady, .foundationModelsUnavailable("SDK unavailable")
    ])
    func extractiveFallbackPersistsReasonAndDoesNotApplySelectedTemplate(reason: SummaryUnavailableReason) async throws {
        let service = FallbackTranscriptSummaryService(
            primary: UnavailableSummaryService(reason: reason),
            fallback: ExtractiveTranscriptSummaryService()
        )
        let template = SummaryTemplate(id: "custom", name: "カスタム", instructions: "担当者とTODOを抽出", outputPerspective: "TODO", isBuiltIn: false)
        let input = transcript(text: "明日までに実装します。")
        let result = await service.summarize(input, template: template, progress: { _ in })
        guard case let .summarized(value) = result else {
            Issue.record("Expected extractive fallback")
            return
        }
        let summary = value.recording(input: input)
        #expect(summary.generation?.method == .extractive)
        #expect(summary.generation?.fallbackReason == reason)
        #expect(summary.generation?.templateApplied == false)
        #expect(summary.generation?.actionItemsExtracted == false)
        #expect(summary.templateID == nil)
        #expect(summary.templateName == nil)
        #expect(summary.actionItems.isEmpty)
        let markdown = try MeetingSummaryMarkdownCodec.encode(summary, recordingID: "fallback")
        #expect(try MeetingSummaryMarkdownCodec.decode(markdown) == summary)
        #expect(markdown.contains("生成方式: 簡易抽出"))
        #expect(markdown.contains(reason.localizedDescription))
        #expect(markdown.contains("TODO抽出は未実施"))
        #expect(!markdown.contains("- Template:"))
        #expect(!markdown.contains("- Template ID:"))

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = libraryItem(directoryURL: directory)
        let store = MeetingSummarySidecarStore()
        try await store.save(summary, for: item)
        #expect(try await store.summary(for: item) == summary)

        // Processing without an explicit template must also retain the reason.
        let defaultResult = await service.summarize(input, progress: { _ in })
        guard case let .summarized(defaultSummary) = defaultResult else {
            Issue.record("Expected default fallback")
            return
        }
        #expect(defaultSummary.generation?.fallbackReason == reason)
    }

    @Test func directExtractionDoesNotClaimTemplateApplication() async throws {
        let result = await ExtractiveTranscriptSummaryService().summarize(
            transcript(text: "本文。"), template: .builtIn, progress: { _ in }
        )
        guard case let .summarized(summary) = result else {
            Issue.record("Expected extraction")
            return
        }
        #expect(summary.generation?.method == .extractive)
        #expect(summary.generation?.fallbackReason == nil)
        #expect(summary.generation?.templateApplied == false)
        #expect(summary.templateID == nil)
        #expect(summary.templateName == nil)
    }

    @Test func normalSummaryRecordsAppliedTemplateAndExtractionStatus() async throws {
        let service = PromptedTranscriptSummaryService(
            availabilityChecker: FixedSummaryAvailabilityChecker(availability: .available),
            generator: FakeSummaryGenerator(result: .success(sampleSummary))
        )
        let result = await service.summarize(transcript(text: "本文"), template: .builtIn, progress: { _ in })
        guard case let .summarized(summary) = result else {
            Issue.record("Expected model summary")
            return
        }
        #expect(summary.generation?.method == .foundationModels)
        #expect(summary.generation?.templateApplied == true)
        #expect(summary.generation?.actionItemsExtracted == true)
        #expect(summary.generation?.fallbackReason == nil)
        #expect(summary.templateID == SummaryTemplate.builtIn.id)
        let markdown = try MeetingSummaryMarkdownCodec.encode(summary, recordingID: "model")
        #expect(try MeetingSummaryMarkdownCodec.decode(markdown) == summary)
        #expect(markdown.contains("生成方式: Apple Foundation Models"))
        #expect(!markdown.contains("TODO抽出は未実施"))
    }

    @Test func oldJSONWithoutGenerationRemainsReadable() throws {
        let data = try JSONEncoder().encode(sampleSummary)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["generation"] == nil)
        let decoded = try JSONDecoder().decode(MeetingSummary.self, from: data)
        #expect(decoded == sampleSummary)
        #expect(decoded.generation == nil)
    }

    @Test func fallbackDoesNotReplacePrimarySuccessOrFailure() async {
        for result in [TranscriptSummaryResult.summarized(sampleSummary), .failed(.generationFailed("failure"))] {
            let service = FallbackTranscriptSummaryService(
                primary: FakeTranscriptSummaryService(result: result),
                fallback: FakeTranscriptSummaryService(result: .failed(.emptyTranscript))
            )
            #expect(await service.summarize(transcript(text: "本文")) == result)
            #expect(await service.summarize(transcript(text: "本文"), template: .builtIn, progress: { _ in }) == result)
        }
    }

    @Test func fallbackFailureIsNotTurnedIntoSummary() async {
        let service = FallbackTranscriptSummaryService(
            primary: UnavailableSummaryService(reason: .modelNotReady),
            fallback: FakeTranscriptSummaryService(result: .failed(.emptyTranscript))
        )
        #expect(await service.summarize(transcript(text: "")) == .failed(.emptyTranscript))
    }

    @Test func fallbackMetadataSurvivesEditingEvidenceFilteringAndDeduplication() throws {
        let summary = MeetingSummary(
            summary: "冒頭", topics: [], actionItems: [], transcriptSourceURL: nil,
            generation: SummaryGeneration(method: .extractive, templateApplied: false, actionItemsExtracted: false,
                                          fallbackReason: .modelNotReady)
        ).recording(input: transcript(text: "冒頭"))
        var draft = MeetingEditDraft(summary: summary)
        draft.text = "編集済み"
        draft.actionItems = [MeetingActionItem(title: "手動追加")]
        let edited = try #require(draft.editedSummary())
        let filtered = edited.restrictingEvidence(to: [], fingerprint: "updated")
        let merged = MeetingSummaryMerger.removingDuplicates(filtered)
        #expect(merged.generation == summary.generation)
        #expect(merged.actionItems.count == 1)
        #expect(merged.generation?.actionItemsExtracted == false)
        #expect(try MeetingSummaryMarkdownCodec.decode(
            MeetingSummaryMarkdownCodec.encode(merged, recordingID: "edited")
        ) == merged)
    }

    @MainActor
    @Test func sidecarStoreSavesAndLoadsSummary() async throws {
        let directoryURL = try makeTemporaryDirectory()
        let item = libraryItem(directoryURL: directoryURL)
        let store = MeetingSummarySidecarStore()

        try await store.save(sampleSummary, for: item)
        let loaded = try await store.summary(for: item)

        #expect(loaded == sampleSummary)
        #expect(FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent("2026-05-19_10-30-00_summary.md").path))
    }

    @MainActor
    @Test func generatedSummaryRoundTripsSpecialCharactersWhitespaceAndMetadata() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let item = libraryItem(directoryURL: directoryURL)
        let store = MeetingSummarySidecarStore()
        let expected = MeetingSummary(
            summary: "\n  要約\n## Topics\n- 箇条書き\n<!-- summary-data: invalid -->\n",
            topics: [
                MeetingTopic(title: "API: v2", detail: "一行目\n二行目\n## Action Items\n- 項目"),
                MeetingTopic(title: "# 見出し (任意), 補足", detail: ""),
                MeetingTopic(title: "詳細なし")
            ],
            actionItems: [
                MeetingActionItem(title: "確認する (任意)", owner: "Doe, John", dueDateText: "金曜 (予定), 来週"),
                MeetingActionItem(title: "\n## Summary\n- 対応\n", owner: "担当: A\nB", dueDateText: ""),
                MeetingActionItem(title: "担当・期限なし")
            ],
            transcriptSourceURL: URL(string: "https://example.com/transcript?version=2"),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000.123456),
            templateID: "template: v2", templateName: "\nテンプレート\n## Summary",
            inputFingerprint: "input-fingerprint"
        )

        #expect(expected.editedAt == nil)
        #expect(!expected.hasEvidence)
        try await store.save(expected, for: item)
        #expect(try await store.summary(for: item) == expected)
        #expect(try await store.summary(for: item) == expected)

        // Human-readable sections are a view; changing them cannot reparse values.
        let url = directoryURL.appendingPathComponent("\(item.id)_summary.md")
        let markdown = try String(contentsOf: url, encoding: .utf8)
        #expect(markdown.contains("## Summary"))
        #expect(markdown.contains("確認する (任意)"))
        let changedDisplay = markdown.replacingOccurrences(of: "API: v2", with: "表示だけ変更")
        try changedDisplay.write(to: url, atomically: true, encoding: .utf8)
        #expect(try await store.summary(for: item) == expected)
    }

    @Test func structuredSummaryPreservesEmptyValuesAndEvidenceMetadata() throws {
        let expected = MeetingSummary(
            summary: "", topics: [MeetingTopic(title: "", detail: "", evidenceIDs: [])],
            actionItems: [MeetingActionItem(title: "", owner: "", dueDateText: "", evidenceIDs: ["audio-1"])],
            transcriptSourceURL: nil, createdAt: Date(timeIntervalSince1970: 1000.123456),
            templateID: "", templateName: "", inputFingerprint: "",
            editedAt: Date(timeIntervalSince1970: 2000.654321),
            evidenceIDs: ["audio-1"], evidenceInputFingerprint: "evidence-fingerprint"
        )
        let markdown = try MeetingSummaryMarkdownCodec.encode(expected, recordingID: "a")

        #expect(try MeetingSummaryMarkdownCodec.decode(markdown) == expected)
    }

    @MainActor
    @Test func legacySummaryIsReadWithoutRewritingAndMigratesOnExplicitSave() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let item = libraryItem(directoryURL: directoryURL)
        let url = directoryURL.appendingPathComponent("\(item.id)_summary.md")
        let legacy = """
        # Meeting Summary

        - Recording: legacy
        - Created: 2026-01-01T00:00:00.000Z
        - Source: /tmp/legacy.m4a
        - Template ID: legacy-template
        - Template: 会議
        - Input SHA256: legacy-input

        ## Summary

        旧要約

        ## Topics

        - 設計: 旧詳細

        ## Action Items

        - 確認 (Owner: DIO, Due: 明日)

        """
        let originalBytes = Data(legacy.utf8)
        try originalBytes.write(to: url)
        let store = MeetingSummarySidecarStore()
        let loaded = try #require(try await store.summary(for: item))

        #expect(loaded.summary == "旧要約")
        #expect(loaded.topics[0].title == "設計")
        #expect(loaded.topics[0].detail == "旧詳細")
        #expect(loaded.actionItems[0].title == "確認")
        #expect(loaded.actionItems[0].owner == "DIO")
        #expect(loaded.actionItems[0].dueDateText == "明日")
        #expect(loaded.createdAt == Date(timeIntervalSince1970: 1_767_225_600))
        #expect(loaded.transcriptSourceURL == URL(fileURLWithPath: "/tmp/legacy.m4a"))
        #expect(loaded.templateID == "legacy-template")
        #expect(loaded.templateName == "会議")
        #expect(loaded.inputFingerprint == "legacy-input")
        #expect(try Data(contentsOf: url) == originalBytes)

        try await store.save(loaded, for: item)
        #expect(try await store.summary(for: item) == loaded)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("<!-- summary-edit-format: 1 -->"))
    }

    @Test func existingVersionOneEditedPayloadRemainsReadable() throws {
        let json = #"{"summary":"旧編集","topics":[{"id":"00000000-0000-0000-0000-000000000001","title":"API: v2"}],"actionItems":[],"createdAt":123.125,"editedAt":456.25}"#
        let markdown = "# Meeting Summary\n\n<!-- summary-edit-format: 1 -->\n\n## Summary\n\n表示\n\n<!-- summary-data: \(Data(json.utf8).base64EncodedString()) -->\n"
        let loaded = try MeetingSummaryMarkdownCodec.decode(markdown)

        #expect(loaded.summary == "旧編集")
        #expect(loaded.topics[0].title == "API: v2")
        #expect(loaded.topics[0].id == sampleSummary.topics[0].id)
        #expect(loaded.createdAt == Date(timeIntervalSinceReferenceDate: 123.125))
        #expect(loaded.editedAt == Date(timeIntervalSinceReferenceDate: 456.25))
    }

    @Test func invalidStructuredSummaryNeverFallsBackToVisibleMarkdown() throws {
        let valid = try MeetingSummaryMarkdownCodec.encode(sampleSummary, recordingID: "a")
        let payloadStart = try #require(valid.range(of: "<!-- summary-data: ")).lowerBound
        let withoutPayload = String(valid[..<payloadStart])
        let invalidMarkdowns = [
            withoutPayload,
            withoutPayload + "<!-- summary-data: invalid -->\n",
            withoutPayload + "<!-- summary-data: e30= -->\n",
            valid.replacingOccurrences(of: "summary-edit-format: 1", with: "summary-edit-format: 2"),
            valid.replacingOccurrences(of: "summary-edit-format: 1 -->", with: "summary-edit-format: broken")
        ]

        for markdown in invalidMarkdowns {
            #expect(throws: (any Error).self) {
                try MeetingSummaryMarkdownCodec.decode(markdown)
            }
        }
    }

    @MainActor
    @Test func encodingFailurePreservesExistingSummaryBytes() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let item = libraryItem(directoryURL: directoryURL)
        let store = MeetingSummarySidecarStore()
        try await store.save(sampleSummary, for: item)
        let url = directoryURL.appendingPathComponent("\(item.id)_summary.md")
        let originalBytes = try Data(contentsOf: url)
        let invalid = MeetingSummary(
            summary: "保存できない日時", topics: [], actionItems: [], transcriptSourceURL: nil,
            createdAt: Date(timeIntervalSince1970: .infinity)
        )

        await #expect(throws: SummaryError.self) {
            try await store.save(invalid, for: item)
        }
        #expect(try Data(contentsOf: url) == originalBytes)
        #expect(try await store.summary(for: item) == sampleSummary)
    }

    @MainActor
    @Test func atomicWriteFailurePreservesExistingSummaryBytes() async throws {
        let directoryURL = try makeTemporaryDirectory()
        let item = libraryItem(directoryURL: directoryURL)
        let store = MeetingSummarySidecarStore()
        try await store.save(sampleSummary, for: item)
        let url = directoryURL.appendingPathComponent("\(item.id)_summary.md")
        let originalBytes = try Data(contentsOf: url)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directoryURL.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: directoryURL)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directoryURL.path)
        let replacement = MeetingSummary(summary: "置き換え", topics: [], actionItems: [], transcriptSourceURL: nil)

        await #expect(throws: SummaryError.self) {
            try await store.save(replacement, for: item)
        }
        #expect(try Data(contentsOf: url) == originalBytes)
        #expect(try await store.summary(for: item) == sampleSummary)
    }

    @MainActor
    @Test func sidecarStoreSavesTranscriptMarkdown() async throws {
        let directoryURL = try makeTemporaryDirectory()
        let item = libraryItem(directoryURL: directoryURL)
        let store = MeetingSummarySidecarStore()

        try await store.save(transcript(text: "今日は設計を確認しました。"), for: item)

        let url = directoryURL.appendingPathComponent("2026-05-19_10-30-00_transcript.md")
        let markdown = try String(contentsOf: url, encoding: .utf8)
        #expect(markdown.contains("# Transcript"))
        #expect(markdown.contains("## Text"))
        #expect(markdown.contains("今日は設計を確認しました。"))
    }

    @MainActor
    @Test func sidecarStoreRoundTripsSpeakerLabeledTranscript() async throws {
        let directoryURL = try makeTemporaryDirectory()
        let item = libraryItem(directoryURL: directoryURL)
        let store = MeetingSummarySidecarStore()
        let expected = TranscriptResult(
            text: "確認します。",
            localeIdentifier: "ja-JP",
            sourceURL: URL(fileURLWithPath: "/tmp/sample.m4a"),
            segments: [
                TranscriptSegment(
                    text: "確認します。",
                    timestamp: 4,
                    duration: 2,
                    speaker: .me
                )
            ]
        )

        try await store.save(expected, for: item)
        let loaded = try await store.transcript(for: item)

        #expect(loaded == expected)
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
    createdAt: Date(timeIntervalSince1970: 1_800_000_000),
    templateID: SummaryTemplate.builtIn.id,
    templateName: SummaryTemplate.builtIn.name
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

private struct FakeTranscriptSummaryService: TranscriptSummaryService {
    let result: TranscriptSummaryResult

    func summarize(_ transcript: TranscriptResult) async -> TranscriptSummaryResult {
        result
    }
}
