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
    let transcriptionReport: TranscriptionReport?
    let generation: SummaryGeneration?

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
        evidenceInputFingerprint: String? = nil,
        transcriptionReport: TranscriptionReport? = nil,
        generation: SummaryGeneration? = nil
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
        self.transcriptionReport = transcriptionReport
        self.generation = generation
    }

    nonisolated func recording(input: TranscriptResult) -> MeetingSummary {
        MeetingSummary(
            summary: summary, topics: topics, actionItems: actionItems,
            transcriptSourceURL: transcriptSourceURL, createdAt: createdAt,
            templateID: templateID, templateName: templateName,
            inputFingerprint: input.summaryInputFingerprint, editedAt: editedAt,
            evidenceIDs: evidenceIDs, evidenceInputFingerprint: evidenceInputFingerprint,
            transcriptionReport: input.transcriptionReport, generation: generation
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
            evidenceIDs: evidenceIDs, evidenceInputFingerprint: evidenceInputFingerprint,
            transcriptionReport: transcriptionReport,
            generation: SummaryGeneration(method: .foundationModels, templateApplied: true, actionItemsExtracted: true)
        )
    }

    nonisolated func recording(fallbackReason: SummaryUnavailableReason) -> MeetingSummary {
        var metadata = generation ?? SummaryGeneration(method: .unknown, templateApplied: false, actionItemsExtracted: false)
        metadata.fallbackReason = fallbackReason
        return MeetingSummary(
            summary: summary, topics: topics, actionItems: actionItems,
            transcriptSourceURL: transcriptSourceURL, createdAt: createdAt,
            templateID: metadata.templateApplied ? templateID : nil,
            templateName: metadata.templateApplied ? templateName : nil,
            inputFingerprint: inputFingerprint, editedAt: editedAt,
            evidenceIDs: evidenceIDs, evidenceInputFingerprint: evidenceInputFingerprint,
            transcriptionReport: transcriptionReport, generation: metadata
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

// Optional on MeetingSummary so pre-existing JSON and Markdown remain readable
// without inferring how an old summary was generated.
nonisolated struct SummaryGeneration: Codable, Equatable, Sendable {
    enum Method: String, Codable, Sendable {
        case foundationModels
        case extractive
        case unknown
    }

    let method: Method
    let templateApplied: Bool
    let actionItemsExtracted: Bool
    var fallbackReason: SummaryUnavailableReason? = nil

    var description: String {
        var lines: [String]
        switch method {
        case .foundationModels:
            lines = ["生成方式: Apple Foundation Models"]
        case .extractive:
            lines = ["生成方式: 簡易抽出", "文字起こしの冒頭から文を抜き出しています。"]
        case .unknown:
            lines = ["生成方式: 不明"]
        }
        if let fallbackReason {
            lines.append("切り替え理由: \(fallbackReason.localizedDescription)")
        }
        if !templateApplied {
            lines.append("テンプレートの指示は適用していません。")
        }
        if !actionItemsExtracted {
            lines.append("TODO抽出は未実施です。会議にTODOがないことを意味しません。")
        }
        return lines.joined(separator: "\n")
    }
}
