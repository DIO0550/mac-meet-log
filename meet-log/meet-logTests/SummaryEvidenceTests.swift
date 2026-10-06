import Foundation
import Testing
@testable import meet_log

struct SummaryEvidenceTests {
    @Test func resolvesOriginalAudioAndScreenWithoutInventingTimes() throws {
        let source = transcript()
        let catalog = SummaryEvidenceCatalog(source)
        let audio = try #require(catalog.entries.first { $0.source == .audio })
        let screen = try #require(catalog.entries.first { $0.source == .screen })
        let resolved = catalog.resolve([audio.id, screen.id, "audio-invented"], fingerprint: catalog.fingerprint)
        #expect(resolved == [audio, screen])
        #expect(audio.timestamp == 12)
        #expect(screen.timestamp == 30)
        #expect(screen.source.label.contains("合意は未確認"))
        #expect(catalog.resolve([audio.id], fingerprint: nil).isEmpty)
    }

    @Test func sourceEditsRetimingAndRegenerationCannotRebindOldReferences() throws {
        let original = transcript()
        let catalog = SummaryEvidenceCatalog(original)
        let audio = try #require(catalog.entries.first { $0.source == .audio })
        let mutations = [
            transcript(audio: "別の発言", timestamp: 12),
            transcript(timestamp: 50),
            transcript(screen: "別の画面"),
            TranscriptResult(text: original.text, localeIdentifier: "ja-JP", sourceURL: original.sourceURL),
            TranscriptResult(text: "更新された集約文", localeIdentifier: "ja-JP", sourceURL: original.sourceURL,
                             segments: original.segments, screenSegments: original.screenSegments),
            TranscriptResult(text: original.text, localeIdentifier: "ja-JP", sourceURL: URL(fileURLWithPath: "/tmp/other.m4a"),
                             segments: original.segments, screenSegments: original.screenSegments)
        ]
        for updated in mutations {
            let current = SummaryEvidenceCatalog(updated)
            #expect(current.fingerprint != catalog.fingerprint)
            #expect(current.resolve([audio.id], fingerprint: catalog.fingerprint).isEmpty)
        }
    }

    @Test func invalidTimesAndUntimedTextHaveNoPlayableEvidence() {
        let source = TranscriptResult(text: "本文", localeIdentifier: "ja-JP", sourceURL: sourceURL,
            segments: [
                TranscriptSegment(text: "不明", timestamp: .nan, duration: 1),
                TranscriptSegment(text: "負値", timestamp: -1, duration: 1),
                TranscriptSegment(text: "無限", timestamp: 0, duration: .infinity)
            ])
        #expect(SummaryEvidenceCatalog(source).entries.isEmpty)
        #expect(SummaryEvidenceCatalog.modelInput(source).contains("不明"))
        #expect(SummaryEvidenceCatalog.modelInput(source).contains("時刻未確認"))
        #expect(SummaryEvidenceCatalog(source).resolve(["audio-0"], fingerprint: nil).isEmpty)
    }

    @Test func referencesRoundTripInGeneratedAndEditedSidecars() throws {
        let source = transcript()
        let catalog = SummaryEvidenceCatalog(source)
        let ids = catalog.entries.map(\.id)
        let summary = MeetingSummary(
            summary: "要約", topics: [MeetingTopic(title: "決定事項", evidenceIDs: ids)],
            actionItems: [MeetingActionItem(title: "確認する", evidenceIDs: ids)],
            transcriptSourceURL: sourceURL, evidenceIDs: ids,
            evidenceInputFingerprint: catalog.fingerprint
        ).recording(input: source).recording(template: .builtIn)
        let loaded = try MeetingSummaryMarkdownCodec.decode(MeetingSummaryMarkdownCodec.encode(summary, recordingID: "test"))
        #expect(loaded == summary)
        let loadedTranscript = try TranscriptMarkdownCodec.decode(TranscriptMarkdownCodec.encode(source, recordingID: "test"))
        #expect(SummaryEvidenceCatalog(loadedTranscript).resolve(loaded.evidenceIDs,
            fingerprint: loaded.evidenceInputFingerprint).count == 2)

        var draft = MeetingEditDraft(summary: loaded)
        draft.topics[0].title = "修正した決定事項"
        let edited = try #require(draft.editedSummary())
        #expect(edited.topics[0].evidenceIDs == nil)
        #expect(edited.actionItems[0].evidenceIDs == ids)
        #expect(edited.evidenceIDs == ids)
        #expect(try MeetingSummaryMarkdownCodec.decode(MeetingSummaryMarkdownCodec.encode(edited, recordingID: "test")) == edited)
        draft.text = "書き換えた要約"
        draft.actionItems[0].owner = "新担当"
        #expect(draft.editedSummary()?.evidenceIDs == nil)
        #expect(draft.editedSummary()?.actionItems[0].evidenceIDs == nil)
    }

    @Test func legacyJSONAndMarkdownRemainUnconfirmed() throws {
        let json = """
        {"summary":"旧要約","topics":[{"id":"00000000-0000-0000-0000-000000000001","title":"旧トピック"}],
         "actionItems":[{"id":"00000000-0000-0000-0000-000000000002","title":"旧TODO"}],"createdAt":0}
        """
        let old = try JSONDecoder().decode(MeetingSummary.self, from: Data(json.utf8))
        #expect(old.evidenceIDs == nil)
        #expect(old.topics.first?.evidenceIDs == nil)
        #expect(old.actionItems.first?.evidenceIDs == nil)
        let markdown = "# Meeting Summary\n\n## Summary\n\n旧要約\n\n## Topics\n\n- 旧トピック\n"
        let loaded = try MeetingSummaryMarkdownCodec.decode(markdown)
        #expect(!loaded.hasEvidence)
        #expect(SummaryEvidenceCatalog(transcript()).resolve(loaded.evidenceIDs,
            fingerprint: loaded.evidenceInputFingerprint).isEmpty)
    }

    @Test func duplicateTopicsAndTasksUnionEveryReference() {
        let summary = MeetingSummary(summary: "要約", topics: [
            MeetingTopic(title: "API", detail: "音声", evidenceIDs: ["audio-a"]),
            MeetingTopic(title: " api ", detail: "画面", evidenceIDs: ["screen-b"])
        ], actionItems: [
            MeetingActionItem(title: "確認", owner: "自分", evidenceIDs: ["audio-a"]),
            MeetingActionItem(title: "確認", owner: "自分", evidenceIDs: ["audio-c"])
        ], transcriptSourceURL: sourceURL, evidenceIDs: ["screen-b"], evidenceInputFingerprint: "original")
        let merged = MeetingSummaryMerger.removingDuplicates(summary)
        #expect(merged.topics.first?.evidenceIDs == ["audio-a", "screen-b"])
        #expect(merged.actionItems.first?.evidenceIDs == ["audio-a", "audio-c"])
        #expect(merged.evidenceInputFingerprint == "original")
        let integration = MeetingSummaryMerger.integrationText([merged])
        #expect(integration.contains("audio-a"))
        #expect(integration.contains("screen-b"))
        #expect(integration.contains("audio-c"))
    }

    @Test func shortGenerationRejectsMissingAndInventedReferences() async throws {
        let source = transcript()
        let catalog = SummaryEvidenceCatalog(source)
        let generator = EvidenceGenerator(includeClaims: true)
        let result = await service(generator: generator, limit: 1000).summarize(source)
        guard case let .summarized(summary) = result else {
            Issue.record("Expected evidence summary")
            return
        }
        #expect(summary.evidenceIDs?.contains("unconfirmed") == true)
        #expect(catalog.resolve(summary.evidenceIDs, fingerprint: summary.evidenceInputFingerprint).count == 2)
        #expect(summary.topics.first?.evidenceIDs == summary.evidenceIDs)
        #expect(summary.actionItems.first?.evidenceIDs == summary.evidenceIDs)
        #expect(await generator.prompts.first?.instructions.contains("時刻やIDを作らない") == true)
    }

    @Test func longAudioAndScreenRetainReferencesThroughMultipleIntegrationRounds() async throws {
        let audio = (0..<20).map { index in
            TranscriptSegment(text: String(repeating: "発言を確認します。 ", count: 18),
                              timestamp: Double(index * 10), duration: 5)
        }
        let source = TranscriptResult(text: audio.map(\.text).joined(separator: "\n"),
            localeIdentifier: "ja-JP", sourceURL: sourceURL, segments: audio,
            screenSegments: [ScreenTranscriptSegment(text: "画面の案は補助資料です。", timestamp: 60, duration: 5)])
        let generator = EvidenceGenerator()
        let result = await service(generator: generator, limit: 600).summarize(source)
        guard case let .summarized(summary) = result else {
            Issue.record("Expected integrated evidence, got \(result)")
            return
        }
        let catalog = SummaryEvidenceCatalog(source)
        #expect(Set(catalog.resolve(summary.evidenceIDs, fingerprint: summary.evidenceInputFingerprint).map(\.id)) == catalog.ids)
        #expect(await generator.prompts.contains { $0.instructions.contains("横断して統合") })
        #expect(await generator.inputs.allSatisfy { $0.text.count <= 600 })
        #expect(await generator.prompts.filter { $0.instructions.contains("横断して統合") }.count > 1)
    }

    @Test func oversizedSingleSegmentRepeatsItsIdentityOnEachFragment() throws {
        let source = transcript(audio: String(repeating: "long words ", count: 100))
        let catalog = SummaryEvidenceCatalog(source)
        let id = try #require(catalog.entries.first { $0.source == .audio }?.id)
        let chunks = try SummaryEvidenceChunker(characterLimit: 200).split(source)
        let audio = chunks.filter { !$0.screen }
        #expect(audio.count > 1)
        #expect(audio.allSatisfy { $0.text.contains(id) && $0.text.count <= 200 && $0.evidenceIDs == [id] })
        #expect(audio.map { String($0.text.dropFirst(catalog.entries[0].promptLabel.count)) }.joined() == source.segments[0].text)
    }

    @Test func extractiveFallbackUsesOnlyExactAudioSources() async throws {
        let source = transcript(audio: "設計を確認します。")
        guard case let .summarized(summary) = await ExtractiveTranscriptSummaryService().summarize(source) else {
            Issue.record("Expected extractive summary")
            return
        }
        let resolved = SummaryEvidenceCatalog(source).resolve(summary.evidenceIDs, fingerprint: summary.evidenceInputFingerprint)
        #expect(resolved.count == 1)
        #expect(resolved.first?.source == .audio)
    }

    private var sourceURL: URL { URL(fileURLWithPath: "/tmp/evidence.m4a") }

    private func transcript(audio: String = "設計を確認します。", timestamp: Double = 12, screen: String = "画面の検討案") -> TranscriptResult {
        TranscriptResult(text: audio, localeIdentifier: "ja-JP", sourceURL: sourceURL,
            segments: [TranscriptSegment(text: audio, timestamp: timestamp, duration: 3, speaker: .me)],
            screenSegments: [ScreenTranscriptSegment(text: screen, timestamp: 30, duration: 5)])
    }

    private func service(generator: EvidenceGenerator, limit: Int) -> PromptedTranscriptSummaryService {
        PromptedTranscriptSummaryService(promptBuilder: SummaryPromptBuilder(characterLimit: limit),
                                        availabilityChecker: EvidenceAvailability(), generator: generator)
    }
}

private struct EvidenceAvailability: SummaryAvailabilityChecking {
    nonisolated func currentAvailability() -> SummaryAvailability { .available }
}

private actor EvidenceGenerator: SummaryGenerating {
    var inputs: [TranscriptResult] = []
    var prompts: [SummaryPrompt] = []
    let includeClaims: Bool

    init(includeClaims: Bool = false) {
        self.includeClaims = includeClaims
    }

    func generate(prompt: SummaryPrompt, transcript: TranscriptResult) async throws -> MeetingSummary {
        inputs.append(transcript)
        prompts.append(prompt)
        let regex = try NSRegularExpression(pattern: "(?:audio|screen)-[0-9a-f]{16}")
        let text = prompt.prompt
        let ids = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted } + ["audio-invented"]
        let topics = includeClaims ? [MeetingTopic(title: "決定", evidenceIDs: unique)] : []
        let actions = includeClaims ? [MeetingActionItem(title: "確認", evidenceIDs: unique)] : []
        return MeetingSummary(summary: "要約", topics: topics, actionItems: actions,
                              transcriptSourceURL: transcript.sourceURL, evidenceIDs: unique)
    }
}
