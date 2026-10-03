import Foundation
import Testing
@testable import meet_log

struct MeetingEditingTests {
    @Test func segmentEditsKeepTimingSourcesAndCanonicalText() throws {
        let original = transcript()
        var draft = MeetingEditDraft(transcript: original)
        #expect(!draft.hasChanges)
        draft.segmentTexts[0] = "修正した人名\n## Segments"
        draft.screenTexts[0] = "画面の修正\n<!-- note -->"
        let edited = try #require(draft.editedTranscript(at: editDate))
        #expect(edited.text == "自分: 修正した人名\n## Segments\n相手: second")
        #expect(edited.segments.map(\.timestamp) == original.segments.map(\.timestamp))
        #expect(edited.segments.map(\.duration) == original.segments.map(\.duration))
        #expect(edited.segments.map(\.speaker) == [.me, .other])
        #expect(edited.screenSegments[0].timestamp == 7)
        #expect(edited.screenSegments[0].duration == 8)
        #expect(edited.screenOCRReport == original.screenOCRReport)
        #expect(edited.sourceURL == original.sourceURL)
        #expect(edited.audioEditedAt == editDate)
        #expect(edited.screenEditedAt == editDate)
        #expect(edited.summaryInputText.contains("画面の修正"))
        #expect(edited.summaryInputFingerprint != original.summaryInputFingerprint)
        #expect(try TranscriptMarkdownCodec.decode(TranscriptMarkdownCodec.encode(edited, recordingID: "a")) == edited)
        #expect(original.segments[0].text == "first")
    }

    @Test func textOnlyLegacyInputCanBeEditedWithoutInventingTimestamps() throws {
        let legacy = "# Transcript\n\n- Locale: ja-JP\n- Source: /tmp/a.m4a\n\n## Text\n\nold\n"
        let original = try TranscriptMarkdownCodec.decode(legacy)
        #expect(original.audioEditedAt == nil)
        var draft = MeetingEditDraft(transcript: original)
        draft.text = "\ncorrected\n## Screen OCR (auxiliary)\n"
        let edited = try #require(draft.editedTranscript(at: editDate))
        #expect(edited.segments.isEmpty)
        #expect(edited.text == draft.text)
        #expect(try TranscriptMarkdownCodec.decode(TranscriptMarkdownCodec.encode(edited, recordingID: "a")) == edited)
    }

    @Test func summaryEditsRoundTripSpecialCharactersAndIDs() throws {
        let legacy = "# Meeting Summary\n\n- Created: 2026-01-01T00:00:00.000Z\n\n## Summary\n\nold\n\n## Topics\n\n- topic: detail\n\n## Action Items\n\n- task (Owner: person, Due: tomorrow)\n"
        let original = try MeetingSummaryMarkdownCodec.decode(legacy)
        #expect(original.editedAt == nil)
        var draft = MeetingEditDraft(summary: original)
        draft.text = "## Summary\n\n訂正\n## Topics\n余白\n"
        draft.topics[0].title = "仕様: A (B)"
        draft.topics[0].detail = "一行目\n- 二行目"
        draft.actionItems[0].title = "対応 (案)\n詳細"
        draft.actionItems[0].owner = "土居, 山田"
        draft.actionItems[0].dueDateText = "金曜 (予定), 来週"
        let edited = try #require(draft.editedSummary(at: editDate))
        let decoded = try MeetingSummaryMarkdownCodec.decode(MeetingSummaryMarkdownCodec.encode(edited, recordingID: "a"))
        #expect(decoded == edited)
        #expect(decoded.topics[0].id == original.topics[0].id)
        #expect(decoded.actionItems[0].id == original.actionItems[0].id)
        #expect(decoded.createdAt == original.createdAt)
        #expect(decoded.editedAt == editDate)
        draft.text = ""
        draft.topics = []
        draft.actionItems = []
        let empty = try #require(draft.editedSummary(at: editDate))
        #expect(try MeetingSummaryMarkdownCodec.decode(MeetingSummaryMarkdownCodec.encode(empty, recordingID: "a")) == empty)
    }

    @Test func unchangedDraftsDoNotMarkGeneratedResultsAsManual() throws {
        let original = transcript()
        let draft = MeetingEditDraft(transcript: original)
        #expect(draft.editedTranscript(at: editDate) == original)
        var screenOnly = draft
        screenOnly.screenTexts[0] = "screen correction"
        let edited = try #require(screenOnly.editedTranscript(at: editDate))
        #expect(edited.text == original.text)
        #expect(edited.audioEditedAt == nil)
        #expect(edited.screenEditedAt == editDate)
        let regenerated = TranscriptResult(text: "new", localeIdentifier: "ja-JP", sourceURL: original.sourceURL)
            .retainingScreen(from: edited)
        #expect(regenerated.audioEditedAt == nil)
        #expect(regenerated.screenEditedAt == editDate)
        #expect(regenerated.screenSegments == edited.screenSegments)
    }

    @Test func corruptEditedPayloadFailsInsteadOfSilentlyLosingMetadata() {
        let invalid = "# Transcript\n\n<!-- transcript-edit-format: 1 -->\n\n## Text\n\nvisible\n\n<!-- transcript-data: broken -->\n"
        #expect(throws: (any Error).self) { try TranscriptMarkdownCodec.decode(invalid) }
        let summary = "# Meeting Summary\n\n<!-- summary-edit-format: 1 -->\n\n## Summary\n\nvisible\n"
        #expect(throws: (any Error).self) { try MeetingSummaryMarkdownCodec.decode(summary) }
    }

    private var editDate: Date { Date(timeIntervalSince1970: 1234) }

    private func transcript() -> TranscriptResult {
        TranscriptResult(
            text: "自分: first\n相手: second", localeIdentifier: "ja-JP", sourceURL: URL(fileURLWithPath: "/tmp/a.m4a"),
            segments: [
                TranscriptSegment(text: "first", timestamp: 1.25, duration: 2.5, speaker: .me),
                TranscriptSegment(text: "second", timestamp: 4, duration: 3, speaker: .other)
            ],
            screenSegments: [ScreenTranscriptSegment(text: "screen", timestamp: 7, duration: 8)],
            screenOCRReport: ScreenOCRReport(sampledFrames: 4, recognizedFrames: 1, elapsedSeconds: 2)
        )
    }
}
