#if canImport(AVFoundation) && canImport(Speech) && compiler(>=6.2)
import AVFoundation
import Foundation
import Speech

@available(macOS 26.0, *)
struct SpeechAnalyzerTranscriptionService: AudioTranscriptionService {
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
                continuation.finish()
            } catch let error as TranscriptionError {
                continuation.finish(throwing: error)
            } catch {
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
        async let result = collectResults(from: transcriber)

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
        continuation.yield(
            .completed(
                TranscriptResult(
                    text: transcript,
                    localeIdentifier: supportedLocale.identifier,
                    sourceURL: audioURL
                )
            )
        )
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

    private func collectResults(from transcriber: SpeechTranscriber) async throws -> String {
        var finalizedText = ""

        for try await result in transcriber.results {
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                continue
            }

            if result.isFinal {
                finalizedText = append(text, to: finalizedText)
                continue
            }

            continuation.yield(.partial(text))
        }

        guard !finalizedText.isEmpty else {
            throw TranscriptionError.emptyResult
        }

        return finalizedText
    }

    private func append(_ text: String, to finalizedText: String) -> String {
        guard !finalizedText.isEmpty else {
            return text
        }

        return "\(finalizedText)\n\(text)"
    }
}
#endif
