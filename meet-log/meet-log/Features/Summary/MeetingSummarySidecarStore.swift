import Foundation

protocol MeetingSummaryStoring: Sendable {
    nonisolated func summary(for item: RecordingLibraryItem) async throws -> MeetingSummary?
    nonisolated func save(_ summary: MeetingSummary, for item: RecordingLibraryItem) async throws
    nonisolated func save(_ transcript: TranscriptResult, for item: RecordingLibraryItem) async throws
}

struct MeetingSummarySidecarStore: MeetingSummaryStoring {
    nonisolated func summary(for item: RecordingLibraryItem) async throws -> MeetingSummary? {
        let url = summaryURL(for: item)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let markdown = try String(contentsOf: url, encoding: .utf8)
            return try MeetingSummaryMarkdownCodec.decode(markdown)
        } catch {
            throw SummaryError.persistenceFailed(error.localizedDescription)
        }
    }

    nonisolated func save(_ summary: MeetingSummary, for item: RecordingLibraryItem) async throws {
        do {
            let url = summaryURL(for: item)
            let markdown = MeetingSummaryMarkdownCodec.encode(summary, recordingID: item.id)
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw SummaryError.persistenceFailed(error.localizedDescription)
        }
    }

    nonisolated func save(_ transcript: TranscriptResult, for item: RecordingLibraryItem) async throws {
        do {
            let url = transcriptURL(for: item)
            let markdown = TranscriptMarkdownCodec.encode(transcript, recordingID: item.id)
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw SummaryError.persistenceFailed(error.localizedDescription)
        }
    }

    private nonisolated func summaryURL(for item: RecordingLibraryItem) -> URL {
        item.mixdownURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(item.id)_summary.md", isDirectory: false)
    }

    private nonisolated func transcriptURL(for item: RecordingLibraryItem) -> URL {
        item.mixdownURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(item.id)_transcript.md", isDirectory: false)
    }
}

enum MeetingSummaryMarkdownCodec {
    nonisolated static func encode(_ summary: MeetingSummary, recordingID: String) -> String {
        var sections = [
            "# Meeting Summary",
            metadata(
                recordingID: recordingID,
                createdAt: summary.createdAt,
                transcriptSourceURL: summary.transcriptSourceURL
            ),
            "## Summary\n\n\(summary.summary)"
        ]

        if !summary.topics.isEmpty {
            sections.append(
                """
                ## Topics

                \(summary.topics.map(topicLine).joined(separator: "\n"))
                """
            )
        }

        if !summary.actionItems.isEmpty {
            sections.append(
                """
                ## Action Items

                \(summary.actionItems.map(actionItemLine).joined(separator: "\n"))
                """
            )
        }

        return sections.joined(separator: "\n\n") + "\n"
    }

    nonisolated static func decode(_ markdown: String) throws -> MeetingSummary {
        let sections = sectionBodies(from: markdown)
        guard let summaryText = sections["Summary"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summaryText.isEmpty else {
            throw SummaryError.persistenceFailed("Summary markdown is missing the summary section.")
        }

        return MeetingSummary(
            summary: summaryText,
            topics: decodeTopics(from: sections["Topics"]),
            actionItems: decodeActionItems(from: sections["Action Items"]),
            transcriptSourceURL: transcriptSourceURL(from: markdown),
            createdAt: createdAt(from: markdown) ?? .now
        )
    }

    private nonisolated static func metadata(
        recordingID: String,
        createdAt: Date,
        transcriptSourceURL: URL?
    ) -> String {
        var lines = [
            "- Recording: \(recordingID)",
            "- Created: \(Self.dateFormatter.string(from: createdAt))"
        ]

        if let transcriptSourceURL {
            lines.append("- Source: \(transcriptSourceURL.path)")
        }

        return lines.joined(separator: "\n")
    }

    private nonisolated static func topicLine(_ topic: MeetingTopic) -> String {
        guard let detail = topic.detail, !detail.isEmpty else {
            return "- \(topic.title)"
        }

        return "- \(topic.title): \(detail)"
    }

    private nonisolated static func actionItemLine(_ item: MeetingActionItem) -> String {
        var details = [String]()
        if let owner = item.owner, !owner.isEmpty {
            details.append("Owner: \(owner)")
        }
        if let dueDateText = item.dueDateText, !dueDateText.isEmpty {
            details.append("Due: \(dueDateText)")
        }

        guard !details.isEmpty else {
            return "- \(item.title)"
        }

        return "- \(item.title) (\(details.joined(separator: ", ")))"
    }

    private nonisolated static func sectionBodies(from markdown: String) -> [String: String] {
        var sections = [String: [String]]()
        var currentTitle: String?

        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                currentTitle = String(line.dropFirst(3))
                sections[currentTitle!, default: []] = []
                continue
            }

            guard let currentTitle else {
                continue
            }

            sections[currentTitle, default: []].append(line)
        }

        return sections.mapValues { $0.joined(separator: "\n") }
    }

    private nonisolated static func decodeTopics(from body: String?) -> [MeetingTopic] {
        bulletLines(from: body).map { line in
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                return MeetingTopic(
                    title: parts[0].trimmingCharacters(in: .whitespaces),
                    detail: parts[1].trimmingCharacters(in: .whitespaces)
                )
            }

            return MeetingTopic(title: line)
        }
    }

    private nonisolated static func decodeActionItems(from body: String?) -> [MeetingActionItem] {
        bulletLines(from: body).map { line in
            guard let metadataStart = line.lastIndex(of: "("),
                  line.hasSuffix(")") else {
                return MeetingActionItem(title: line)
            }

            let title = String(line[..<metadataStart]).trimmingCharacters(in: .whitespaces)
            let metadata = line[line.index(after: metadataStart)..<line.index(before: line.endIndex)]
            var owner: String?
            var dueDateText: String?

            for part in metadata.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                if part.hasPrefix("Owner: ") {
                    owner = String(part.dropFirst("Owner: ".count))
                } else if part.hasPrefix("Due: ") {
                    dueDateText = String(part.dropFirst("Due: ".count))
                }
            }

            return MeetingActionItem(title: title, owner: owner, dueDateText: dueDateText)
        }
    }

    private nonisolated static func bulletLines(from body: String?) -> [String] {
        body?
            .components(separatedBy: .newlines)
            .compactMap { line in
                guard line.hasPrefix("- ") else {
                    return nil
                }

                return String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? []
    }

    private nonisolated static func transcriptSourceURL(from markdown: String) -> URL? {
        metadataValue(named: "Source", in: markdown).map { URL(fileURLWithPath: $0) }
    }

    private nonisolated static func createdAt(from markdown: String) -> Date? {
        metadataValue(named: "Created", in: markdown).flatMap(dateFormatter.date)
    }

    private nonisolated static func metadataValue(named key: String, in markdown: String) -> String? {
        markdown
            .components(separatedBy: .newlines)
            .first { $0.hasPrefix("- \(key): ") }
            .map { String($0.dropFirst("- \(key): ".count)) }
    }

    private static var dateFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

enum TranscriptMarkdownCodec {
    nonisolated static func encode(_ transcript: TranscriptResult, recordingID: String) -> String {
        var sections = [
            "# Transcript",
            """
            - Recording: \(recordingID)
            - Locale: \(transcript.localeIdentifier)
            """
        ]

        sections[1] += "\n- Source: \(transcript.sourceURL.path)"
        sections.append("## Text\n\n\(transcript.text)")

        return sections.joined(separator: "\n\n") + "\n"
    }
}
