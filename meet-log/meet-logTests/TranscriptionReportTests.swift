import Foundation
import PDFKit
import Testing
@testable import meet_log

struct TranscriptionReportTests {
    private let sourceURL = URL(fileURLWithPath: "/tmp/meeting_microphone.m4a")
    private let report = TranscriptionReport(
        coverage: .partial,
        trackIssues: [.init(speaker: .other, reason: .processingFailed, message: "recognition failed")],
        mixdownFailure: "mix unavailable"
    )

    @Test func reportSurvivesTranscriptAndSummarySidecarsAndManualEdits() throws {
        let input = transcript()
        let markdown = TranscriptMarkdownCodec.encode(input, recordingID: "meeting")
        #expect(markdown.contains(report.warningText))
        #expect(try TranscriptMarkdownCodec.decode(markdown) == input)

        let externalEdit = markdown.replacingOccurrences(of: "## Text\n\n自分: 残った発言", with: "## Text\n\n修正した発言")
        #expect(try TranscriptMarkdownCodec.decode(externalEdit).transcriptionReport == report)

        var draft = MeetingEditDraft(transcript: input)
        draft.segmentTexts[0] = "修正した発言"
        let edited = try #require(draft.editedTranscript())
        #expect(edited.transcriptionReport == report)
        #expect(try TranscriptMarkdownCodec.decode(TranscriptMarkdownCodec.encode(edited, recordingID: "meeting")) == edited)

        let summary = MeetingSummary(summary: "残った発言の要約", topics: [], actionItems: [], transcriptSourceURL: sourceURL)
            .recording(input: input).recording(template: .builtIn)
        let summaryMarkdown = try MeetingSummaryMarkdownCodec.encode(summary, recordingID: "meeting")
        #expect(summaryMarkdown.contains(report.warningText))
        #expect(try MeetingSummaryMarkdownCodec.decode(summaryMarkdown) == summary)
        var summaryDraft = MeetingEditDraft(summary: summary)
        summaryDraft.text = "修正した要約"
        #expect(summaryDraft.editedSummary()?.transcriptionReport == report)
        #expect(MeetingSummaryMerger.removingDuplicates(summary).transcriptionReport == report)
        #expect(summary.restrictingEvidence(to: []).transcriptionReport == report)
    }

    @Test func metadataDoesNotPretendToBeSpeechAndChangesSummaryFingerprint() throws {
        let input = transcript()
        let complete = input.recording(report: nil)
        #expect(input.summaryInputText == complete.summaryInputText)
        #expect(input.summaryInputFingerprint != complete.summaryInputFingerprint)
        let prompt = try SummaryPromptBuilder().makePrompt(for: input).get()
        #expect(prompt.instructions.contains(report.warningText))
        #expect(prompt.instructions.contains("補完・推測しない"))
        #expect(!prompt.prompt.contains("recognition failed"))
    }

    @Test func audioRegenerationUsesNewReportInsteadOfRetainingOldCoverage() {
        let previous = transcript()
        let regenerated = previous.recording(report: nil).retainingScreen(from: previous)
        #expect(regenerated.transcriptionReport == nil)
    }

    @Test func ocrEnrichmentPreservesCoverage() async throws {
        let input = transcript()
        let output = try await ScreenTranscriptEnricher(service: ReportOCRService())
            .enrich(input, videoURL: URL(fileURLWithPath: "/tmp/screen.mp4"))
        #expect(output.transcriptionReport == report)
        #expect(output.screenSegments.first?.text == "slide")
    }

    @Test func summaryOnlyExportRetainsWarningEvenWithoutTranscript() throws {
        let summary = MeetingSummary(summary: "要約", topics: [], actionItems: [], transcriptSourceURL: sourceURL)
            .recording(input: transcript())
        let document = MeetingExportDocument(title: "meeting", createdAt: .now, summary: summary, transcript: nil, notes: [])
        let formatter = MeetingExportFormatter()
        #expect(formatter.markdown(for: document, sections: [.summary]).contains(report.warningText))
        #expect(formatter.plainText(for: document, sections: [.summary]).contains(report.warningText))
        let pdf = try formatter.payload(for: document, sections: [.summary], format: .pdf)
        let pdfText = try #require(PDFDocument(data: pdf.data)?.string)
        #expect(pdfText.contains("部分的な文字起こし"))
        #expect(pdfText.contains("recognition failed"))
    }

    @Test func transcriptOnlyExportIncludesCoverageAndTrackCause() {
        let document = MeetingExportDocument(title: "meeting", createdAt: .now, summary: nil, transcript: transcript(), notes: [])
        let formatter = MeetingExportFormatter()
        #expect(formatter.markdown(for: document, sections: [.transcript]).contains(report.warningText))
        #expect(formatter.plainText(for: document, sections: [.transcript]).contains(report.warningText))
    }

    @Test func oldJSONWithoutCoverageRemainsReadable() throws {
        let oldTranscript = #"{"text":"old","localeIdentifier":"ja-JP","sourceURL":"file:///tmp/old.m4a"}"#
        #expect(try JSONDecoder().decode(TranscriptResult.self, from: Data(oldTranscript.utf8)).transcriptionReport == nil)
        let summary = MeetingSummary(summary: "old", topics: [], actionItems: [], transcriptSourceURL: sourceURL)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any])
        json.removeValue(forKey: "transcriptionReport")
        #expect(try JSONDecoder().decode(MeetingSummary.self, from: JSONSerialization.data(withJSONObject: json)).transcriptionReport == nil)
    }

    @Test func everyLongMeetingChunkAndIntegrationReceivesCoverageWarning() async throws {
        let generator = ReportSummaryGenerator()
        let input = TranscriptResult(
            text: String(repeating: "remaining words. ", count: 60),
            localeIdentifier: "ja-JP", sourceURL: sourceURL, transcriptionReport: report
        )
        _ = try await ChunkedSummaryPipeline(promptBuilder: SummaryPromptBuilder(characterLimit: 200), generator: generator)
            .summarize(input, progress: { _ in })
        let prompts = await generator.prompts
        #expect(prompts.count > 2)
        #expect(prompts.allSatisfy { $0.instructions.contains(report.warningText) })
        #expect(prompts.last?.instructions.contains("横断して統合") == true)
    }

    private func transcript() -> TranscriptResult {
        TranscriptResult(
            text: "自分: 残った発言", localeIdentifier: "ja-JP", sourceURL: sourceURL,
            segments: [TranscriptSegment(text: "残った発言", timestamp: 1, duration: 2, speaker: .me)],
            transcriptionReport: report
        )
    }
}

private struct ReportOCRService: ScreenOCRServicing {
    func recognize(videoURL: URL, locale: Locale) async throws -> ScreenOCRResult {
        ScreenOCRResult(
            segments: [ScreenTranscriptSegment(text: "slide", timestamp: 0, duration: 2)],
            report: ScreenOCRReport(sampledFrames: 1, recognizedFrames: 1, elapsedSeconds: 0)
        )
    }
}

private actor ReportSummaryGenerator: SummaryGenerating {
    private(set) var prompts: [SummaryPrompt] = []

    func generate(prompt: SummaryPrompt, transcript: TranscriptResult) async throws -> MeetingSummary {
        prompts.append(prompt)
        return MeetingSummary(summary: "result", topics: [], actionItems: [], transcriptSourceURL: transcript.sourceURL)
    }
}
