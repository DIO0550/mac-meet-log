import Foundation
import Speech

struct LegacySpeechTranscriptionService: AudioTranscriptionService {
    private let authorizationProvider: LegacySpeechAuthorizationProviding
    private let recognizerFactory: LegacySpeechRecognizerMaking

    init(
        authorizationProvider: LegacySpeechAuthorizationProviding = SystemSpeechAuthorizationProvider(),
        recognizerFactory: LegacySpeechRecognizerMaking = SystemSpeechRecognizerFactory()
    ) {
        self.authorizationProvider = authorizationProvider
        self.recognizerFactory = recognizerFactory
    }

    nonisolated func transcribe(
        audioURL: URL,
        locale: Locale = Locale(identifier: "ja-JP")
    ) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(10)) { continuation in
            let coordinator = LegacySpeechTranscriptionCoordinator(
                audioURL: audioURL,
                locale: locale,
                authorizationProvider: authorizationProvider,
                recognizerFactory: recognizerFactory,
                continuation: continuation
            )

            continuation.onTermination = { _ in
                coordinator.cancel()
            }

            coordinator.start()
        }
    }
}

nonisolated final class LegacySpeechTranscriptionCoordinator: @unchecked Sendable {
    private let audioURL: URL
    private let locale: Locale
    private let authorizationProvider: LegacySpeechAuthorizationProviding
    private let recognizerFactory: LegacySpeechRecognizerMaking
    private let continuation: AsyncThrowingStream<TranscriptionEvent, Error>.Continuation
    private let lock = NSLock()
    private var task: LegacySpeechRecognitionTasking?

    nonisolated init(
        audioURL: URL,
        locale: Locale,
        authorizationProvider: LegacySpeechAuthorizationProviding,
        recognizerFactory: LegacySpeechRecognizerMaking,
        continuation: AsyncThrowingStream<TranscriptionEvent, Error>.Continuation
    ) {
        self.audioURL = audioURL
        self.locale = locale
        self.authorizationProvider = authorizationProvider
        self.recognizerFactory = recognizerFactory
        self.continuation = continuation
    }

    nonisolated func start() {
        Task {
            do {
                try await authorize()
                try startRecognition()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    nonisolated func cancel() {
        lock.lock()
        let task = task
        self.task = nil
        lock.unlock()

        task?.cancel()
    }

    nonisolated private func authorize() async throws {
        switch await authorizationProvider.authorizationStatusAfterRequest() {
        case .authorized:
            return
        case .denied:
            throw TranscriptionError.authorizationDenied
        case .restricted:
            throw TranscriptionError.authorizationRestricted
        case .notDetermined, .unavailable:
            throw TranscriptionError.authorizationUnavailable
        }
    }

    nonisolated private func startRecognition() throws {
        let localeIdentifier = locale.identifier
        guard let recognizer = recognizerFactory.recognizer(locale: locale) else {
            throw TranscriptionError.recognizerUnavailable(localeIdentifier: localeIdentifier)
        }

        guard recognizer.isAvailable else {
            throw TranscriptionError.recognizerNotAvailable(localeIdentifier: localeIdentifier)
        }

        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.onDeviceRecognitionUnavailable(localeIdentifier: localeIdentifier)
        }

        let configuration = LegacySpeechRecognitionRequestConfiguration(
            requiresOnDeviceRecognition: true,
            shouldReportPartialResults: true,
            addsPunctuation: true
        )
        let recognitionTask = recognizer.recognitionTask(
            audioURL: audioURL,
            configuration: configuration
        ) { [weak self] callback in
            self?.handle(callback)
        }

        lock.lock()
        task = recognitionTask
        lock.unlock()
    }

    nonisolated private func handle(_ callback: LegacySpeechRecognitionCallback) {
        if let error = callback.error {
            continuation.finish(throwing: TranscriptionError.recognitionFailed(error.localizedDescription))
            return
        }

        let text = callback.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard callback.isFinal else {
            if !text.isEmpty {
                continuation.yield(.partial(text))
            }
            return
        }

        guard !text.isEmpty else {
            continuation.finish(throwing: TranscriptionError.emptyResult)
            return
        }

        continuation.yield(
            .completed(
                TranscriptResult(
                    text: text,
                    localeIdentifier: locale.identifier,
                    sourceURL: audioURL,
                    segments: callback.segments
                )
            )
        )
        continuation.finish()
    }
}

enum LegacySpeechAuthorizationStatus: Equatable, Sendable {
    case authorized
    case denied
    case restricted
    case notDetermined
    case unavailable
}

protocol LegacySpeechAuthorizationProviding: Sendable {
    nonisolated func authorizationStatusAfterRequest() async -> LegacySpeechAuthorizationStatus
}

struct SystemSpeechAuthorizationProvider: LegacySpeechAuthorizationProviding {
    nonisolated func authorizationStatusAfterRequest() async -> LegacySpeechAuthorizationStatus {
        let currentStatus = Self.map(SFSpeechRecognizer.authorizationStatus())
        switch currentStatus {
        case .notDetermined:
            break
        case .authorized, .denied, .restricted, .unavailable:
            return currentStatus
        }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: Self.map(status))
            }
        }
    }

    nonisolated private static func map(
        _ status: SFSpeechRecognizerAuthorizationStatus
    ) -> LegacySpeechAuthorizationStatus {
        switch status {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unavailable
        }
    }
}

struct LegacySpeechRecognitionRequestConfiguration: Equatable, Sendable {
    let requiresOnDeviceRecognition: Bool
    let shouldReportPartialResults: Bool
    let addsPunctuation: Bool
}

struct LegacySpeechRecognitionCallback {
    let text: String
    let segments: [TranscriptSegment]
    let isFinal: Bool
    let error: Error?

    init(text: String, segments: [TranscriptSegment] = [], isFinal: Bool, error: Error? = nil) {
        self.text = text
        self.segments = segments
        self.isFinal = isFinal
        self.error = error
    }
}

protocol LegacySpeechRecognizerMaking: Sendable {
    nonisolated func recognizer(locale: Locale) -> LegacySpeechRecognizing?
}

protocol LegacySpeechRecognizing: Sendable {
    nonisolated var isAvailable: Bool { get }
    nonisolated var supportsOnDeviceRecognition: Bool { get }

    nonisolated func recognitionTask(
        audioURL: URL,
        configuration: LegacySpeechRecognitionRequestConfiguration,
        resultHandler: @escaping (LegacySpeechRecognitionCallback) -> Void
    ) -> LegacySpeechRecognitionTasking
}

protocol LegacySpeechRecognitionTasking: Sendable {
    nonisolated func cancel()
}

struct SystemSpeechRecognizerFactory: LegacySpeechRecognizerMaking {
    func recognizer(locale: Locale) -> LegacySpeechRecognizing? {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return nil
        }

        return SystemSpeechRecognizer(recognizer: recognizer)
    }
}

final class SystemSpeechRecognizer: LegacySpeechRecognizing, @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer

    init(recognizer: SFSpeechRecognizer) {
        self.recognizer = recognizer
    }

    var isAvailable: Bool {
        recognizer.isAvailable
    }

    var supportsOnDeviceRecognition: Bool {
        recognizer.supportsOnDeviceRecognition
    }

    func recognitionTask(
        audioURL: URL,
        configuration: LegacySpeechRecognitionRequestConfiguration,
        resultHandler: @escaping (LegacySpeechRecognitionCallback) -> Void
    ) -> LegacySpeechRecognitionTasking {
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = configuration.requiresOnDeviceRecognition
        request.shouldReportPartialResults = configuration.shouldReportPartialResults
        request.taskHint = .dictation

        if #available(macOS 13.0, *) {
            request.addsPunctuation = configuration.addsPunctuation
        }

        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                resultHandler(Self.callback(from: result, error: error))
                return
            }

            if let error {
                resultHandler(.init(text: "", isFinal: true, error: error))
            }
        }

        return SystemSpeechRecognitionTask(task: task)
    }

    private static func callback(
        from result: SFSpeechRecognitionResult,
        error: Error?
    ) -> LegacySpeechRecognitionCallback {
        LegacySpeechRecognitionCallback(
            text: result.bestTranscription.formattedString,
            segments: result.bestTranscription.segments.map { segment in
                TranscriptSegment(
                    text: segment.substring,
                    timestamp: segment.timestamp,
                    duration: segment.duration
                )
            },
            isFinal: result.isFinal,
            error: error
        )
    }
}

final class SystemSpeechRecognitionTask: LegacySpeechRecognitionTasking, @unchecked Sendable {
    private let task: SFSpeechRecognitionTask

    init(task: SFSpeechRecognitionTask) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}
