import Foundation
import Testing
@testable import meet_log

@MainActor
struct LegacySpeechCancellationTests {
    @Test(arguments: [LegacySpeechAuthorizationStatus.authorized, .denied])
    func consumerCancellationDuringAuthorizationPreventsRecognition(
        lateStatus: LegacySpeechAuthorizationStatus
    ) async throws {
        let authorization = PendingSpeechAuthorization()
        defer { authorization.resolve(lateStatus) }
        let recognizer = ControlledSpeechRecognizer()
        let factory = ControlledSpeechRecognizerFactory(recognizer: recognizer)
        let fixture = CoordinatorFixture(authorization: authorization, factory: factory)
        let stream = fixture.stream
        let consumer = Task { try await collect(stream) }
        fixture.start()
        try await waitFor { authorization.isWaiting }

        consumer.cancel()
        await #expect(throws: CancellationError.self) { try await consumer.value }
        try await waitFor { authorization.cancellationCount == 1 }
        #expect(fixture.termination.count == 1)

        fixture.releaseCoordinator()
        authorization.resolve(lateStatus)
        // Deallocation proves the cancelled startup actually resumed and exited.
        try await waitFor { fixture.lifetime.value == nil }
        #expect(factory.creationCount == 0)
        #expect(recognizer.creationCount == 0)
        #expect(fixture.termination.count == 1)
    }

    @Test func cancellationBeforeStartDoesNotRequestAuthorization() async throws {
        let authorization = PendingSpeechAuthorization()
        defer { authorization.resolve(.authorized) }
        let recognizer = ControlledSpeechRecognizer()
        let fixture = CoordinatorFixture(
            authorization: authorization,
            factory: ControlledSpeechRecognizerFactory(recognizer: recognizer)
        )

        fixture.coordinator?.cancel()
        fixture.start()
        fixture.start()
        await #expect(throws: CancellationError.self) { try await collect(fixture.stream) }

        fixture.releaseCoordinator()
        try await waitFor { fixture.lifetime.value == nil }
        #expect(!authorization.isWaiting)
        #expect(recognizer.creationCount == 0)
        #expect(fixture.termination.count == 1)
    }

    @Test func cancellationWhileMakingRecognizerPreventsTaskCreation() async throws {
        let gate = RecognitionCreationGate()
        defer { gate.release() }
        let recognizer = ControlledSpeechRecognizer()
        let factory = ControlledSpeechRecognizerFactory(recognizer: recognizer, gate: gate)
        let fixture = CoordinatorFixture(factory: factory)
        let stream = fixture.stream
        let consumer = Task { try await collect(stream) }
        fixture.start()
        try await waitFor { gate.isWaiting }

        consumer.cancel()
        await #expect(throws: CancellationError.self) { try await consumer.value }
        fixture.releaseCoordinator()
        gate.release()

        try await waitFor { fixture.lifetime.value == nil }
        #expect(factory.creationCount == 1)
        #expect(recognizer.creationCount == 0)
        #expect(fixture.termination.count == 1)
    }

    @Test func cancellationDuringTaskCreationStopsTheReturnedTask() async throws {
        let gate = RecognitionCreationGate()
        defer { gate.release() }
        let recognizer = ControlledSpeechRecognizer(gate: gate)
        let fixture = CoordinatorFixture(factory: ControlledSpeechRecognizerFactory(recognizer: recognizer))
        let stream = fixture.stream
        let consumer = Task { try await collect(stream) }
        fixture.start()
        try await waitFor { gate.isWaiting }

        consumer.cancel()
        await #expect(throws: CancellationError.self) { try await consumer.value }
        #expect(recognizer.task.cancellationCount == 0)
        fixture.releaseCoordinator()
        gate.release()

        try await waitFor { fixture.lifetime.value == nil }
        #expect(recognizer.task.cancellationCount == 1)
        recognizer.emit(.init(text: "遅延完了", isFinal: true))
        #expect(fixture.termination.count == 1)
    }

    @Test func activeRecognitionCancellationIgnoresLateCallbacks() async throws {
        let recognizer = ControlledSpeechRecognizer()
        let fixture = CoordinatorFixture(factory: ControlledSpeechRecognizerFactory(recognizer: recognizer))
        let stream = fixture.stream
        let consumer = Task { try await collect(stream) }
        fixture.start()
        fixture.start()
        try await waitFor { recognizer.creationCount == 1 }

        consumer.cancel()
        await #expect(throws: CancellationError.self) { try await consumer.value }
        try await waitFor { recognizer.task.cancellationCount == 1 }
        recognizer.emit(.init(text: "途中", isFinal: false))
        recognizer.emit(.init(text: "遅延完了", isFinal: true))
        fixture.coordinator?.cancel()
        fixture.releaseCoordinator()

        try await waitFor { fixture.lifetime.value == nil }
        #expect(recognizer.creationCount == 1)
        #expect(recognizer.task.cancellationCount == 1)
        #expect(fixture.termination.count == 1)
    }

    @Test(arguments: [false, true])
    func finalCallbackFinishesOnceEvenBeforeTaskIsStored(synchronous: Bool) async throws {
        let final = LegacySpeechRecognitionCallback(text: "完了", isFinal: true)
        let recognizer = ControlledSpeechRecognizer(initialCallback: synchronous ? final : nil)
        let fixture = CoordinatorFixture(factory: ControlledSpeechRecognizerFactory(recognizer: recognizer))
        fixture.start()

        if !synchronous {
            try await waitFor { recognizer.creationCount == 1 }
            recognizer.emit(final)
        }

        let events = try await collect(fixture.stream)
        #expect(events == [.completed(TranscriptResult(
            text: "完了", localeIdentifier: "ja-JP", sourceURL: audioURL
        ))])
        try await waitFor { recognizer.task.cancellationCount == 1 }
        recognizer.emit(final)
        recognizer.emit(.init(text: "", isFinal: true, error: CancellationError()))
        fixture.coordinator?.cancel()
        fixture.releaseCoordinator()

        try await waitFor { fixture.lifetime.value == nil }
        #expect(recognizer.task.cancellationCount == 1)
        #expect(fixture.termination.count == 1)
    }

    @Test func synchronousRecognitionFailureStopsTaskAndFinishesOnce() async throws {
        let recognizer = ControlledSpeechRecognizer(initialCallback: .init(text: " ", isFinal: true))
        let fixture = CoordinatorFixture(factory: ControlledSpeechRecognizerFactory(recognizer: recognizer))
        fixture.start()

        await #expect(throws: TranscriptionError.emptyResult) { try await collect(fixture.stream) }
        try await waitFor { recognizer.task.cancellationCount == 1 }
        recognizer.emit(.init(text: "遅延完了", isFinal: true))
        fixture.coordinator?.cancel()
        fixture.releaseCoordinator()

        try await waitFor { fixture.lifetime.value == nil }
        #expect(recognizer.task.cancellationCount == 1)
        #expect(fixture.termination.count == 1)
    }

    @Test func authorizationDenialFinishesOnceWithoutRecognition() async throws {
        let recognizer = ControlledSpeechRecognizer()
        let factory = ControlledSpeechRecognizerFactory(recognizer: recognizer)
        let fixture = CoordinatorFixture(authorization: ImmediateSpeechAuthorization(status: .denied), factory: factory)
        fixture.start()

        await #expect(throws: TranscriptionError.authorizationDenied) { try await collect(fixture.stream) }
        fixture.coordinator?.cancel()
        fixture.start()
        fixture.releaseCoordinator()

        try await waitFor { fixture.lifetime.value == nil }
        #expect(factory.creationCount == 0)
        #expect(recognizer.creationCount == 0)
        #expect(fixture.termination.count == 1)
    }
}

private let audioURL = URL(fileURLWithPath: "/tmp/cancellation-test.m4a")

private func collect(_ stream: AsyncThrowingStream<TranscriptionEvent, Error>) async throws -> [TranscriptionEvent] {
    var events: [TranscriptionEvent] = []
    for try await event in stream {
        try Task.checkCancellation()
        events.append(event)
    }
    try Task.checkCancellation()
    return events
}

private func waitFor(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            throw WaitTimeout()
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private struct WaitTimeout: Error {}

private final class CoordinatorFixture {
    let stream: AsyncThrowingStream<TranscriptionEvent, Error>
    var coordinator: LegacySpeechTranscriptionCoordinator?
    let lifetime: WeakCoordinator
    let termination = TerminationCounter()

    init(
        authorization: LegacySpeechAuthorizationProviding = ImmediateSpeechAuthorization(status: .authorized),
        factory: LegacySpeechRecognizerMaking
    ) {
        let pair = AsyncThrowingStream<TranscriptionEvent, Error>.makeStream()
        stream = pair.stream
        let coordinator = LegacySpeechTranscriptionCoordinator(
            audioURL: audioURL,
            locale: Locale(identifier: "ja-JP"),
            authorizationProvider: authorization,
            recognizerFactory: factory,
            continuation: pair.continuation
        )
        self.coordinator = coordinator
        lifetime = WeakCoordinator(coordinator)
        pair.continuation.onTermination = { [termination] _ in
            termination.increment()
            coordinator.cancel()
        }
    }

    func start() {
        coordinator?.start()
    }

    func releaseCoordinator() {
        coordinator = nil
    }
}

private final class WeakCoordinator: @unchecked Sendable {
    weak var value: LegacySpeechTranscriptionCoordinator?

    init(_ value: LegacySpeechTranscriptionCoordinator) {
        self.value = value
    }
}

private final class TerminationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func increment() {
        lock.withLock { value += 1 }
    }
}

private struct ImmediateSpeechAuthorization: LegacySpeechAuthorizationProviding {
    let status: LegacySpeechAuthorizationStatus

    func authorizationStatusAfterRequest() async -> LegacySpeechAuthorizationStatus {
        status
    }
}

private final class PendingSpeechAuthorization: LegacySpeechAuthorizationProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LegacySpeechAuthorizationStatus, Never>?
    private var cancellations = 0

    var isWaiting: Bool {
        lock.withLock { continuation != nil }
    }

    var cancellationCount: Int {
        lock.withLock { cancellations }
    }

    func authorizationStatusAfterRequest() async -> LegacySpeechAuthorizationStatus {
        await withTaskCancellationHandler {
            // Deliberately wait for the OS response even after cancellation.
            await withCheckedContinuation { continuation in
                lock.withLock { self.continuation = continuation }
            }
        } onCancel: {
            self.lock.withLock { self.cancellations += 1 }
        }
    }

    func resolve(_ status: LegacySpeechAuthorizationStatus) {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(returning: status)
    }
}

private final class RecognitionCreationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var waiting = false
    private var released = false

    var isWaiting: Bool {
        condition.withLock { waiting }
    }

    func wait() {
        condition.lock()
        waiting = true
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class ControlledSpeechRecognizerFactory: LegacySpeechRecognizerMaking, @unchecked Sendable {
    private let recognizerValue: ControlledSpeechRecognizer
    private let gate: RecognitionCreationGate?
    private let lock = NSLock()
    private var creations = 0

    init(recognizer: ControlledSpeechRecognizer, gate: RecognitionCreationGate? = nil) {
        recognizerValue = recognizer
        self.gate = gate
    }

    var creationCount: Int {
        lock.withLock { creations }
    }

    func recognizer(locale: Locale) -> LegacySpeechRecognizing? {
        lock.withLock { creations += 1 }
        gate?.wait()
        return recognizerValue
    }
}

private final class ControlledSpeechRecognizer: LegacySpeechRecognizing, @unchecked Sendable {
    let isAvailable = true
    let supportsOnDeviceRecognition = true
    let task = ControlledSpeechRecognitionTask()
    private let gate: RecognitionCreationGate?
    private let initialCallback: LegacySpeechRecognitionCallback?
    private let lock = NSLock()
    private var handler: ((LegacySpeechRecognitionCallback) -> Void)?
    private var creations = 0

    init(gate: RecognitionCreationGate? = nil, initialCallback: LegacySpeechRecognitionCallback? = nil) {
        self.gate = gate
        self.initialCallback = initialCallback
    }

    var creationCount: Int {
        lock.withLock { creations }
    }

    func recognitionTask(
        audioURL: URL,
        configuration: LegacySpeechRecognitionRequestConfiguration,
        resultHandler: @escaping (LegacySpeechRecognitionCallback) -> Void
    ) -> LegacySpeechRecognitionTasking {
        task.setCancellationHandler {
            resultHandler(.init(text: "", isFinal: true, error: CancellationError()))
        }
        lock.withLock {
            handler = resultHandler
            creations += 1
        }
        if let initialCallback {
            resultHandler(initialCallback)
        }
        gate?.wait()
        return task
    }

    func emit(_ callback: LegacySpeechRecognitionCallback) {
        let handler = lock.withLock { self.handler }
        handler?(callback)
    }
}

private final class ControlledSpeechRecognitionTask: LegacySpeechRecognitionTasking, @unchecked Sendable {
    private let lock = NSLock()
    private var cancellations = 0
    private var cancellationHandler: (() -> Void)?

    var cancellationCount: Int {
        lock.withLock { cancellations }
    }

    func setCancellationHandler(_ handler: @escaping () -> Void) {
        lock.withLock { cancellationHandler = handler }
    }

    func cancel() {
        let handler = lock.withLock {
            cancellations += 1
            return cancellationHandler
        }
        handler?()
    }
}
