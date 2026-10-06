import Foundation
import Testing
@testable import meet_log

struct ManualSpeakerTests {
    @Test func bulkAndIndividualAssignmentsKeepInputSourcesAndTiming() throws {
        let original = transcript()
        var draft = MeetingEditDraft(transcript: original)
        draft.addParticipant(named: " 土居 ")
        draft.addParticipant(named: "山田")
        let doi = draft.participants[0].id
        let yamada = draft.participants[1].id
        draft.assignParticipant(doi, to: [0, 1, 2])
        draft.assignParticipant(yamada, to: [1])
        draft.assignParticipant(nil, to: [2])
        let edited = try #require(draft.editedTranscript())

        #expect(edited.segments.map(\.participantID) == [doi, yamada, nil])
        #expect(edited.segments.map(\.speaker) == original.segments.map(\.speaker))
        #expect(edited.segments.map(\.timestamp) == original.segments.map(\.timestamp))
        #expect(edited.segments.map(\.duration) == original.segments.map(\.duration))
        #expect(edited.text == "土居: first\n山田: second\n自分: third")
        #expect(original.participants.isEmpty)
        #expect(original.segments.allSatisfy { $0.participantID == nil })
        #expect(edited.audioEditedAt != nil)
    }

    @Test func renamingAndDeletingParticipantsUpdateEveryAssignedSegment() throws {
        var draft = MeetingEditDraft(transcript: transcript())
        draft.addParticipant(named: "土居")
        let id = draft.participants[0].id
        draft.assignParticipant(id, to: [0, 1])
        let assigned = try #require(draft.editedTranscript())
        var renamedDraft = MeetingEditDraft(transcript: assigned)
        renamedDraft.participants[0].displayName = "土居 孝史"
        let renamed = try #require(renamedDraft.editedTranscript())
        #expect(renamed.audioText == "土居 孝史: first\n土居 孝史: second\n自分: third")
        #expect(renamed.summaryInputFingerprint != assigned.summaryInputFingerprint)
        let oldCatalog = SummaryEvidenceCatalog(assigned)
        let newCatalog = SummaryEvidenceCatalog(renamed)
        #expect(newCatalog.resolve(Array(oldCatalog.ids), fingerprint: oldCatalog.fingerprint).isEmpty)

        renamedDraft.removeParticipant(id)
        let removed = try #require(renamedDraft.editedTranscript())
        #expect(removed.participants.isEmpty)
        #expect(removed.segments.allSatisfy { $0.participantID == nil })
        #expect(removed.audioText == transcript().text)
    }

    @Test func namesAndAssignmentsRoundTripThroughJSONAndMarkdown() throws {
        var draft = MeetingEditDraft(transcript: transcript())
        draft.addParticipant(named: "土居 (設計): ## A <!-- note -->")
        draft.assignParticipant(draft.participants[0].id, to: [1])
        let edited = try #require(draft.editedTranscript())
        #expect(try JSONDecoder().decode(TranscriptResult.self, from: JSONEncoder().encode(edited)) == edited)
        let markdown = TranscriptMarkdownCodec.encode(edited, recordingID: "test")
        #expect(markdown.contains("**土居 (設計): ## A <!-- note -->**: second"))
        #expect(try TranscriptMarkdownCodec.decode(markdown) == edited)
        #expect(MeetingEditDraft(transcript: edited).editedTranscript() == edited)
    }

    @Test func oldTrackLabelsDecodeAndUnassignedNamesDoNotChangeInput() throws {
        let json = """
        {"text":"相手: first","localeIdentifier":"ja-JP","sourceURL":"file:///tmp/a.m4a",
         "segments":[{"text":"first","timestamp":1,"duration":2,"speaker":"other"}]}
        """
        let old = try JSONDecoder().decode(TranscriptResult.self, from: Data(json.utf8))
        #expect(old.participants.isEmpty)
        #expect(old.segments[0].participantID == nil)
        #expect(old.speakerName(for: old.segments[0]) == "相手")
        #expect(MeetingEditDraft(transcript: old).editedTranscript() == old)
        #expect(try TranscriptMarkdownCodec.decode(TranscriptMarkdownCodec.encode(old, recordingID: "test")) == old)

        var draft = MeetingEditDraft(transcript: old)
        draft.addParticipant(named: "土居")
        let edited = try #require(draft.editedTranscript())
        #expect(edited.summaryInputText == old.summaryInputText)
        #expect(edited.summaryInputFingerprint == old.summaryInputFingerprint)
    }

    @Test func danglingAndBlankNamesFallBackToTrackLabels() {
        let participant = MeetingParticipant(displayName: "   ")
        let input = TranscriptResult(text: "old", localeIdentifier: "ja-JP", sourceURL: sourceURL,
            segments: [
                TranscriptSegment(text: "first", timestamp: 0, duration: 1, speaker: .other, participantID: UUID()),
                TranscriptSegment(text: "second", timestamp: 1, duration: 1, speaker: .me, participantID: participant.id),
                TranscriptSegment(text: "unknown", timestamp: 2, duration: 1)
            ], participants: [participant])
        #expect(input.speakerName(for: input.segments[0]) == "相手")
        #expect(input.speakerName(for: input.segments[1]) == "自分")
        #expect(input.speakerName(for: input.segments[2]) == nil)
        #expect(input.audioText == "相手: first\n自分: second\nunknown")
    }

    @Test func blankParticipantNamesCannotBeSavedAndInvalidAssignmentsAreIgnored() {
        var draft = MeetingEditDraft(transcript: transcript())
        draft.addParticipant(named: " \n ")
        #expect(draft.participants.isEmpty)
        draft.assignParticipant(UUID(), to: [0])
        #expect(!draft.hasChanges)
        draft.addParticipant(named: "土居")
        draft.assignParticipant(draft.participants[0].id, to: [-1, 99])
        #expect(draft.segmentParticipantIDs.allSatisfy { $0 == nil })
        draft.participants[0].displayName = " "
        #expect(!draft.hasValidParticipants)
        #expect(draft.editedTranscript() == nil)
    }

    @Test func exportAndBothSummaryInputsUseManualNamesWithFallbacks() throws {
        var draft = MeetingEditDraft(transcript: transcript())
        draft.addParticipant(named: "山田")
        draft.assignParticipant(draft.participants[0].id, to: [0])
        let edited = try #require(draft.editedTranscript())
        let document = MeetingExportDocument(title: "会議", createdAt: .now, summary: nil, transcript: edited, notes: [])
        let formatter = MeetingExportFormatter()
        #expect(formatter.markdown(for: document, sections: [.transcript]).contains("**山田**: first"))
        #expect(formatter.plainText(for: document, sections: [.transcript]).contains("山田: first"))
        #expect(formatter.plainText(for: document, sections: [.transcript]).contains("相手: second"))
        #expect(edited.summaryInputText.contains("山田: first"))
        let prompt = try SummaryPromptBuilder().makePrompt(for: edited).get()
        #expect(prompt.prompt.contains("山田: first"))
        #expect(prompt.prompt.contains("相手: second"))
        let chunks = try SummaryEvidenceChunker(characterLimit: 200).split(edited)
        #expect(chunks.map(\.text).joined().contains("山田: first"))
        #expect(chunks.map(\.text).joined().contains("相手: second"))
    }

    @Test func invalidTimesStillKeepAssignedNamesInSummaryInput() throws {
        let participant = MeetingParticipant(displayName: "山田")
        let input = TranscriptResult(text: "old", localeIdentifier: "ja-JP", sourceURL: sourceURL,
            segments: [TranscriptSegment(text: "first", timestamp: -1, duration: 1,
                                         speaker: .other, participantID: participant.id)],
            participants: [participant])
        #expect(SummaryEvidenceCatalog(input).entries.isEmpty)
        #expect(SummaryEvidenceCatalog.modelInput(input).contains("山田: first"))
        #expect(try SummaryEvidenceChunker(characterLimit: 200).split(input).first?.text.contains("山田: first") == true)
    }

    private var sourceURL: URL { URL(fileURLWithPath: "/tmp/a.m4a") }

    private func transcript() -> TranscriptResult {
        TranscriptResult(text: "相手: first\n相手: second\n自分: third", localeIdentifier: "ja-JP", sourceURL: sourceURL,
            segments: [
                TranscriptSegment(text: "first", timestamp: 1, duration: 2, speaker: .other),
                TranscriptSegment(text: "second", timestamp: 3, duration: 2, speaker: .other),
                TranscriptSegment(text: "third", timestamp: 5, duration: 2, speaker: .me)
            ])
    }
}
