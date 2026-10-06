import AppKit
import CoreText
import SwiftUI
import UniformTypeIdentifiers

enum MeetingExportSection: String, CaseIterable, Identifiable, Sendable {
    case summary
    case transcript
    case notes

    var id: Self { self }

    var title: String {
        switch self {
        case .summary:
            return "要約"
        case .transcript:
            return "文字起こし"
        case .notes:
            return "メモ"
        }
    }
}

enum MeetingExportFormat: String, CaseIterable, Identifiable, Sendable {
    case markdown
    case plainText
    case pdf

    var id: Self { self }

    var title: String {
        switch self {
        case .markdown:
            return "Markdown"
        case .plainText:
            return "プレーンテキスト"
        case .pdf:
            return "PDF"
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown:
            return "md"
        case .plainText:
            return "txt"
        case .pdf:
            return "pdf"
        }
    }

    var contentType: UTType {
        switch self {
        case .markdown:
            return UTType(filenameExtension: "md") ?? .plainText
        case .plainText:
            return .plainText
        case .pdf:
            return .pdf
        }
    }
}

struct MeetingExportDocument: Equatable, Identifiable, Sendable {
    let title: String
    let createdAt: Date
    let summary: MeetingSummary?
    let transcript: TranscriptResult?
    let notes: [RecordingNote]

    var id: String {
        "\(createdAt.timeIntervalSince1970)-\(title)"
    }

    var availableSections: Set<MeetingExportSection> {
        var sections = Set<MeetingExportSection>()
        if summary != nil {
            sections.insert(.summary)
        }
        if transcript != nil {
            sections.insert(.transcript)
        }
        if !notes.isEmpty {
            sections.insert(.notes)
        }
        return sections
    }

    func fileName(for format: MeetingExportFormat) -> String {
        let date = Self.fileDateFormatter.string(from: createdAt)
        let safeTitle = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = safeTitle.isEmpty ? "meeting-log" : safeTitle
        return "\(date)_\(name).\(format.fileExtension)"
    }

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()
}

enum MeetingExportError: Error, LocalizedError {
    case noContent
    case pdfCreationFailed

    var errorDescription: String? {
        switch self {
        case .noContent:
            return "出力する項目を1つ以上選択してください。"
        case .pdfCreationFailed:
            return "PDFを生成できませんでした。"
        }
    }
}

struct MeetingExportPayload {
    let data: Data
    let text: String?
    let format: MeetingExportFormat

    func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        if let text {
            NSPasteboard.general.setString(text, forType: .string)
        } else {
            NSPasteboard.general.setData(data, forType: .pdf)
        }
    }

    var sharingItem: Any {
        if let text {
            return text
        }
        return data
    }
}

struct MeetingExportFormatter {
    func payload(
        for document: MeetingExportDocument,
        sections requestedSections: Set<MeetingExportSection>,
        format: MeetingExportFormat
    ) throws -> MeetingExportPayload {
        let sections = requestedSections.intersection(document.availableSections)
        guard !sections.isEmpty else {
            throw MeetingExportError.noContent
        }

        switch format {
        case .markdown:
            let text = markdown(for: document, sections: sections)
            return MeetingExportPayload(data: Data(text.utf8), text: text, format: format)
        case .plainText:
            let text = plainText(for: document, sections: sections)
            return MeetingExportPayload(data: Data(text.utf8), text: text, format: format)
        case .pdf:
            let text = plainText(for: document, sections: sections)
            let data = try MeetingPDFRenderer().render(text)
            return MeetingExportPayload(data: data, text: nil, format: format)
        }
    }

    func markdown(
        for document: MeetingExportDocument,
        sections: Set<MeetingExportSection>
    ) -> String {
        var output = [
            "# \(document.title)",
            "- Date: \(Self.displayDateFormatter.string(from: document.createdAt))"
        ]

        if sections.contains(.summary), let summary = document.summary {
            output.append(markdownSummary(summary))
        }
        if sections.contains(.transcript), let transcript = document.transcript {
            output.append(markdownTranscript(transcript))
            if !transcript.screenSegments.isEmpty {
                output.append("## 画面テキスト（OCR・補助情報）\n\n" + transcript.screenText)
            }
        }
        if sections.contains(.notes), !document.notes.isEmpty {
            output.append(
                """
                ## メモ

                \(document.notes.sorted(by: noteOrder).map { "- [\($0.timestamp)] \($0.text)" }.joined(separator: "\n"))
                """
            )
        }

        return output.joined(separator: "\n\n") + "\n"
    }

    func plainText(
        for document: MeetingExportDocument,
        sections: Set<MeetingExportSection>
    ) -> String {
        var output = [
            document.title,
            "日時: \(Self.displayDateFormatter.string(from: document.createdAt))"
        ]

        if sections.contains(.summary), let summary = document.summary {
            output.append(plainTextSummary(summary))
        }
        if sections.contains(.transcript), let transcript = document.transcript {
            output.append(plainTextTranscript(transcript))
            if !transcript.screenSegments.isEmpty {
                output.append("画面テキスト（OCR・補助情報）\n" + transcript.screenText)
            }
        }
        if sections.contains(.notes), !document.notes.isEmpty {
            output.append(
                """
                メモ
                \(document.notes.sorted(by: noteOrder).map { "[\($0.timestamp)] \($0.text)" }.joined(separator: "\n"))
                """
            )
        }

        return output.joined(separator: "\n\n") + "\n"
    }

    private func markdownSummary(_ summary: MeetingSummary) -> String {
        var parts = ["## 要約\n\n\(summary.summary)"]
        if !summary.topics.isEmpty {
            parts.append(
                """
                ### 主要トピック

                \(summary.topics.map { topic in
                    guard let detail = topic.detail, !detail.isEmpty else {
                        return "- \(topic.title)"
                    }
                    return "- **\(topic.title)**: \(detail)"
                }.joined(separator: "\n"))
                """
            )
        }
        if !summary.actionItems.isEmpty {
            parts.append(
                """
                ### アクションアイテム

                \(summary.actionItems.map { item in
                    var metadata = [String]()
                    if let owner = item.owner, !owner.isEmpty {
                        metadata.append("担当: \(owner)")
                    }
                    if let dueDate = item.dueDateText, !dueDate.isEmpty {
                        metadata.append("期限: \(dueDate)")
                    }
                    let suffix = metadata.isEmpty ? "" : "（\(metadata.joined(separator: " / "))）"
                    return "- [ ] \(item.title)\(suffix)"
                }.joined(separator: "\n"))
                """
            )
        }
        return parts.joined(separator: "\n\n")
    }

    private func plainTextSummary(_ summary: MeetingSummary) -> String {
        var parts = ["要約\n\(summary.summary)"]
        if !summary.topics.isEmpty {
            parts.append(
                "主要トピック\n" + summary.topics.map { topic in
                    guard let detail = topic.detail, !detail.isEmpty else {
                        return "- \(topic.title)"
                    }
                    return "- \(topic.title): \(detail)"
                }.joined(separator: "\n")
            )
        }
        if !summary.actionItems.isEmpty {
            parts.append(
                "アクションアイテム\n" + summary.actionItems.map { item in
                    var metadata = [String]()
                    if let owner = item.owner, !owner.isEmpty {
                        metadata.append("担当: \(owner)")
                    }
                    if let dueDate = item.dueDateText, !dueDate.isEmpty {
                        metadata.append("期限: \(dueDate)")
                    }
                    let suffix = metadata.isEmpty ? "" : "（\(metadata.joined(separator: " / "))）"
                    return "- \(item.title)\(suffix)"
                }.joined(separator: "\n")
            )
        }
        return parts.joined(separator: "\n\n")
    }

    private func markdownTranscript(_ transcript: TranscriptResult) -> String {
        guard !transcript.segments.isEmpty else {
            return "## 文字起こし\n\n\(transcript.text)"
        }
        let lines = transcript.segments.map { segment in
            let speaker = transcript.speakerName(for: segment) ?? "話者不明"
            return "- [\(segment.timeRangeText)] **\(speaker)**: \(segment.text)"
        }
        return "## 文字起こし\n\n\(lines.joined(separator: "\n"))"
    }

    private func plainTextTranscript(_ transcript: TranscriptResult) -> String {
        guard !transcript.segments.isEmpty else {
            return "文字起こし\n\(transcript.text)"
        }
        let lines = transcript.segments.map { segment in
            let speaker = transcript.speakerName(for: segment) ?? "話者不明"
            return "[\(segment.timeRangeText)] \(speaker): \(segment.text)"
        }
        return "文字起こし\n\(lines.joined(separator: "\n"))"
    }

    private func noteOrder(_ lhs: RecordingNote, _ rhs: RecordingNote) -> Bool {
        if lhs.elapsed != rhs.elapsed {
            return lhs.elapsed < rhs.elapsed
        }
        return lhs.createdAt < rhs.createdAt
    }

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct MeetingPDFRenderer {
    func render(_ text: String) throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw MeetingExportError.pdfCreationFailed
        }

        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.black
            ]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let textRect = CGRect(x: 48, y: 48, width: mediaBox.width - 96, height: mediaBox.height - 96)
        var location = 0

        while location < attributed.length {
            context.beginPDFPage(nil)
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: location, length: 0),
                path,
                nil
            )
            CTFrameDraw(frame, context)
            let visibleRange = CTFrameGetVisibleStringRange(frame)
            context.endPDFPage()

            guard visibleRange.length > 0 else {
                throw MeetingExportError.pdfCreationFailed
            }
            location += visibleRange.length
        }

        context.closePDF()
        return data as Data
    }
}

struct MeetingExportView: View {
    @Environment(\.dismiss) private var dismiss
    let document: MeetingExportDocument
    @State private var selectedSections: Set<MeetingExportSection>
    @State private var format = MeetingExportFormat.markdown
    @State private var errorMessage: String?

    init(document: MeetingExportDocument) {
        self.document = document
        _selectedSections = State(initialValue: document.availableSections)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("書き出し")
                .font(.title2.weight(.semibold))

            Text(document.title)
                .font(.callout)
                .foregroundStyle(.secondary)

            GroupBox("出力対象") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(MeetingExportSection.allCases) { section in
                        Toggle(isOn: binding(for: section)) {
                            HStack {
                                Text(section.title)
                                if !document.availableSections.contains(section) {
                                    Text("未生成")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(!document.availableSections.contains(section))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            Picker("形式", selection: $format) {
                ForEach(MeetingExportFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.segmented)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("閉じる") {
                    dismiss()
                }
                Spacer()
                Button(action: copy) {
                    Label("コピー", systemImage: "doc.on.doc")
                }
                .disabled(selectedSections.isEmpty)
                Button(action: save) {
                    Label("ファイル保存", systemImage: "square.and.arrow.down")
                }
                .disabled(selectedSections.isEmpty)
                SharePickerButton(makeItems: sharingItems)
                    .disabled(selectedSections.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private func binding(for section: MeetingExportSection) -> Binding<Bool> {
        Binding {
            selectedSections.contains(section)
        } set: { isSelected in
            if isSelected {
                selectedSections.insert(section)
            } else {
                selectedSections.remove(section)
            }
        }
    }

    private func sharingItems() -> [Any] {
        guard let payload = try? MeetingExportFormatter().payload(
            for: document,
            sections: selectedSections,
            format: format
        ) else {
            return []
        }
        return [payload.sharingItem]
    }

    private func copy() {
        do {
            let payload = try MeetingExportFormatter().payload(
                for: document,
                sections: selectedSections,
                format: format
            )
            payload.copyToPasteboard()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        do {
            let payload = try MeetingExportFormatter().payload(
                for: document,
                sections: selectedSections,
                format: format
            )
            let panel = NSSavePanel()
            panel.allowedContentTypes = [format.contentType]
            panel.nameFieldStringValue = document.fileName(for: format)
            guard panel.runModal() == .OK, let url = panel.url else {
                return
            }
            try payload.data.write(to: url, options: .atomic)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SharePickerButton: NSViewRepresentable {
    let makeItems: () -> [Any]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: "共有…",
            target: context.coordinator,
            action: #selector(Coordinator.share)
        )
        button.bezelStyle = .rounded
        context.coordinator.button = button
        context.coordinator.makeItems = makeItems
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.makeItems = makeItems
    }

    final class Coordinator: NSObject {
        weak var button: NSButton?
        var makeItems: () -> [Any] = { [] }
        private var picker: NSSharingServicePicker?

        @objc func share() {
            guard let button else {
                return
            }
            let items = makeItems()
            guard !items.isEmpty else {
                return
            }
            let picker = NSSharingServicePicker(items: items)
            self.picker = picker
            picker.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
