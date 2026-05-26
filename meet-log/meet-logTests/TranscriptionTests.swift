import Foundation
import Testing
@testable import meet_log

struct TranscriptionTests {
    @Test func transcriptionErrorDescriptionsAreUserFacing() {
        let errors: [TranscriptionError] = [
            .authorizationDenied,
            .authorizationRestricted,
            .authorizationUnavailable,
            .recognizerUnavailable(localeIdentifier: "ja-JP"),
            .recognizerNotAvailable(localeIdentifier: "ja-JP"),
            .onDeviceRecognitionUnavailable(localeIdentifier: "ja-JP"),
            .recognitionFailed("Speech failed"),
            .emptyResult,
            .cancelled
        ]

        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    @Test func authorizationDeniedFailsWithTypedError() async {
        await expectTranscriptionFailure(
            authorizationStatus: .denied,
            expectedError: .authorizationDenied
        )
    }

    @Test func authorizationRestrictedFailsWithTypedError() async {
        await expectTranscriptionFailure(
            authorizationStatus: .restricted,
            expectedError: .authorizationRestricted
        )
    }

    @Test func authorizationUnavailableFailsWithTypedError() async {
        await expectTranscriptionFailure(
            authorizationStatus: .unavailable,
            expectedError: .authorizationUnavailable
        )
    }

    @Test func notDeterminedAfterRequestFailsWithAuthorizationUnavailable() async {
        await expectTranscriptionFailure(
            authorizationStatus: .notDetermined,
            expectedError: .authorizationUnavailable
        )
    }

    @Test func nilRecognizerFailsWithRecognizerUnavailable() async {
        let service = makeService(recognizer: nil)

        await expectFailure(
            from: service.transcribe(audioURL: sampleAudioURL, locale: japaneseLocale),
            expectedError: .recognizerUnavailable(localeIdentifier: "ja-JP")
        )
    }

    @Test func unavailableRecognizerFailsWithRecognizerNotAvailable() async {
        let recognizer = FakeSpeechRecognizer(isAvailable: false)
        let service = makeService(recognizer: recognizer)

        await expectFailure(
            from: service.transcribe(audioURL: sampleAudioURL, locale: japaneseLocale),
            expectedError: .recognizerNotAvailable(localeIdentifier: "ja-JP")
        )
    }

    @Test func onDeviceUnsupportedRecognizerFailsWithTypedError() async {
        let recognizer = FakeSpeechRecognizer(supportsOnDeviceRecognition: false)
        let service = makeService(recognizer: recognizer)

        await expectFailure(
            from: service.transcribe(audioURL: sampleAudioURL, locale: japaneseLocale),
            expectedError: .onDeviceRecognitionUnavailable(localeIdentifier: "ja-JP")
        )
    }

    @Test func recognitionRequestConfigurationRequiresOnDeviceAndPartialResults() async throws {
        let recognizer = FakeSpeechRecognizer()
        let service = makeService(recognizer: recognizer)
        let stream = service.transcribe(audioURL: sampleAudioURL, locale: japaneseLocale)
        var iterator = stream.makeAsyncIterator()

        try await waitUntil { recognizer.recordedConfiguration != nil }

        #expect(recognizer.recordedAudioURL == sampleAudioURL)
        #expect(recognizer.recordedConfiguration?.requiresOnDeviceRecognition == true)
        #expect(recognizer.recordedConfiguration?.shouldReportPartialResults == true)
        #expect(recognizer.recordedConfiguration?.addsPunctuation == true)

        recognizer.emit(.init(text: "完了", isFinal: true))
        _ = try await iterator.next()
    }

    @Test func partialRecognitionCallbackEmitsPartialEvent() async throws {
        let recognizer = FakeSpeechRecognizer()
        let service = makeService(recognizer: recognizer)
        let stream = service.transcribe(audioURL: sampleAudioURL, locale: japaneseLocale)
        var iterator = stream.makeAsyncIterator()

        try await waitUntil { recognizer.hasResultHandler }
        recognizer.emit(.init(text: "こんにちは", isFinal: false))

        let event = try await iterator.next()

        #expect(event == .partial("こんにちは"))
    }

    @Test func finalRecognitionCallbackEmitsCompletedEvent() async throws {
        let recognizer = FakeSpeechRecognizer()
        let service = makeService(recognizer: recognizer)
        let stream = service.transcribe(audioURL: sampleAudioURL, locale: japaneseLocale)
        var iterator = stream.makeAsyncIterator()
        let segments = [TranscriptSegment(text: "こんにちは", timestamp: 0, duration: 1)]

        try await waitUntil { recognizer.hasResultHandler }
        recognizer.emit(.init(text: "こんにちは", segments: segments, isFinal: true))

        let event = try await iterator.next()

        #expect(
            event == .completed(
                TranscriptResult(
                    text: "こんにちは",
                    localeIdentifier: "ja-JP",
                    sourceURL: sampleAudioURL,
                    segments: segments
                )
            )
        )
    }

    @Test func emptyFinalRecognitionCallbackFailsWithEmptyResult() async throws {
        let recognizer = FakeSpeechRecognizer()
        let service = makeService(recognizer: recognizer)
        let failureTask = Task {
            await failure(from: service.transcribe(audioURL: sampleAudioURL, locale: japaneseLocale))
        }

        try await waitUntil { recognizer.hasResultHandler }
        recognizer.emit(.init(text: "  ", isFinal: true))

        #expect(await failureTask.value == .emptyResult)
    }

    @Test func callbackErrorFailsWithRecognitionFailed() async throws {
        let recognizer = FakeSpeechRecognizer()
        let service = makeService(recognizer: recognizer)
        let failureTask = Task {
            await failure(from: service.transcribe(audioURL: sampleAudioURL, locale: japaneseLocale))
        }

        try await waitUntil { recognizer.hasResultHandler }
        recognizer.emit(.init(text: "", isFinal: true, error: TestRecognitionError.boom))

        #expect(await failureTask.value == .recognitionFailed("boom"))
    }

    @Test func streamTerminationCancelsRecognitionTask() async throws {
        let recognizer = FakeSpeechRecognizer()
        let service = makeService(recognizer: recognizer)
        var stream: AsyncThrowingStream<TranscriptionEvent, Error>? = service.transcribe(
            audioURL: sampleAudioURL,
            locale: japaneseLocale
        )
        var iterator = stream?.makeAsyncIterator()

        try await waitUntil { recognizer.hasResultHandler }
        stream = nil
        iterator = nil

        try await waitUntil { recognizer.task.isCancelled }
    }

    @Test func finalTranscriptReturnsFinalResultAndIgnoresPartials() async throws {
        let recognizer = FakeSpeechRecognizer()
        let service = makeService(recognizer: recognizer)
        let transcriptTask = Task {
            try await service.finalTranscript(audioURL: sampleAudioURL, locale: japaneseLocale)
        }

        try await waitUntil { recognizer.hasResultHandler }
        recognizer.emit(.init(text: "途中", isFinal: false))
        recognizer.emit(.init(text: "最終", isFinal: true))

        let result = try await transcriptTask.value

        #expect(result.text == "最終")
        #expect(result.localeIdentifier == "ja-JP")
        #expect(result.sourceURL == sampleAudioURL)
    }

    private func expectTranscriptionFailure(
        authorizationStatus: LegacySpeechAuthorizationStatus,
        expectedError: TranscriptionError
    ) async {
        let service = LegacySpeechTranscriptionService(
            authorizationProvider: FakeSpeechAuthorizationProvider(status: authorizationStatus),
            recognizerFactory: FakeSpeechRecognizerFactory(recognizer: FakeSpeechRecognizer())
        )

        await expectFailure(
            from: service.transcribe(audioURL: sampleAudioURL, locale: japaneseLocale),
            expectedError: expectedError
        )
    }

    private func expectFailure(
        from stream: AsyncThrowingStream<TranscriptionEvent, Error>,
        expectedError: TranscriptionError
    ) async {
        #expect(await failure(from: stream) == expectedError)
    }

    private func failure(
        from stream: AsyncThrowingStream<TranscriptionEvent, Error>
    ) async -> TranscriptionError? {
        do {
            for try await _ in stream {}
            return nil
        } catch let error as TranscriptionError {
            return error
        } catch {
            Issue.record("Expected TranscriptionError, got \(error).")
            return nil
        }
    }

    private func makeService(recognizer: FakeSpeechRecognizer?) -> LegacySpeechTranscriptionService {
        LegacySpeechTranscriptionService(
            authorizationProvider: FakeSpeechAuthorizationProvider(status: .authorized),
            recognizerFactory: FakeSpeechRecognizerFactory(recognizer: recognizer)
        )
    }
}

private let japaneseLocale = Locale(identifier: "ja-JP")
private let sampleAudioURL = URL(fileURLWithPath: "/tmp/sample.m4a")

private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline {
            Issue.record("Timed out waiting for condition.")
            return
        }

        try await Task.sleep(for: .milliseconds(10))
    }
}

private struct FakeSpeechAuthorizationProvider: LegacySpeechAuthorizationProviding {
    let status: LegacySpeechAuthorizationStatus

    func authorizationStatusAfterRequest() async -> LegacySpeechAuthorizationStatus {
        status
    }
}

private final class FakeSpeechRecognizerFactory: LegacySpeechRecognizerMaking, @unchecked Sendable {
    private let recognizerValue: FakeSpeechRecognizer?

    init(recognizer: FakeSpeechRecognizer?) {
        recognizerValue = recognizer
    }

    func recognizer(locale: Locale) -> LegacySpeechRecognizing? {
        recognizerValue
    }
}

private final class FakeSpeechRecognizer: LegacySpeechRecognizing, @unchecked Sendable {
    let isAvailable: Bool
    let supportsOnDeviceRecognition: Bool
    let task = FakeSpeechRecognitionTask()
    private let lock = NSLock()
    private var resultHandler: ((LegacySpeechRecognitionCallback) -> Void)?
    private var configurationValue: LegacySpeechRecognitionRequestConfiguration?
    private var audioURLValue: URL?

    init(isAvailable: Bool = true, supportsOnDeviceRecognition: Bool = true) {
        self.isAvailable = isAvailable
        self.supportsOnDeviceRecognition = supportsOnDeviceRecognition
    }

    var hasResultHandler: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resultHandler != nil
    }

    var recordedConfiguration: LegacySpeechRecognitionRequestConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        return configurationValue
    }

    var recordedAudioURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return audioURLValue
    }

    func recognitionTask(
        audioURL: URL,
        configuration: LegacySpeechRecognitionRequestConfiguration,
        resultHandler: @escaping (LegacySpeechRecognitionCallback) -> Void
    ) -> LegacySpeechRecognitionTasking {
        lock.lock()
        audioURLValue = audioURL
        configurationValue = configuration
        self.resultHandler = resultHandler
        lock.unlock()
        return task
    }

    func emit(_ callback: LegacySpeechRecognitionCallback) {
        lock.lock()
        let resultHandler = resultHandler
        lock.unlock()
        resultHandler?(callback)
    }
}

private final class FakeSpeechRecognitionTask: LegacySpeechRecognitionTasking, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private enum TestRecognitionError: Error, LocalizedError {
    case boom

    var errorDescription: String? {
        "boom"
    }
}
