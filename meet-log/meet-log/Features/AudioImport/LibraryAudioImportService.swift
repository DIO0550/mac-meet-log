import Foundation

@MainActor
protocol LibraryAudioImporting {
    func importAudio(from sourceURL: URL, to directoryURL: URL) async throws -> RecordingLibraryItem
}

/// Library imports are durable copies. External-file access ends before processing
/// starts; transcription, playback and retries use the managed copy exclusively.
@MainActor
struct LibraryAudioImportService: LibraryAudioImporting {
    var validator: AudioFileImporting = AVAudioFileImporter()
    var startAccess: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
    var stopAccess: (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }

    func importAudio(from sourceURL: URL, to directoryURL: URL) async throws -> RecordingLibraryItem {
        let accessing = startAccess(sourceURL)
        defer {
            if accessing {
                stopAccess(sourceURL)
            }
        }

        try Task.checkCancellation()
        let audio = try await validator.importAudio(from: sourceURL)
        try Task.checkCancellation()

        let stem = "import-\(UUID().uuidString)"
        let staging = directoryURL.appendingPathComponent(".\(stem)", isDirectory: true)
        let destination = directoryURL.appendingPathComponent(stem, isDirectory: true)
        let fileName = "\(stem)_mix.\(audio.fileExtension)"
        let stagedAudio = staging.appendingPathComponent(fileName)
        let managedAudio = destination.appendingPathComponent(fileName)
        let createdAt = Date()

        // Publish the entire session with one rename after copying and metadata
        // saving succeed. Failed/cancelled imports never appear in Library scans.
        defer { try? FileManager.default.removeItem(at: staging) }
        try await copy(sourceURL, to: stagedAudio)
        try Task.checkCancellation()

        let stagedItem = makeItem(audio, stem: stem, url: stagedAudio, createdAt: createdAt)
        try RecordingDisplayMetadataStore().save(
            RecordingDisplayMetadata(name: audio.fileName, tags: [], createdAt: createdAt),
            for: stagedItem
        )
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: destination)

        return makeItem(audio, stem: stem, url: managedAudio, createdAt: createdAt)
    }

    private func copy(_ source: URL, to destination: URL) async throws {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw AudioImportError.unreadable("Choose a regular audio file rather than a link.")
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: source, to: destination)
            try Task.checkCancellation()
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func makeItem(
        _ audio: AudioImportItem, stem: String, url: URL, createdAt: Date
    ) -> RecordingLibraryItem {
        RecordingLibraryItem(
            id: stem, title: audio.fileName, createdAt: createdAt, duration: audio.duration,
            mixdownURL: url, systemAudioURL: nil, microphoneURL: nil,
            fileExistence: RecordingLibraryFileExistence(
                mixdownExists: true, systemAudioExists: false, microphoneExists: false
            )
        )
    }
}
