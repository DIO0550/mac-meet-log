#if canImport(AVFoundation) && canImport(Speech) && compiler(>=6.2)
import AVFoundation
import Foundation
import Speech

@available(macOS 26.0, *)
struct SpeechAnalyzerTranscriptionService: AudioTranscriptionService {
    nonisolated init() {}

    nonisolated func transcribe(
        audioURL: URL,
        locale: Locale = Locale(identifier: "ja-JP")
    ) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(10)) { continuation in
            let coordinator = SpeechAnalyzerTranscriptionCoordinator(
                audioURL: audioURL,
                locale: locale,
                continuation: continuation
            )

            continuation.onTermination = { _ in
                coordinator.cancel()
            }

            coordinator.start()
        }
    }
}

@available(macOS 26.0, *)
nonisolated final class SpeechAnalyzerTranscriptionCoordinator: @unchecked Sendable {
    private let audioURL: URL
    private let locale: Locale
    private let continuation: AsyncThrowingStream<TranscriptionEvent, Error>.Continuation
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    nonisolated init(
        audioURL: URL,
        locale: Locale,
        continuation: AsyncThrowingStream<TranscriptionEvent, Error>.Continuation
    ) {
        self.audioURL = audioURL
        self.locale = locale
        self.continuation = continuation
    }

    nonisolated func start() {
        let task = Task {
            do {
                try await transcribeFile()
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
            } catch let error as TranscriptionError {
                continuation.finish(throwing: error)
            } catch {
                if TranscriptionCancellation.isCancellation(error) {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                continuation.finish(throwing: TranscriptionError.recognitionFailed(error.localizedDescription))
            }
        }

        lock.lock()
        self.task = task
        lock.unlock()
    }

    nonisolated func cancel() {
        lock.lock()
        let task = task
        self.task = nil
        lock.unlock()

        task?.cancel()
    }

    private func transcribeFile() async throws {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.speechAnalyzerUnavailable
        }

        let requestedLocaleIdentifier = locale.identifier
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.recognizerUnsupportedForLocale(localeIdentifier: requestedLocaleIdentifier)
        }

        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .transcription)
        try await installAssets(for: transcriber, localeIdentifier: requestedLocaleIdentifier)

        let audioFile = try AVAudioFile(forReading: audioURL)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let result = collectResults(from: transcriber, localeIdentifier: supportedLocale.identifier)

        do {
            if let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }

        let transcript = try await result
        continuation.yield(.completed(transcript))
    }

    private func installAssets(
        for transcriber: SpeechTranscriber,
        localeIdentifier: String
    ) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return
        case .supported, .downloading, .unsupported:
            throw TranscriptionError.speechAnalyzerAssetsUnavailable(localeIdentifier: localeIdentifier)
        @unknown default:
            throw TranscriptionError.speechAnalyzerAssetsUnavailable(localeIdentifier: localeIdentifier)
        }
    }

    private func collectResults(
        from transcriber: SpeechTranscriber,
        localeIdentifier: String
    ) async throws -> TranscriptResult {
        var accumulator = SpeechAnalyzerResultAccumulator()

        for try await result in transcriber.results {
            if let event = try accumulator.consume(
                text: String(result.text.characters),
                range: result.range,
                isFinal: result.isFinal
            ) {
                continuation.yield(event)
            }
        }

        return try accumulator.transcript(localeIdentifier: localeIdentifier, sourceURL: audioURL)
    }
}
#endif
