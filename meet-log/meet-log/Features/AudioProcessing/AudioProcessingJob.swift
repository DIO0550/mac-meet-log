import Foundation

nonisolated struct AudioProcessingJob: Sendable {
    let importer: AudioFileImporting
    let transcriptionService: AudioTranscriptionService
    let summaryService: TranscriptSummaryService

    init(
        importer: AudioFileImporting = AVAudioFileImporter(),
        transcriptionService: AudioTranscriptionService = LegacySpeechTranscriptionService(),
        summaryService: TranscriptSummaryService = SummaryServiceFactory.makeDefault()
    ) {
        self.importer = importer
        self.transcriptionService = transcriptionService
        self.summaryService = summaryService
    }

    nonisolated func run(
        audioURL: URL,
        locale: Locale = Locale(identifier: "ja-JP")
    ) -> AsyncStream<AudioProcessingJobState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(20)) { continuation in
            let task = Task {
                var importedItem: AudioImportItem?
                var transcript: TranscriptResult?

                do {
                    let didStartAccessing = audioURL.startAccessingSecurityScopedResource()
                    defer {
                        if didStartAccessing {
                            audioURL.stopAccessingSecurityScopedResource()
                        }
                    }

                    continuation.yield(.loading)
                    try Task.checkCancellation()

                    let item = try await importer.importAudio(from: audioURL)
                    importedItem = item
                    try Task.checkCancellation()

                    transcript = try await transcribe(
                        item: item,
                        locale: locale,
                        continuation: continuation
                    )
                    guard let transcript else {
                        throw TranscriptionError.transcriptionIncomplete
                    }

                    try Task.checkCancellation()
                    continuation.yield(.summarizing(item, transcript))

                    let summaryResult = await summaryService.summarize(transcript)
                    try Task.checkCancellation()

                    switch summaryResult {
                    case .summarized, .unavailable:
                        continuation.yield(.completed(item, transcript, summaryResult))
                    case let .failed(error):
                        continuation.yield(.failed(item, .summaryFailed(error), transcript: transcript))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.cancelled(importedItem))
                    continuation.finish()
                } catch {
                    continuation.yield(
                        .failed(
                            importedItem,
                            Self.map(error),
                            transcript: transcript
                        )
                    )
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private nonisolated func transcribe(
        item: AudioImportItem,
        locale: Locale,
        continuation: AsyncStream<AudioProcessingJobState>.Continuation
    ) async throws -> TranscriptResult {
        var finalTranscript: TranscriptResult?

        continuation.yield(.transcribing(item, partialTranscript: nil))

        for try await event in transcriptionService.transcribe(audioURL: item.url, locale: locale) {
            try Task.checkCancellation()

            switch event {
            case let .partial(text):
                continuation.yield(.transcribing(item, partialTranscript: text))
            case let .completed(transcript):
                finalTranscript = transcript
            }
        }

        guard let finalTranscript else {
            throw TranscriptionError.transcriptionIncomplete
        }

        return finalTranscript
    }

    private static nonisolated func map(_ error: Error) -> AudioProcessingError {
        if let error = error as? AudioImportError {
            return .importFailed(error)
        }

        if let error = error as? TranscriptionError {
            return .transcriptionFailed(error)
        }

        if let error = error as? SummaryError {
            return .summaryFailed(error)
        }

        return .unexpected(error.localizedDescription)
    }
}
