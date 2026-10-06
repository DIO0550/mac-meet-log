import Foundation

protocol MeetingSummaryStoring: Sendable {
    nonisolated func summary(for item: RecordingLibraryItem) async throws -> MeetingSummary?
    nonisolated func transcript(for item: RecordingLibraryItem) async throws -> TranscriptResult?
    nonisolated func save(_ summary: MeetingSummary, for item: RecordingLibraryItem) async throws
    nonisolated func save(_ transcript: TranscriptResult, for item: RecordingLibraryItem) async throws
}

extension MeetingSummaryStoring {
    nonisolated func transcript(for item: RecordingLibraryItem) async throws -> TranscriptResult? {
        nil
    }
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
            let markdown = try MeetingSummaryMarkdownCodec.encode(summary, recordingID: item.id)
            guard try MeetingSummaryMarkdownCodec.decode(markdown) == summary else {
                throw SummaryError.persistenceFailed("要約を保存形式に変換できません。")
            }
            try Task.checkCancellation()
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SummaryError.persistenceFailed(error.localizedDescription)
        }
    }

    nonisolated func transcript(for item: RecordingLibraryItem) async throws -> TranscriptResult? {
        let url = transcriptURL(for: item)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let markdown = try String(contentsOf: url, encoding: .utf8)
            return try TranscriptMarkdownCodec.decode(markdown)
        } catch {
            throw SummaryError.persistenceFailed(error.localizedDescription)
        }
    }

    nonisolated func save(_ transcript: TranscriptResult, for item: RecordingLibraryItem) async throws {
        do {
            let url = transcriptURL(for: item)
            let markdown = TranscriptMarkdownCodec.encode(transcript, recordingID: item.id)
            if transcript.audioEditedAt != nil || transcript.screenEditedAt != nil {
                guard try TranscriptMarkdownCodec.decode(markdown) == transcript else {
                    throw SummaryError.persistenceFailed("編集内容を保存形式に変換できません。")
                }
            }
            try Task.checkCancellation()
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch is CancellationError {
            throw CancellationError()
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
    // Version 1 stores the complete Codable model in a final JSON payload.
    // Retain the existing marker so edited/evidence sidecars remain compatible.
    nonisolated static func encode(_ summary: MeetingSummary, recordingID: String) throws -> String {
        let data = try JSONEncoder().encode(summary)
        var sections = renderedSections(summary, recordingID: recordingID)
        sections.insert("<!-- summary-edit-format: 1 -->", at: 1)
        sections.append("<!-- summary-data: \(data.base64EncodedString()) -->")

        return sections.joined(separator: "\n\n") + "\n"
    }

    private nonisolated static func renderedSections(_ summary: MeetingSummary, recordingID: String) -> [String] {
        var sections = [
            "# Meeting Summary",
            metadata(
                recordingID: recordingID,
                createdAt: summary.createdAt,
                transcriptSourceURL: summary.transcriptSourceURL,
                templateID: summary.templateID,
                templateName: summary.templateName,
                inputFingerprint: summary.inputFingerprint
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

        return sections
    }

    nonisolated static func decode(_ markdown: String) throws -> MeetingSummary {
        if markdown.hasPrefix("# Meeting Summary\n\n<!-- summary-edit-format: 1 -->\n") {
            return try EditedSidecarPayload.decode(MeetingSummary.self, named: "summary-data", from: markdown)
        }

        guard !markdown.hasPrefix("# Meeting Summary\n\n<!-- summary-edit-format:") else {
            throw SummaryError.persistenceFailed("未対応または不正な要約の保存形式です。")
        }

        // Unversioned Markdown is read-only legacy input. Migration happens only
        // when the user explicitly saves edits or regenerates the summary.
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
            createdAt: createdAt(from: markdown) ?? .now,
            templateID: metadataValue(named: "Template ID", in: markdown),
            templateName: metadataValue(named: "Template", in: markdown),
            inputFingerprint: metadataValue(named: "Input SHA256", in: markdown)
        )
    }

    private nonisolated static func metadata(
        recordingID: String,
        createdAt: Date,
        transcriptSourceURL: URL?,
        templateID: String?,
        templateName: String?,
        inputFingerprint: String?
    ) -> String {
        var lines = [
            "- Recording: \(recordingID)",
            "- Created: \(Self.dateFormatter.string(from: createdAt))"
        ]

        if let transcriptSourceURL {
            lines.append("- Source: \(transcriptSourceURL.path)")
        }
        if let templateID {
            lines.append("- Template ID: \(templateID)")
        }
        if let templateName {
            lines.append("- Template: \(templateName)")
        }

        if let inputFingerprint {
            lines.append("- Input SHA256: \(inputFingerprint)")
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
        sections.append("## Text\n\n\(transcript.audioText)")
        if !transcript.segments.isEmpty {
            sections.append(
                """
                ## Segments

                \(transcript.segments.map { segmentLine($0, transcript: transcript) }.joined(separator: "\n"))
                """
            )
        }
        if !transcript.screenSegments.isEmpty {
            sections.append("## Screen OCR (auxiliary)\n\n" + transcript.screenText)
        }
        if let data = try? JSONEncoder().encode(transcript) {
            sections.append("<!-- transcript-data: \(data.base64EncodedString()) -->")
        }
        if transcript.audioEditedAt != nil || transcript.screenEditedAt != nil || !transcript.participants.isEmpty {
            sections.insert("<!-- transcript-edit-format: 1 -->", at: 1)
        }

        return sections.joined(separator: "\n\n") + "\n"
    }

    nonisolated static func decode(_ markdown: String) throws -> TranscriptResult {
        if markdown.hasPrefix("# Transcript\n\n<!-- transcript-edit-format: 1 -->\n") {
            return try EditedSidecarPayload.decode(TranscriptResult.self, named: "transcript-data", from: markdown)
        }
        if let encoded = metadataValue(named: "transcript-data", in: markdown),
           let data = Data(base64Encoded: encoded),
           let transcript = try? JSONDecoder().decode(TranscriptResult.self, from: data) {
            // The visible text is editable; embedded JSON supplies timing and OCR metadata.
            guard let text = sectionBody(named: "Text", in: markdown)?
                .trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw SummaryError.persistenceFailed("Transcript markdown is missing the text section.")
            }
            guard text != transcript.audioText.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return transcript
            }
            return TranscriptResult(
                text: text, localeIdentifier: transcript.localeIdentifier,
                sourceURL: transcript.sourceURL, segments: [],
                screenSegments: transcript.screenSegments, screenOCRReport: transcript.screenOCRReport,
                audioEditedAt: transcript.audioEditedAt, screenEditedAt: transcript.screenEditedAt,
                participants: transcript.participants
            )
        }

        guard let text = sectionBody(named: "Text", in: markdown)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw SummaryError.persistenceFailed("Transcript markdown is missing the text section.")
        }

        let localeIdentifier = lineValue(named: "Locale", in: markdown) ?? "ja-JP"
        let sourcePath = lineValue(named: "Source", in: markdown) ?? "/"
        return TranscriptResult(
            text: text,
            localeIdentifier: localeIdentifier,
            sourceURL: URL(fileURLWithPath: sourcePath)
        )
    }

    private nonisolated static func segmentLine(_ segment: TranscriptSegment, transcript: TranscriptResult) -> String {
        let speaker = transcript.speakerName(for: segment) ?? "話者不明"
        return "- [\(segment.timeRangeText)] **\(speaker)**: \(segment.text)"
    }

    private nonisolated static func metadataValue(named key: String, in markdown: String) -> String? {
        let prefix = "<!-- \(key): "
        return markdown
            .components(separatedBy: .newlines)
            .first { $0.hasPrefix(prefix) && $0.hasSuffix(" -->") }
            .map { String($0.dropFirst(prefix.count).dropLast(" -->".count)) }
    }

    private nonisolated static func lineValue(named key: String, in markdown: String) -> String? {
        let prefix = "- \(key): "
        return markdown
            .components(separatedBy: .newlines)
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    private nonisolated static func sectionBody(named name: String, in markdown: String) -> String? {
        let lines = markdown.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(of: "## \(name)") else {
            return nil
        }
        let body = lines.dropFirst(start + 1).prefix {
            $0 != "## Segments" && $0 != "## Screen OCR (auxiliary)" && !$0.hasPrefix("<!-- transcript-data: ")
        }
        return body.joined(separator: "\n")
    }
}

private enum EditedSidecarPayload {
    nonisolated static func decode<Value: Decodable>(_ type: Value.Type, named name: String, from markdown: String) throws -> Value {
        let prefix = "<!-- \(name): "
        let lines = markdown.components(separatedBy: .newlines)
        guard let line = lines.last(where: { !$0.isEmpty }),
              line.hasPrefix(prefix), line.hasSuffix(" -->"),
              let data = Data(base64Encoded: String(line.dropFirst(prefix.count).dropLast(4))) else {
            throw SummaryError.persistenceFailed("編集データを読み込めません。ファイルを確認してください。")
        }
        return try JSONDecoder().decode(type, from: data)
    }
}
