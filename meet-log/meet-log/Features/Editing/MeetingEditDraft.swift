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
    var topics: [MeetingTopic] = []
    var actionItems: [MeetingActionItem] = []

    init(transcript: TranscriptResult) {
        original = .transcript(transcript)
        text = transcript.text
        segmentTexts = transcript.segments.map(\.text)
        screenTexts = transcript.screenSegments.map(\.text)
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
              screenTexts.count == value.screenSegments.count else {
            return nil
        }
        let segments = zip(value.segments, segmentTexts).map { segment, text in
            TranscriptSegment(text: text, timestamp: segment.timestamp, duration: segment.duration, speaker: segment.speaker)
        }
        let screenSegments = zip(value.screenSegments, screenTexts).map { segment, text in
            ScreenTranscriptSegment(text: text, timestamp: segment.timestamp, duration: segment.duration)
        }
        let audioChanged = audioHasChanges(value)
        // A timed transcript is edited exclusively through its segments. Derive the
        // aggregate used by search, export and summarization from the same values.
        let combinedText = segments.map { segment in
            guard let speaker = segment.speaker else { return segment.text }
            return "\(speaker.displayName): \(segment.text)"
        }.joined(separator: "\n")
        return TranscriptResult(
            text: audioChanged ? (segments.isEmpty ? text : combinedText) : value.text,
            localeIdentifier: value.localeIdentifier, sourceURL: value.sourceURL,
            segments: segments, screenSegments: screenSegments, screenOCRReport: value.screenOCRReport,
            audioEditedAt: audioChanged ? date : value.audioEditedAt,
            screenEditedAt: screenTexts != value.screenSegments.map(\.text) ? date : value.screenEditedAt
        )
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
            evidenceInputFingerprint: value.evidenceInputFingerprint
        )
    }

    private func audioHasChanges(_ value: TranscriptResult) -> Bool {
        value.segments.isEmpty ? text != value.text : segmentTexts != value.segments.map(\.text)
    }
}

