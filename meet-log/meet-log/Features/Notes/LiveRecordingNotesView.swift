import SwiftUI

struct LiveRecordingNotesView: View {
    @ObservedObject var viewModel: RecorderViewModel
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Timestamped Notes").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.notes) { note in
                        HStack(alignment: .top) {
                            Text(note.timestamp).monospacedDigit().foregroundStyle(.secondary)
                            Text(note.text)
                        }
                    }
                }
            }
            .frame(maxHeight: 90)
            if viewModel.isRecording || viewModel.isPaused {
                HStack {
                    TextField("Note at the current time", text: $text)
                        .onSubmit(commit)
                    Button("Add", action: commit)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if viewModel.hasUnsavedNotes && viewModel.completion != nil {
                Text("Notes are not saved yet. Retry before leaving this recording.")
                    .foregroundStyle(.red)
                Button("Retry Saving Notes", action: viewModel.saveNotes)
            }
        }
    }

    private func commit() {
        if viewModel.addNote(text) {
            text = ""
        }
    }
}
