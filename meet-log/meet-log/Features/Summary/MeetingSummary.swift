import Foundation

nonisolated struct MeetingSummary: Codable, Equatable, Sendable {
    let summary: String
    let topics: [MeetingTopic]
    let actionItems: [MeetingActionItem]
    let transcriptSourceURL: URL?
    let createdAt: Date
    let templateID: String?
    let templateName: String?
    let inputFingerprint: String?
    let editedAt: Date?
    let evidenceIDs: [String]?
    let evidenceInputFingerprint: String?

    nonisolated init(
        summary: String,
        topics: [MeetingTopic],
        actionItems: [MeetingActionItem],
        transcriptSourceURL: URL?,
        createdAt: Date = .now,
        templateID: String? = nil,
        templateName: String? = nil,
        inputFingerprint: String? = nil,
        editedAt: Date? = nil,
        evidenceIDs: [String]? = nil,
        evidenceInputFingerprint: String? = nil
    ) {
        self.summary = summary
        self.topics = topics
        self.actionItems = actionItems
        self.transcriptSourceURL = transcriptSourceURL
        self.createdAt = createdAt
        self.templateID = templateID
        self.templateName = templateName
        self.inputFingerprint = inputFingerprint
        self.editedAt = editedAt
        self.evidenceIDs = evidenceIDs
        self.evidenceInputFingerprint = evidenceInputFingerprint
    }

    nonisolated func recording(input: TranscriptResult) -> MeetingSummary {
        MeetingSummary(
            summary: summary, topics: topics, actionItems: actionItems,
            transcriptSourceURL: transcriptSourceURL, createdAt: createdAt,
            templateID: templateID, templateName: templateName,
            inputFingerprint: input.summaryInputFingerprint, editedAt: editedAt,
            evidenceIDs: evidenceIDs, evidenceInputFingerprint: evidenceInputFingerprint
        )
    }

    nonisolated func recording(template: SummaryTemplate) -> MeetingSummary {
        MeetingSummary(
            summary: summary,
            topics: topics,
            actionItems: actionItems,
            transcriptSourceURL: transcriptSourceURL,
            createdAt: createdAt,
            templateID: template.id,
            templateName: template.name,
            inputFingerprint: inputFingerprint, editedAt: editedAt,
            evidenceIDs: evidenceIDs, evidenceInputFingerprint: evidenceInputFingerprint
        )
    }
}

nonisolated struct MeetingTopic: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var detail: String?
    var evidenceIDs: [String]?

    nonisolated init(id: UUID = UUID(), title: String, detail: String? = nil, evidenceIDs: [String]? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.evidenceIDs = evidenceIDs
    }
}

nonisolated struct MeetingActionItem: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var owner: String?
    var dueDateText: String?
    var evidenceIDs: [String]?

    nonisolated init(
        id: UUID = UUID(),
        title: String,
        owner: String? = nil,
        dueDateText: String? = nil,
        evidenceIDs: [String]? = nil
    ) {
        self.id = id
        self.title = title
        self.owner = owner
        self.dueDateText = dueDateText
        self.evidenceIDs = evidenceIDs
    }
}

