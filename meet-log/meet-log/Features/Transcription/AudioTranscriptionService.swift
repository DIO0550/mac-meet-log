import Foundation

protocol AudioTranscriptionService: Sendable {
    func transcribe(
        audioURL: URL,
        locale: Locale
    ) -> AsyncThrowingStream<TranscriptionEvent, Error>
}

extension AudioTranscriptionService {
    func finalTranscript(
        audioURL: URL,
        locale: Locale = Locale(identifier: "ja-JP")
    ) async throws -> TranscriptResult {
        var finalResult: TranscriptResult?

        for try await event in transcribe(audioURL: audioURL, locale: locale) {
            if case let .completed(result) = event {
                finalResult = result
            }
        }

        guard let finalResult else {
            throw TranscriptionError.emptyResult
        }

        return finalResult
    }
}
