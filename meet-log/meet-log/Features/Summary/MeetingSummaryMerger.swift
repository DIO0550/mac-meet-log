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
                topics[index] = MeetingTopic(id: previous.id, title: previous.title, detail: details.joined(separator: "\n"))
                continue
            }
            topicIndexes[key] = topics.count
            topics.append(topic)
        }

        var actionKeys = Set<[String]>()
        let actions = summary.actionItems.filter { item in
            // Different owners or deadlines can describe distinct tasks; do not collapse them.
            actionKeys.insert([normalized(item.title), normalized(item.owner ?? ""), normalized(item.dueDateText ?? "")]).inserted
        }
        return MeetingSummary(
            summary: summary.summary,
            topics: topics,
            actionItems: actions,
            transcriptSourceURL: summary.transcriptSourceURL,
            createdAt: summary.createdAt,
            templateID: summary.templateID,
            templateName: summary.templateName
        )
    }

    static func integrationText(_ summaries: [MeetingSummary]) -> String {
        summaries.enumerated().map { index, summary in
            let summary = removingDuplicates(summary)
            let topics = summary.topics.map { "- \($0.title): \($0.detail ?? "")" }.joined(separator: "\n")
            let actions = summary.actionItems.map {
                "- \($0.title) / 担当: \($0.owner ?? "不明") / 期限: \($0.dueDateText ?? "不明")"
            }.joined(separator: "\n")
            return "中間要約 \(index + 1)\n\(summary.summary)\nトピック:\n\(topics)\nアクション:\n\(actions)"
        }.joined(separator: "\n\n")
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
