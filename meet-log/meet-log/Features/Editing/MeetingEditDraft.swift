import Foundation

/// Value-only working copy. Timing, source identity and generation metadata are never editable.
nonisolated struct MeetingEditDraft: Equatable, Identifiable, Sendable {
    enum Original: Equatable, Sendable {
        case transcript(TranscriptResult)
        case summary(MeetingSummary)
    }

    let id = UUID()
    let original: Original
    var text: String
    var segmentTexts: [String] = []
    var screenTexts: [String] = []
    var participants: [MeetingParticipant] = []
    var segmentParticipantIDs: [UUID?] = []
    var topics: [MeetingTopic] = []
    var actionItems: [MeetingActionItem] = []

    init(transcript: TranscriptResult) {
        original = .transcript(transcript)
        text = transcript.text
        segmentTexts = transcript.segments.map(\.text)
        screenTexts = transcript.screenSegments.map(\.text)
        participants = transcript.participants
        segmentParticipantIDs = transcript.segments.map(\.participantID)
    }

    init(summary: MeetingSummary) {
        original = .summary(summary)
        text = summary.summary
        topics = summary.topics
        actionItems = summary.actionItems
    }

    var hasChanges: Bool {
        switch original {
        case .transcript(let value):
            return audioHasChanges(value) || screenTexts != value.screenSegments.map(\.text)
        case .summary(let value):
            return text != value.summary || topics != value.topics || actionItems != value.actionItems
        }
    }

    func editedTranscript(at date: Date = .now) -> TranscriptResult? {
        guard case .transcript(let value) = original,
              segmentTexts.count == value.segments.count,
              segmentParticipantIDs.count == value.segments.count,
              hasValidParticipants,
              screenTexts.count == value.screenSegments.count else {
            return nil
        }
        let segments = value.segments.enumerated().map { index, segment in
            TranscriptSegment(
                text: segmentTexts[index], timestamp: segment.timestamp, duration: segment.duration,
                speaker: segment.speaker, participantID: segmentParticipantIDs[index]
            )
        }
        let screenSegments = zip(value.screenSegments, screenTexts).map { segment, text in
            ScreenTranscriptSegment(text: text, timestamp: segment.timestamp, duration: segment.duration)
        }
        let audioChanged = audioHasChanges(value)
        // A timed transcript is edited exclusively through its segments. Derive the
        // aggregate used by search, export and summarization from the same values.
        return TranscriptResult(
            text: audioChanged ? updatedAudioText(value, segments: segments) : value.text,
            localeIdentifier: value.localeIdentifier, sourceURL: value.sourceURL,
            segments: segments, screenSegments: screenSegments, screenOCRReport: value.screenOCRReport,
            audioEditedAt: audioChanged ? date : value.audioEditedAt,
            screenEditedAt: screenTexts != value.screenSegments.map(\.text) ? date : value.screenEditedAt,
            participants: participants, transcriptionReport: value.transcriptionReport
        )
    }

    var hasValidParticipants: Bool {
        let ids = Set(participants.map(\.id))
        guard ids.count == participants.count,
              participants.allSatisfy({ !$0.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return false
        }

        return segmentParticipantIDs.compactMap { $0 }.allSatisfy { ids.contains($0) }
    }

    mutating func addParticipant(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return
        }

        participants.append(MeetingParticipant(displayName: name))
    }

    mutating func removeParticipant(_ id: UUID) {
        participants.removeAll { $0.id == id }
        segmentParticipantIDs = segmentParticipantIDs.map { $0 == id ? nil : $0 }
    }

    mutating func assignParticipant(_ id: UUID?, to indices: Set<Int>) {
        if let id, !participants.contains(where: { $0.id == id }) {
            return
        }

        for index in indices where segmentParticipantIDs.indices.contains(index) {
            segmentParticipantIDs[index] = id
        }
    }

    func editedSummary(at date: Date = .now) -> MeetingSummary? {
        guard case .summary(let value) = original else { return nil }
        return MeetingSummary(
            summary: text,
            topics: topics.map { topic in
                guard let original = value.topics.first(where: { $0.id == topic.id }),
                      original.title == topic.title, original.detail == topic.detail else {
                    return MeetingTopic(id: topic.id, title: topic.title, detail: topic.detail)
                }
                return topic
            },
            actionItems: actionItems.map { item in
                guard let original = value.actionItems.first(where: { $0.id == item.id }),
                      original.title == item.title, original.owner == item.owner,
                      original.dueDateText == item.dueDateText else {
                    return MeetingActionItem(id: item.id, title: item.title, owner: item.owner, dueDateText: item.dueDateText)
                }
                return item
            },
            transcriptSourceURL: value.transcriptSourceURL, createdAt: value.createdAt,
            templateID: value.templateID, templateName: value.templateName,
            inputFingerprint: value.inputFingerprint, editedAt: hasChanges ? date : value.editedAt,
            evidenceIDs: text == value.summary ? value.evidenceIDs : nil,
            evidenceInputFingerprint: value.evidenceInputFingerprint,
            transcriptionReport: value.transcriptionReport
        )
    }

    private func audioHasChanges(_ value: TranscriptResult) -> Bool {
        if participants != value.participants {
            return true
        }
        if segmentParticipantIDs != value.segments.map(\.participantID) {
            return true
        }
        if value.segments.isEmpty {
            return text != value.text
        }

        return segmentTexts != value.segments.map(\.text)
    }

    private func updatedAudioText(_ value: TranscriptResult, segments: [TranscriptSegment]) -> String {
        guard !segments.isEmpty else {
            return text
        }
        if segmentTexts != value.segments.map(\.text) {
            return TranscriptResult.audioText(segments: segments, participants: participants)
        }
        if segmentParticipantIDs != value.segments.map(\.participantID) {
            return TranscriptResult.audioText(segments: segments, participants: participants)
        }
        if segments.contains(where: { $0.participantID != nil }) {
            return TranscriptResult.audioText(segments: segments, participants: participants)
        }

        return value.text
    }
}
