import Foundation

struct FallbackAudioTranscriptionService: AudioTranscriptionService {
    private let primary: AudioTranscriptionService
    private let fallback: AudioTranscriptionService
    private let shouldFallback: @Sendable (Error) -> Bool

    nonisolated init(
        primary: AudioTranscriptionService,
        fallback: AudioTranscriptionService,
        shouldFallback: @escaping @Sendable (Error) -> Bool = Self.shouldFallback
    ) {
        self.primary = primary
        self.fallback = fallback
        self.shouldFallback = shouldFallback
    }

    nonisolated func transcribe(
        audioURL: URL,
        locale: Locale = Locale(identifier: "ja-JP")
    ) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(10)) { continuation in
            let task = Task {
                do {
                    try await streamEvents(
                        from: primary.transcribe(audioURL: audioURL, locale: locale),
                        to: continuation
                    )
                    continuation.finish()
                } catch where shouldFallback(error) {
                    do {
                        try await streamEvents(
                            from: fallback.transcribe(audioURL: audioURL, locale: locale),
                            to: continuation
                        )
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    nonisolated private func streamEvents(
        from stream: AsyncThrowingStream<TranscriptionEvent, Error>,
        to continuation: AsyncThrowingStream<TranscriptionEvent, Error>.Continuation
    ) async throws {
        for try await event in stream {
            continuation.yield(event)
        }
    }

    nonisolated private static func shouldFallback(_ error: Error) -> Bool {
        guard let error = error as? TranscriptionError else {
            return false
        }

        switch error {
        case .speechAnalyzerUnavailable,
             .speechAnalyzerAssetsUnavailable,
             .recognizerUnsupportedForLocale:
            return true
        case .authorizationDenied,
             .authorizationRestricted,
             .authorizationUnavailable,
             .recognizerTemporarilyUnavailable,
             .onDeviceRecognitionUnavailable,
             .siriAndDictationDisabled,
             .recognitionFailed,
             .emptyResult,
             .transcriptionIncomplete:
            return false
        }
    }
}
