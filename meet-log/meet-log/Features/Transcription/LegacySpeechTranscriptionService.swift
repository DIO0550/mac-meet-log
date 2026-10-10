import Foundation
import Speech

struct LegacySpeechTranscriptionService: AudioTranscriptionService {
    private let authorizationProvider: LegacySpeechAuthorizationProviding
    private let recognizerFactory: LegacySpeechRecognizerMaking

    nonisolated init(
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
    private var state = State.idle
    private var startupTask: Task<Void, Never>?
    private var recognitionTask: LegacySpeechRecognitionTasking?

    private enum State {
        case idle
        case running
        case finished
    }

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
        lock.lock()
        guard state == .idle else {
            lock.unlock()
            return
        }

        state = .running
        startupTask = Task {
            defer { clearStartupTask() }

            do {
                try checkCancellation()
                try await authorize()
                try startRecognition()
            } catch {
                finish(throwing: error)
            }
        }
        lock.unlock()
    }

    nonisolated func cancel() {
        finish(throwing: CancellationError())
    }

    nonisolated private func clearStartupTask() {
        lock.lock()
        startupTask = nil
        lock.unlock()
    }

    nonisolated private func checkCancellation() throws {
        try Task.checkCancellation()

        lock.lock()
        let isRunning = state == .running
        lock.unlock()

        guard isRunning else {
            throw CancellationError()
        }
    }

    nonisolated private func authorize() async throws {
        let status = await authorizationProvider.authorizationStatusAfterRequest()
        try checkCancellation()

        switch status {
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
        try checkCancellation()

        let localeIdentifier = locale.identifier
        guard let recognizer = recognizerFactory.recognizer(locale: locale) else {
            throw TranscriptionError.recognizerUnsupportedForLocale(localeIdentifier: localeIdentifier)
        }

        guard recognizer.isAvailable else {
            throw TranscriptionError.recognizerTemporarilyUnavailable(localeIdentifier: localeIdentifier)
        }

        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.onDeviceRecognitionUnavailable(localeIdentifier: localeIdentifier)
        }

        let configuration = LegacySpeechRecognitionRequestConfiguration(
            requiresOnDeviceRecognition: true,
            shouldReportPartialResults: true,
            addsPunctuation: true
        )
        try checkCancellation()

        // Recognition can call back synchronously, so create it outside the lock.
        let recognitionTask = recognizer.recognitionTask(
            audioURL: audioURL,
            configuration: configuration
        ) { [weak self] callback in
            self?.handle(callback)
        }

        lock.lock()
        guard state == .running else {
            lock.unlock()
            recognitionTask.cancel()
            return
        }

        self.recognitionTask = recognitionTask
        lock.unlock()
    }

    nonisolated private func handle(_ callback: LegacySpeechRecognitionCallback) {
        if let error = callback.error {
            finish(throwing: Self.map(error))
            return
        }

        let text = callback.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard callback.isFinal else {
            lock.lock()
            let isRunning = state == .running
            lock.unlock()

            guard isRunning else {
                return
            }

            if !text.isEmpty {
                continuation.yield(.partial(text))
            }
            return
        }

        guard !text.isEmpty else {
            finish(throwing: TranscriptionError.emptyResult)
            return
        }

        finish(
            with: .completed(
                TranscriptResult(
                    text: text,
                    localeIdentifier: locale.identifier,
                    sourceURL: audioURL,
                    segments: callback.segments
                )
            )
        )
    }

    nonisolated private func finish(
        with event: TranscriptionEvent? = nil,
        throwing error: Error? = nil
    ) {
        lock.lock()
        guard state != .finished else {
            lock.unlock()
            return
        }

        state = .finished
        let startupTask = startupTask
        let recognitionTask = recognitionTask
        self.startupTask = nil
        self.recognitionTask = nil
        lock.unlock()

        // finish invokes onTermination; cancellation can also call back synchronously.
        if let event {
            continuation.yield(event)
        }
        continuation.finish(throwing: error)
        startupTask?.cancel()
        recognitionTask?.cancel()
    }

    nonisolated private static func map(_ error: Error) -> Error {
        if TranscriptionCancellation.isCancellation(error) {
            return CancellationError()
        }
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("Siri and Dictation are disabled") {
            return TranscriptionError.siriAndDictationDisabled
        }

        return TranscriptionError.recognitionFailed(message)
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
    nonisolated init() {}

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
    nonisolated init() {}

    nonisolated func recognizer(locale: Locale) -> LegacySpeechRecognizing? {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return nil
        }

        return SystemSpeechRecognizer(recognizer: recognizer)
    }
}

nonisolated final class SystemSpeechRecognizer: LegacySpeechRecognizing, @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer

    nonisolated init(recognizer: SFSpeechRecognizer) {
        self.recognizer = recognizer
    }

    nonisolated var isAvailable: Bool {
        recognizer.isAvailable
    }

    nonisolated var supportsOnDeviceRecognition: Bool {
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
        request.addsPunctuation = configuration.addsPunctuation

        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                resultHandler(Self.callback(from: result))
                return
            }

            if let error {
                resultHandler(.init(text: "", isFinal: true, error: error))
            }
        }

        return SystemSpeechRecognitionTask(task: task)
    }

    private static func callback(from result: SFSpeechRecognitionResult) -> LegacySpeechRecognitionCallback {
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
            error: nil
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
