import SwiftUI

struct TranscriptSpeakerEditorView: View {
    @Binding var draft: MeetingEditDraft
    let original: TranscriptResult
    @State private var newParticipantName = ""
    @State private var selectedSegments = Set<Int>()
    @State private var bulkParticipantID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            participantFields
            Divider()
            Text("音声").font(.headline)

            if original.segments.isEmpty {
                Text("時刻情報のない文字起こしです。本文を編集できます。話者の割当には発言セグメントが必要です。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("文字起こし本文", text: $draft.text, axis: .vertical)
                    .lineLimit(2...12)
            }

            if !original.segments.isEmpty {
                bulkAssignmentFields
            }

            ForEach(original.segments.indices, id: \.self) { index in
                let segment = original.segments[index]
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Toggle(isOn: selection(for: index)) {
                            Text("\(segment.timeRangeText) · 入力元: \(segment.speaker?.displayName ?? "不明")")
                        }
                        .toggleStyle(.checkbox)
                        .font(.caption)

                        participantPicker("話者", selection: $draft.segmentParticipantIDs[index])
                            .frame(maxWidth: 240)
                    }

                    TextField("音声セグメント", text: $draft.segmentTexts[index], axis: .vertical)
                        .lineLimit(2...12)
                }
            }
        }
    }

    private var participantFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("参加者").font(.headline)
            Text("表示する話者名を登録します。音声の入力元（自分／相手）は保持されます。削除すると、その参加者の割当を解除します。")
                .font(.caption).foregroundStyle(.secondary)

            ForEach($draft.participants) { $participant in
                HStack {
                    TextField("参加者名", text: $participant.displayName)
                    Button("削除", role: .destructive) {
                        draft.removeParticipant(participant.id)
                        if bulkParticipantID == participant.id {
                            bulkParticipantID = nil
                        }
                    }
                }
            }

            HStack {
                TextField("追加する参加者名", text: $newParticipantName)
                Button("参加者を追加") {
                    draft.addParticipant(named: newParticipantName)
                    newParticipantName = ""
                }
                .disabled(newParticipantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !draft.hasValidParticipants {
                Text("参加者名を入力し、有効な参加者へ割り当ててください。")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var bulkAssignmentFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("全選択") { selectedSegments = Set(original.segments.indices) }
                Button("自分を選択") { selectSegments(from: .me) }
                Button("相手を選択") { selectSegments(from: .other) }
                Button("選択をクリア") { selectedSegments = [] }
            }

            HStack {
                participantPicker("一括割当", selection: $bulkParticipantID)
                Button("選択した発言に適用（\(selectedSegments.count)件）") {
                    draft.assignParticipant(bulkParticipantID, to: selectedSegments)
                }
                .disabled(selectedSegments.isEmpty)
            }

            Text("未割当を適用すると解除できます。未割当の発言には従来の入力元ラベルを表示します。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func participantPicker(_ title: String, selection: Binding<UUID?>) -> some View {
        Picker(title, selection: selection) {
            Text("未割当").tag(Optional<UUID>.none)
            ForEach(draft.participants) { participant in
                Text(participant.displayName).tag(Optional(participant.id))
            }
        }
    }

    private func selectSegments(from speaker: TranscriptSpeaker) {
        selectedSegments = Set(original.segments.indices.filter { original.segments[$0].speaker == speaker })
    }

    private func selection(for index: Int) -> Binding<Bool> {
        Binding(get: { selectedSegments.contains(index) }, set: { selected in
            if selected {
                selectedSegments.insert(index)
                return
            }

            selectedSegments.remove(index)
        })
    }
}
