import Foundation

struct RecordingNoteStore {
    func load(from url: URL) throws -> [RecordingNote] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        let notes = try JSONDecoder().decode([RecordingNote].self, from: Data(contentsOf: url))
        try validate(notes)
        return sorted(notes)
    }

    func save(_ notes: [RecordingNote], to url: URL) throws {
        try validate(notes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sorted(notes)).write(to: url, options: .atomic)
    }

    func url(for trackURL: URL) -> URL? {
        guard let stem = RecordingLibraryItem.stem(fromFileName: trackURL.lastPathComponent) else {
            return nil
        }
        return trackURL.deletingLastPathComponent().appendingPathComponent("\(stem)_notes.json")
    }

    private func sorted(_ notes: [RecordingNote]) -> [RecordingNote] {
        notes.sorted {
            if $0.elapsed != $1.elapsed {
                return $0.elapsed < $1.elapsed
            }
            return $0.createdAt < $1.createdAt
        }
    }

    private func validate(_ notes: [RecordingNote]) throws {
        guard Set(notes.map(\.id)).count == notes.count,
              notes.allSatisfy({ $0.elapsed.isFinite && $0.elapsed >= 0 && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}
