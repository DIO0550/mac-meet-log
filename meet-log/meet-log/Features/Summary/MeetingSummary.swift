import Foundation

nonisolated struct MeetingSummary: Codable, Equatable, Sendable {
    let summary: String
    let topics: [MeetingTopic]
    let actionItems: [MeetingActionItem]
    let transcriptSourceURL: URL?
    let createdAt: Date

    nonisolated init(
        summary: String,
        topics: [MeetingTopic],
        actionItems: [MeetingActionItem],
        transcriptSourceURL: URL?,
        createdAt: Date = .now
    ) {
        self.summary = summary
        self.topics = topics
        self.actionItems = actionItems
        self.transcriptSourceURL = transcriptSourceURL
        self.createdAt = createdAt
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
