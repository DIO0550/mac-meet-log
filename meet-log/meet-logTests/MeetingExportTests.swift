import Foundation
import Testing
@testable import meet_log

struct MeetingExportTests {
    @Test func markdownIncludesSelectedSummaryTranscriptAndNotes() {
        let document = exportDocument()
        let markdown = MeetingExportFormatter().markdown(
            for: document,
            sections: [.summary, .transcript, .notes]
        )

        #expect(markdown.contains("# 設計会議"))
        #expect(markdown.contains("## 要約"))
        #expect(markdown.contains("### 主要トピック"))
        #expect(markdown.contains("- [ ] 実装する（担当: 土居 / 期限: 明日）"))
        #expect(markdown.contains("- [00:03–00:05] **自分**: 案Aで進めます"))
        #expect(markdown.contains("- [00:12] リスクを確認"))
    }

    @Test func plainTextExcludesUnavailableAndUnselectedSections() {
        let document = MeetingExportDocument(
            title: "文字起こしのみ",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            summary: nil,
            transcript: exportDocument().transcript,
            notes: []
        )
        let text = MeetingExportFormatter().plainText(
            for: document,
            sections: [.summary, .transcript, .notes]
        )

        #expect(text.contains("文字起こし"))
        #expect(text.contains("自分: 案Aで進めます"))
        #expect(!text.contains("アクションアイテム"))
        #expect(!text.contains("\nメモ\n"))
        #expect(document.availableSections == [.transcript])
    }

    @Test func pdfPayloadProducesPDFData() throws {
        let payload = try MeetingExportFormatter().payload(
            for: exportDocument(),
            sections: [.summary],
            format: .pdf
        )

        #expect(String(decoding: payload.data.prefix(4), as: UTF8.self) == "%PDF")
        #expect(payload.text == nil)
    }

    @Test func payloadRejectsEmptyOrUnavailableSelection() {
        let document = MeetingExportDocument(
            title: "空",
            createdAt: .now,
            summary: nil,
            transcript: nil,
            notes: []
        )

        #expect(throws: MeetingExportError.self) {
            try MeetingExportFormatter().payload(
                for: document,
                sections: [.summary],
                format: .markdown
            )
        }
    }

    @Test func fileNameContainsRecordingTitleAndRequestedExtension() {
        let name = exportDocument().fileName(for: .markdown)

        #expect(name.contains("設計会議"))
        #expect(name.hasSuffix(".md"))
    }
}

private func exportDocument() -> MeetingExportDocument {
    MeetingExportDocument(
        title: "設計会議",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        summary: MeetingSummary(
            summary: "案Aを採用しました。",
            topics: [MeetingTopic(title: "設計", detail: "リスクを確認")],
            actionItems: [MeetingActionItem(title: "実装する", owner: "土居", dueDateText: "明日")],
            transcriptSourceURL: URL(fileURLWithPath: "/tmp/meeting.m4a")
        ),
        transcript: TranscriptResult(
            text: "案Aで進めます",
            localeIdentifier: "ja-JP",
            sourceURL: URL(fileURLWithPath: "/tmp/meeting.m4a"),
            segments: [
                TranscriptSegment(
                    text: "案Aで進めます",
                    timestamp: 3,
                    duration: 2,
                    speaker: .me
                )
            ]
        ),
        notes: [
            RecordingNote(
                elapsed: 12,
                text: "リスクを確認",
                createdAt: Date(timeIntervalSince1970: 1_800_000_012)
            )
        ]
    )
}
