import SwiftUI

struct MeetingEditorView: View {
    @Binding var draft: MeetingEditDraft
    let isSaving: Bool
    let error: String?
    let save: () -> Void
    let cancel: () -> Void
    @State private var confirmDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            Text("保存するまで元の内容は変更されません。")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch draft.original {
                    case .transcript(let original):
                        transcriptFields(original)
                    case .summary:
                        summaryFields
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(2)
            }
            .disabled(isSaving)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                Text(draft.hasChanges ? "未保存の変更があります" : "変更なし")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button("キャンセル") {
                    guard draft.hasChanges else {
                        cancel()
                        return
                    }
                    confirmDiscard = true
                }
                .keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.hasValidParticipants)
            }
            .disabled(isSaving)
        }
        .padding(24)
        .frame(minWidth: 640, idealWidth: 720, minHeight: 520, idealHeight: 620)
        .interactiveDismissDisabled(true)
        .confirmationDialog("未保存の変更を破棄しますか？", isPresented: $confirmDiscard) {
            Button("変更を破棄", role: .destructive, action: cancel)
            Button("編集を続ける", role: .cancel) {}
        }
    }

    private var title: String {
        switch draft.original {
        case .transcript: return "文字起こしを編集"
        case .summary: return "要約・トピック・TODOを編集"
        }
    }

    @ViewBuilder
    private func transcriptFields(_ original: TranscriptResult) -> some View {
        TranscriptSpeakerEditorView(draft: $draft, original: original)
        if !original.screenSegments.isEmpty {
            Divider()
            Text("画面OCR（補助情報）").font(.headline)
            ForEach(original.screenSegments.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    Text(original.screenSegments[index].timeRangeText)
                        .font(.caption).foregroundStyle(.secondary)
                    multiline("画面セグメント", text: $draft.screenTexts[index])
                }
            }
        }
    }

    private var summaryFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("要約本文").font(.headline)
            multiline("要約本文", text: $draft.text)
            Divider()
            Text("トピック").font(.headline)
            ForEach($draft.topics) { $topic in
                VStack(alignment: .leading, spacing: 8) {
                    multiline("トピック名", text: $topic.title)
                    multiline("詳細", text: optionalText($topic.detail))
                    Button("トピックを削除", role: .destructive) {
                        draft.topics.removeAll { $0.id == topic.id }
                    }
                }
            }
            Button("トピックを追加") { draft.topics.append(MeetingTopic(title: "")) }
            Divider()
            Text("TODO").font(.headline)
            ForEach($draft.actionItems) { $item in
                VStack(alignment: .leading, spacing: 8) {
                    multiline("TODOの内容", text: $item.title)
                    TextField("担当者", text: optionalText($item.owner))
                    TextField("期限", text: optionalText($item.dueDateText))
                    Button("TODOを削除", role: .destructive) {
                        draft.actionItems.removeAll { $0.id == item.id }
                    }
                }
            }
            Button("TODOを追加") { draft.actionItems.append(MeetingActionItem(title: "")) }
        }
    }

    private func multiline(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text, axis: .vertical)
            .lineLimit(2...12)
    }

    private func optionalText(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}
