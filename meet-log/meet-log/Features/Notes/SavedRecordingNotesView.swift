import SwiftUI

struct SavedRecordingNotesView: View {
    let url: URL
    let duration: Duration?
    var seek: ((Double) -> Void)? = nil
    @State private var notes: [RecordingNote] = []
    @State private var text = ""
    @State private var seconds = 0.0
    @State private var editingID: UUID?
    @State private var errorMessage: String?
    @State private var loaded = false
    private let store = RecordingNoteStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Timestamped Notes").font(.headline)
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
                if !loaded {
                    Button("Reload Notes", action: load)
                }
            }
            ForEach(notes) { note in
                HStack(alignment: .top) {
                    PlaybackTimestampButton(title: note.timestamp, seconds: note.elapsed, seek: seek)
                    Text(note.text).textSelection(.enabled)
                    Spacer()
                    Button("Edit") {
                        editingID = note.id
                        text = note.text
                        seconds = note.elapsed
                    }
                    Button("Delete", role: .destructive) {
                        save(notes.filter { $0.id != note.id })
                    }
                }
            }
            HStack {
                Text("Seconds")
                TextField("Seconds", value: $seconds, format: .number)
                    .frame(width: 80)
                TextField("Note", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                Button(editingID == nil ? "Add" : "Save", action: commit)
                    .disabled(!loaded || !validInput)
                if editingID != nil {
                    Button("Cancel", action: clearInput)
                }
            }
            if notes.isEmpty && loaded {
                Text("No notes yet.").foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: load)
    }

    private var validInput: Bool {
        guard seconds.isFinite, seconds >= 0,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard let duration else {
            return true
        }
        return Duration.seconds(seconds) <= duration
    }

    private func load() {
        do {
            notes = try store.load(from: url)
            loaded = true
            errorMessage = nil
        } catch {
            loaded = false
            errorMessage = "Notes could not be read. The existing file has been preserved: \(error.localizedDescription)"
        }
    }

    private func commit() {
        guard loaded, validInput else {
            return
        }
        var updated = notes
        if let editingID, let index = updated.firstIndex(where: { $0.id == editingID }) {
            let old = updated[index]
            updated[index] = RecordingNote(id: old.id, elapsed: seconds, text: text, createdAt: old.createdAt)
        } else {
            updated.append(RecordingNote(elapsed: seconds, text: text))
        }
        save(updated)
    }

    private func save(_ updated: [RecordingNote]) {
        do {
            try store.save(updated, to: url)
            notes = try store.load(from: url)
            errorMessage = nil
            clearInput()
        } catch {
            errorMessage = "Notes could not be saved: \(error.localizedDescription)"
        }
    }

    private func clearInput() {
        editingID = nil
        text = ""
        seconds = 0
    }
}
