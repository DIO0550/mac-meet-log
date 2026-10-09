import Foundation

nonisolated enum MeetingSummaryMerger {
    static func removingDuplicates(_ summary: MeetingSummary) -> MeetingSummary {
        var topics: [MeetingTopic] = []
        var topicIndexes: [String: Int] = [:]
        for topic in summary.topics {
            let key = normalized(topic.title)
            if let index = topicIndexes[key] {
                let previous = topics[index]
                let details = unique([previous.detail, topic.detail].compactMap { $0 })
                topics[index] = MeetingTopic(id: previous.id, title: previous.title, detail: details.joined(separator: "\n"),
                                            evidenceIDs: evidenceUnion(previous.evidenceIDs, topic.evidenceIDs))
                continue
            }
            topicIndexes[key] = topics.count
            topics.append(topic)
        }

        var actions: [MeetingActionItem] = []
        var actionIndexes: [[String]: Int] = [:]
        for item in summary.actionItems {
            // Different owners or deadlines can describe distinct tasks.
            let key = [normalized(item.title), normalized(item.owner ?? ""), normalized(item.dueDateText ?? "")]
            if let index = actionIndexes[key] {
                actions[index].evidenceIDs = evidenceUnion(actions[index].evidenceIDs, item.evidenceIDs)
                continue
            }
            actionIndexes[key] = actions.count
            actions.append(item)
        }
        return MeetingSummary(
            summary: summary.summary,
            topics: topics,
            actionItems: actions,
            transcriptSourceURL: summary.transcriptSourceURL,
            createdAt: summary.createdAt,
            templateID: summary.templateID,
            templateName: summary.templateName,
            inputFingerprint: summary.inputFingerprint, editedAt: summary.editedAt,
            evidenceIDs: summary.evidenceIDs, evidenceInputFingerprint: summary.evidenceInputFingerprint,
            transcriptionReport: summary.transcriptionReport, generation: summary.generation
        )
    }

    static func integrationText(_ summaries: [MeetingSummary]) -> String {
        summaries.enumerated().map { index, summary in
            let summary = removingDuplicates(summary)
            let topics = summary.topics.map { "- \($0.title): \($0.detail ?? "")" + evidenceText($0.evidenceIDs) }.joined(separator: "\n")
            let actions = summary.actionItems.map {
                "- \($0.title) / 担当: \($0.owner ?? "不明") / 期限: \($0.dueDateText ?? "不明")" + evidenceText($0.evidenceIDs)
            }.joined(separator: "\n")
            return "中間要約 \(index + 1)\n\(summary.summary)\(evidenceText(summary.evidenceIDs))\nトピック:\n\(topics)\nアクション:\n\(actions)"
        }.joined(separator: "\n\n")
    }

    static func evidenceUnion(_ first: [String]?, _ second: [String]?) -> [String]? {
        guard first != nil || second != nil else {
            return nil
        }
        var seen = Set<String>()
        return ((first ?? []) + (second ?? [])).filter { seen.insert($0).inserted }
    }

    private static func evidenceText(_ ids: [String]?) -> String {
        let confirmed = (ids ?? []).filter { $0 != "unconfirmed" }
        guard !confirmed.isEmpty else {
            return ""
        }
        return " [根拠: \(confirmed.joined(separator: ", "))]"
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert(normalized($0)).inserted }
    }
}

