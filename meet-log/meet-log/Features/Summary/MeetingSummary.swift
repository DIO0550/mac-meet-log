import Foundation

nonisolated struct MeetingSummary: Codable, Equatable, Sendable {
    let summary: String
    let topics: [MeetingTopic]
    let actionItems: [MeetingActionItem]
    let transcriptSourceURL: URL?
    let createdAt: Date
    let templateID: String?
    let templateName: String?

    nonisolated init(
        summary: String,
        topics: [MeetingTopic],
        actionItems: [MeetingActionItem],
        transcriptSourceURL: URL?,
        createdAt: Date = .now,
        templateID: String? = nil,
        templateName: String? = nil
    ) {
        self.summary = summary
        self.topics = topics
        self.actionItems = actionItems
        self.transcriptSourceURL = transcriptSourceURL
        self.createdAt = createdAt
        self.templateID = templateID
        self.templateName = templateName
    }

    nonisolated func recording(template: SummaryTemplate) -> MeetingSummary {
        MeetingSummary(
            summary: summary,
            topics: topics,
            actionItems: actionItems,
            transcriptSourceURL: transcriptSourceURL,
            createdAt: createdAt,
            templateID: template.id,
            templateName: template.name
        )
    }
}

nonisolated struct MeetingTopic: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let detail: String?

    nonisolated init(id: UUID = UUID(), title: String, detail: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

nonisolated struct MeetingActionItem: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let owner: String?
    let dueDateText: String?

    nonisolated init(
        id: UUID = UUID(),
        title: String,
        owner: String? = nil,
        dueDateText: String? = nil
    ) {
        self.id = id
        self.title = title
        self.owner = owner
        self.dueDateText = dueDateText
    }
}
