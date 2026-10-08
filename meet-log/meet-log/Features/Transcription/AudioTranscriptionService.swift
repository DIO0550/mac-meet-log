import Foundation

protocol AudioTranscriptionService: Sendable {
    nonisolated func transcribe(
        audioURL: URL,
        locale: Locale
    ) -> AsyncThrowingStream<TranscriptionEvent, Error>
}

extension AudioTranscriptionService {
    nonisolated func finalTranscript(
        audioURL: URL,
        locale: Locale = Locale(identifier: "ja-JP")
    ) async throws -> TranscriptResult {
        try Task.checkCancellation()
        var finalResult: TranscriptResult?

        for try await event in transcribe(audioURL: audioURL, locale: locale) {
            try Task.checkCancellation()
            if case let .completed(result) = event {
                finalResult = result
            }
        }

        try Task.checkCancellation()
        guard let finalResult else {
            throw TranscriptionError.transcriptionIncomplete
        }

        guard !finalResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptionError.emptyResult
        }

        return finalResult
    }
}
